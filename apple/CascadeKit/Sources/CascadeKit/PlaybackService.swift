import Foundation
import AVFoundation
import Observation
import Network

#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// The one place AVPlayer is wired to Jellyfin's playback API.
///
/// No view ever touches the AVPlayer. Views read this object's properties and
/// call its transport methods, which is what keeps the state machine in one
/// readable place instead of smeared across screens. Ported from the desktop
/// app's playback section and the RN port's PlaybackService, both of which
/// learned the same lessons the hard way.
///
/// `@Observable` means SwiftUI redraws automatically when any property below
/// changes; there is no publisher to wire up and no `objectWillChange` to send.
@MainActor
@Observable
public final class PlaybackService {

    // MARK: - What a view can read

    public private(set) var item: JfItem?
    /// The queue and where we are in it. Views read `queue.items` to draw an
    /// up-next list and `queue.index` to highlight the current row.
    public private(set) var queue = QueueOrder()
    public private(set) var repeatMode: RepeatMode = .none
    public private(set) var shuffle = false
    /// Counts plays a person started, as opposed to the queue moving on by
    /// itself. tvOS watches it to bring the player forward on a pick without
    /// yanking you back to it every time a song ends.
    public private(set) var playRequests = 0
    public private(set) var isPaused = true
    /// Between a play() call landing and its stream actually resolving, so a
    /// view can show "loading" rather than a stale track.
    public private(set) var isLoading = false
    public private(set) var positionSeconds: Double = 0
    public private(set) var durationSeconds: Double = 0
    public private(set) var error: String?
    /// 0-1, the scale AVPlayer takes. Jellyfin talks in 0-100.
    public private(set) var volume: Float = 1
    public private(set) var isMuted = false
    /// True when the server chose to transcode rather than hand over the file.
    /// Worth surfacing: on this library it should essentially never happen, so
    /// seeing it means the device profile and the server disagree.
    public private(set) var isTranscoding = false

    // MARK: - Internals

    private let client: JellyfinClient
    private let config: ServerConfig
    private let profile: DeviceProfile

    /// Settings > Streaming quality. Set through setStreamingQuality so a
    /// preload resolved at the old rate is thrown away.
    public private(set) var streamingQuality: StreamingQuality = .original
    public private(set) var cellularQuality: StreamingQuality = .original
    /// Cellular or a personal hotspot, as Network reports it. The cellular
    /// quality applies while this is true.
    public private(set) var onExpensiveNetwork = false
    private let pathMonitor = NWPathMonitor()

    /// A queue player so the next track can be handed over without a gap:
    /// it is resolved and enqueued while this one plays, and AVFoundation
    /// switches to it at the exact end (trimming AAC and MP3 priming as it
    /// goes). See syncPreload.
    private let player = AVQueuePlayer()
    /// The AVPlayerItem that belongs to `item`. Tracked here rather than read
    /// from player.currentItem, because a queue player moves that on its own,
    /// and an end notification from any other item (a track already skipped
    /// past, a preload) must not move the queue.
    private var currentPlayerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var progressTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// The active resolved stream, kept so seeking, reporting and abandoning an
    /// encode all know what they are dealing with without re-resolving.
    private var resolved: ResolvedStream?

    /// Ticks the current STREAM begins at. Non-zero only for a transcode asked
    /// to start partway in, because that is the one case where AVPlayer's own
    /// clock is measured from somewhere other than the start of the track. Add
    /// it to the player's time to get a real position.
    private var streamStartTicks = 0

    /// Bumped on every load, seek and stop, so a resolution already in flight
    /// can tell it has been superseded and drop its own result. Without this a
    /// slow PlaybackInfo for a track the user skipped past lands late and
    /// repoints the player at the wrong song.
    private var loadToken = 0

    public init(client: JellyfinClient, config: ServerConfig, profile: DeviceProfile = .apple) {
        self.client = client
        self.config = config
        self.profile = profile
        configureAudioSession()
        observePlayer()
        configureRemoteCommands()
        pathMonitor.pathUpdateHandler = Self.pathHandler { [weak self] expensive in
            self?.onExpensiveNetwork = expensive
        }
        pathMonitor.start(queue: DispatchQueue(label: "cascade.path"))
    }

    /// Built outside main-actor isolation for the same reason as the lock
    /// screen artwork: Network calls this on its own queue, and a closure
    /// written in this @MainActor class would trap there. It hops to main
    /// explicitly instead.
    nonisolated private static func pathHandler(
        _ apply: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> @Sendable (NWPath) -> Void {
        { path in
            let expensive = path.isExpensive
            Task { @MainActor in apply(expensive) }
        }
    }

    /// Takes effect from the next stream resolved. What is playing keeps
    /// playing; the preloaded next track is re-resolved at the new rate.
    public func setStreamingQuality(wifi: StreamingQuality, cellular: StreamingQuality) {
        streamingQuality = wifi
        cellularQuality = cellular
        dropPreload()
        syncPreload()
    }

    /// The profile to negotiate with right now.
    private var currentProfile: DeviceProfile {
        profile.capped(at: onExpensiveNetwork ? cellularQuality : streamingQuality)
    }

    // ponytail: no deinit. Swift 6 will not let one touch main-actor state, and
    // this object lives for the whole signed-in session, so nothing needs to
    // clean up early. The time observer is retained by the player, which this
    // object owns, so both die together, and the event loop below exits on its
    // own once self is gone. If this ever becomes per-screen rather than
    // per-session, give it an explicit tearDown() and call it from onDisappear.

    // MARK: - Transport

    /// Play a list of tracks starting at one of them. This is the entry point
    /// every screen uses: tapping a song in an album plays the whole album from
    /// that song, which is why there is no single-track version.
    public func play(_ items: [JfItem], startIndex: Int = 0) async {
        guard items.indices.contains(startIndex) else { return }
        queue = QueueOrder(items: items, index: startIndex, unshuffled: nil)
        shuffle = false
        playRequests += 1
        await load(items[startIndex])
    }

    /// Skip forward. Distinct from a track ending on its own: with repeat-one
    /// this still moves on, because a next button that refused to skip would
    /// read as broken.
    public func next() async {
        guard let index = manualNextIndex(length: queue.items.count,
                                          index: queue.index, repeatMode: repeatMode) else {
            await stop()
            return
        }
        queue.index = index
        await load(queue.items[index])
    }

    public func previous() async {
        guard let index = manualPreviousIndex(length: queue.items.count,
                                              index: queue.index, repeatMode: repeatMode) else { return }
        queue.index = index
        await load(queue.items[index])
    }

    public func cycleRepeat() {
        repeatMode = repeatMode.next
        syncPreload()
    }

    /// Reorders the queue around whatever is playing. The track keeps playing
    /// untouched; only the order around it changes.
    public func toggleShuffle() {
        shuffle.toggle()
        queue = setShuffle(queue, on: shuffle)
        syncPreload()
    }

    // MARK: - Queue edits
    //
    // The order logic is in QueueActions.swift. Each of these re-syncs the
    // gapless preload, because each can change what plays next.

    /// Right after the current track. With nothing playing, plays them.
    public func playNext(_ items: [JfItem]) async {
        guard !items.isEmpty else { return }
        guard item != nil else { return await play(items) }
        queue = playingNext(queue, items)
        syncPreload()
    }

    /// At the end of the queue. With nothing playing, plays them.
    public func addToQueue(_ items: [JfItem]) async {
        guard !items.isEmpty else { return }
        guard item != nil else { return await play(items) }
        queue = appending(queue, items)
        syncPreload()
    }

    /// Offsets as SwiftUI's onMove reports them.
    public func moveQueueItems(from offsets: IndexSet, to destination: Int) {
        queue = moving(queue, from: offsets, to: destination)
        syncPreload()
    }

    /// Never removes the current track; see removing(_:at:).
    public func removeQueueItems(at offsets: IndexSet) {
        queue = removing(queue, at: offsets)
        syncPreload()
    }

    /// Play a queue row, keeping the queue as it is.
    public func jump(to index: Int) async {
        guard queue.items.indices.contains(index) else { return }
        queue.index = index
        await load(queue.items[index])
    }

    /// Replace the queue with Jellyfin's instant mix seeded from a track,
    /// album or artist. A failure lands in `error`, where Now Playing shows it.
    public func playInstantMix(from seedId: String) async {
        do {
            let mix = try await client.instantMix(seedId: seedId)
            guard !mix.isEmpty else {
                error = "Jellyfin returned no instant mix for this."
                return
            }
            await play(mix)
        } catch {
            self.error = "Could not build an instant mix: \(error.localizedDescription)"
        }
    }

    // MARK: - Sleep timer
    //
    // The desktop's: after N minutes, or at the end of the current track.
    // Either one pauses rather than stops, so the queue is still there in the
    // morning.

    public enum SleepTimer: Equatable, Sendable {
        case off
        case at(Date)
        case endOfTrack
    }
    public private(set) var sleepTimer: SleepTimer = .off
    private var sleepTask: Task<Void, Never>?

    public func setSleepTimer(minutes: Int) {
        // Only the menu's fixed choices reach here, but a zero or negative
        // count would pause at once and a huge one would overflow the clock.
        let minutes = min(max(minutes, 1), 24 * 60)
        cancelSleepTimer()
        sleepTimer = .at(Date().addingTimeInterval(Double(minutes) * 60))
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self else { return }
            self.sleepTimer = .off
            self.pause()
        }
    }

    public func setSleepTimerAtEndOfTrack() {
        cancelSleepTimer()
        sleepTimer = .endOfTrack
        // Nothing may be queued to start by itself once this track ends.
        syncPreload()
    }

    public func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        guard sleepTimer != .off else { return }
        sleepTimer = .off
        syncPreload()
    }

    /// End-of-track sleep: stop at the end, but with the next track loaded
    /// and paused, so play in the morning carries on from where the queue was.
    private func sleepAtTrackEnd() async {
        sleepTimer = .off
        switch advanceOnEnd(length: queue.items.count, index: queue.index, repeatMode: repeatMode) {
        case .stop:
            await stop()
        case .restart:
            await seek(to: 0)
            pause()
        case .play(let index):
            queue.index = index
            await load(queue.items[index], autoplay: false)
        }
    }

    private func load(_ item: JfItem, autoplay: Bool = true) async {
        // Whatever was playing is finished as far as the server is concerned,
        // and its transcode, if any, is now waste.
        if self.item != nil { await reportStopped() }
        abandonEncode()
        stopReporting()
        dropPreload()
        // From here the old item's end, if it lands, is not ours to act on.
        currentPlayerItem = nil

        let token = nextToken()
        self.item = item
        isPaused = !autoplay
        isLoading = true
        error = nil
        positionSeconds = 0
        durationSeconds = 0
        resolved = nil
        streamStartTicks = 0
        isTranscoding = false

        let startTicks = resumeTicks(for: item)
        let stream = await resolveStream(client: client, config: config,
                                        itemId: item.id, profile: currentProfile, startTicks: startTicks)
        // A later play() or stop() won the race; its result is the real one.
        guard token == loadToken else { return }

        adopt(stream)

        let playerItem = AVPlayerItem(url: stream.url)
        setPlayerItem(playerItem)

        // Direct play hands over the whole file, so the server ignored
        // startTicks and a resume position has to be seeked locally. That can
        // only happen once the asset has loaded enough to be seekable, which is
        // why this awaits the duration rather than seeking straight away.
        //
        // The error is surfaced rather than ignored. This is the one place an
        // undecodable stream announces itself: resolveStream falls back rather
        // than throwing, and a player pointed at something it cannot decode
        // sits there silently instead of failing. Silence that looks like a bug
        // in the app is exactly the failure mode the device profile exists to
        // avoid, so it gets a message.
        do {
            let duration = try await playerItem.asset.load(.duration).seconds
            guard token == loadToken else { return }
            if duration.isFinite, duration > 0 {
                durationSeconds = duration
                if stream.direct && startTicks > 0 {
                    await seekPlayer(to: CascadeKit.seconds(fromTicks: startTicks))
                    positionSeconds = CascadeKit.seconds(fromTicks: startTicks)
                }
            }
        } catch {
            guard token == loadToken else { return }
            reportLoadFailure(playerItem, error)
            return
        }

        guard token == loadToken else { return }
        if autoplay { player.play() }
        updateNowPlaying()
        Task { await loadArtwork() }
        syncPreload()
        await PlaybackReporter.start(client, state())
        startReporting()
    }

    /// Make `playerItem` the only thing the queue player holds. Not
    /// replaceCurrentItem: on a queue player that leaves whatever was queued
    /// behind it in place.
    private func setPlayerItem(_ playerItem: AVPlayerItem) {
        dropPreload()
        player.removeAllItems()
        player.insert(playerItem, after: nil)
        currentPlayerItem = playerItem
    }

    public func pause() {
        guard item != nil, !isPaused else { return }
        isPaused = true
        player.pause()
        updateNowPlaying()
        reportNow()
    }

    public func resume() {
        guard item != nil, isPaused else { return }
        isPaused = false
        player.play()
        updateNowPlaying()
        reportNow()
    }

    public func togglePlayPause() {
        isPaused ? resume() : pause()
    }

    /// Seek to an absolute position in the current track, in seconds.
    public func seek(to seconds: Double) async {
        guard let item, let resolved else { return }
        let target = max(0, min(seconds, durationSeconds > 0 ? durationSeconds : seconds))

        if resolved.direct {
            // The whole file is already there, so this costs no round trip.
            await seekPlayer(to: target)
            positionSeconds = target
            updateNowPlaying()
            reportNow()
            return
        }

        // A transcode only ever exposes what has already been encoded, so
        // seeking one means asking for a fresh stream that starts at the new
        // offset. See withStartTicks.
        //
        // ponytail: always a full PlaybackInfo round trip. Add a cached-URL
        // fast path if a seek's round trip turns out to be felt on a real
        // connection.
        let token = nextToken()
        abandonEncode()
        let stream = await resolveStream(client: client, config: config, itemId: item.id,
                                         profile: currentProfile, startTicks: ticks(fromSeconds: target))
        guard token == loadToken else { return }

        adopt(stream)
        setPlayerItem(AVPlayerItem(url: stream.url))
        player.play()
        positionSeconds = target
        updateNowPlaying()
        reportNow()
        syncPreload()
    }

    /// 0-1, clamped. Persisting it is the app's business, not this service's.
    public func setVolume(_ v: Float) {
        volume = min(1, max(0, v))
        player.volume = volume
        reportNow()
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        player.isMuted = muted
        reportNow()
    }

    public func stop() async {
        if item != nil { await reportStopped() }
        abandonEncode()
        stopReporting()
        _ = nextToken()          // invalidates anything still resolving
        dropPreload()
        player.removeAllItems()
        currentPlayerItem = nil
        resolved = nil
        streamStartTicks = 0
        item = nil
        queue = QueueOrder()
        // Repeat and shuffle survive: they are the user's settings, not part of
        // what happens to be playing, and a queue running out should not
        // silently switch them off.
        isPaused = true
        isLoading = false
        isTranscoding = false
        positionSeconds = 0
        durationSeconds = 0
        clearNowPlaying()
    }

    /// Report a load failure with whatever detail the player has, which is
    /// usually more specific than the thrown error alone.
    private func reportLoadFailure(_ playerItem: AVPlayerItem, _ thrown: Error) {
        let detail = (playerItem.error ?? thrown).localizedDescription
        error = "Could not play this track: \(detail)"
        isLoading = false
        isPaused = true
    }

    /// A track finishing on its own, which is not the same as pressing next.
    private func handleTrackEnded(_ ended: ObjectIdentifier?) async {
        // Only the end of the item we are playing counts. A late one from a
        // track already skipped past would otherwise skip this one too.
        guard let ended, let currentPlayerItem, ended == ObjectIdentifier(currentPlayerItem) else { return }
        if sleepTimer == .endOfTrack { return await sleepAtTrackEnd() }
        #if DEBUG
        measureHandover(from: ended)
        #endif
        switch advanceOnEnd(length: queue.items.count, index: queue.index, repeatMode: repeatMode) {
        case .stop:
            await stop()
        case .restart:
            // Explicit play: the item paused at its end, and a seek alone
            // left repeat-one sitting silent at 0:00 while showing "playing".
            await seek(to: 0)
            if !isPaused { player.play() }
        case .play(let index):
            if let preload, preload.index == index, preload.itemId == queue.items[index].id,
               player.items().contains(preload.playerItem) {
                await handOver(to: preload)
            } else {
                queue.index = index
                await load(queue.items[index])
            }
        }
    }

    // MARK: - Gapless handover
    //
    // The next track is resolved (PlaybackInfo) and enqueued on the queue
    // player while this one plays, so the end of a track costs no round trip
    // and AVFoundation starts the next one at the exact end of this one. Before
    // this, every track change was a stopped report, a PlaybackInfo request
    // and a fresh item, a few hundred ms of silence even on a LAN.
    //
    // What is enqueued has to be exactly what advanceOnEnd would pick, because
    // the player moves onto it by itself. So every change that could alter
    // that (queue edits, shuffle, repeat, a seek that swaps the item) calls
    // syncPreload, which drops a stale preload and fetches the right one.

    private struct Preload {
        let index: Int
        let itemId: String
        let stream: ResolvedStream
        let playerItem: AVPlayerItem
        let duration: Double
    }
    private var preload: Preload?
    /// What the in-flight preload is fetching, so a sync that wants the same
    /// thing leaves it alone instead of starting over.
    private var preloadTarget: (index: Int, itemId: String)?
    private var preloadTask: Task<Void, Never>?
    /// Separate from loadToken: shuffle, repeat and queue edits invalidate a
    /// preload without touching what is playing.
    private var preloadToken = 0

    /// The track that plays when this one ends on its own, if it can be
    /// handed over gaplessly. Not for repeat-one (a seek replays it) or a
    /// track with a resume point (load() seeks into it, which a queued item
    /// cannot do before it starts).
    private func expectedNext() -> (index: Int, item: JfItem)? {
        guard item != nil, sleepTimer != .endOfTrack,
              case .play(let index) = advanceOnEnd(length: queue.items.count, index: queue.index,
                                                  repeatMode: repeatMode) else { return nil }
        let next = queue.items[index]
        guard resumeTicks(for: next) == 0 else { return nil }
        return (index, next)
    }

    /// Bring the enqueued next item in line with what should play next.
    private func syncPreload() {
        let want = expectedNext()
        if let want {
            if let preload, preload.index == want.index, preload.itemId == want.item.id,
               player.items().contains(preload.playerItem) { return }
            if preload == nil, let target = preloadTarget,
               target.index == want.index, target.itemId == want.item.id { return }
        }
        dropPreload()
        guard let want, currentPlayerItem != nil else { return }
        let token = preloadToken
        preloadTarget = (want.index, want.item.id)
        preloadTask = Task { [weak self] in await self?.fetchPreload(want.index, want.item, token) }
    }

    private func fetchPreload(_ index: Int, _ next: JfItem, _ token: Int) async {
        let stream = await resolveStream(client: client, config: config, itemId: next.id, profile: currentProfile)
        guard token == preloadToken else { return abandon(stream) }
        let playerItem = AVPlayerItem(url: stream.url)
        // Loading the duration is also what proves the stream decodes. One
        // that does not is left out, and the end of this track falls back to
        // load(), which reports the failure properly.
        guard let duration = try? await playerItem.asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else {
            if token == preloadToken { preloadTarget = nil }
            return abandon(stream)
        }
        // Still wanted, and the current item has not ended while this was
        // resolving. If it has, load() is already on it.
        guard token == preloadToken, let current = currentPlayerItem,
              player.items().last === current else { return abandon(stream) }
        player.insert(playerItem, after: current)
        player.actionAtItemEnd = .advance
        preload = Preload(index: index, itemId: next.id, stream: stream,
                          playerItem: playerItem, duration: duration)
        preloadTarget = nil
    }

    /// Take the enqueued item out of the player and forget it.
    private func dropPreload() {
        preloadToken += 1
        preloadTask?.cancel()
        preloadTask = nil
        preloadTarget = nil
        // Pause at the end rather than advance whenever nothing we chose is
        // queued, which is what a plain AVPlayer did: repeat-one and the
        // load() fallback both expect the finished item to still be there.
        player.actionAtItemEnd = .pause
        guard let preload else { return }
        self.preload = nil
        player.remove(preload.playerItem)
        abandon(preload.stream)
    }

    /// The player has already moved onto the preloaded item by itself; bring
    /// this object's state, the server and the lock screen along with it.
    private func handOver(to next: Preload) async {
        // Snapshot BEFORE swapping `resolved`: a stopped report carrying the
        // new item's PlaySessionId would tell the server to kill the stream
        // that is now playing. The old track ran to its end, so it reports
        // its full length.
        var finished = state()
        finished.positionTicks = ticks(fromSeconds: durationSeconds)
        stopReporting()
        _ = nextToken()   // a seek or load still resolving for the old track is void

        preload = nil
        preloadTarget = nil
        player.actionAtItemEnd = .pause
        queue.index = next.index
        item = queue.items[next.index]
        currentPlayerItem = next.playerItem
        adopt(next.stream)
        durationSeconds = next.duration
        let t = player.currentTime().seconds
        positionSeconds = t.isFinite ? t : 0
        error = nil
        updateNowPlaying()
        Task { await loadArtwork() }
        syncPreload()

        await PlaybackReporter.stopped(client, finished)
        await PlaybackReporter.start(client, state())
        startReporting()
    }

    #if DEBUG
    /// How long the timeline sat between one track ending and the next one
    /// producing audio: time since the end notification, minus how far the
    /// new item's clock has already run. Near zero means the next item was
    /// already playing when we heard the old one end. This is the player's
    /// timeline, not a sample-level check of the audio. Read it with
    /// `log show --predicate 'eventMessage CONTAINS "HANDOVER"'`.
    private func measureHandover(from ended: ObjectIdentifier) {
        let start = ContinuousClock.now
        let from = item?.name ?? "?"
        Task { [weak self] in
            while start.duration(to: .now) < .seconds(15) {
                guard let self else { return }
                if let current = self.player.currentItem, ObjectIdentifier(current) != ended,
                   self.player.timeControlStatus == .playing {
                    let t = self.player.currentTime().seconds
                    if t.isFinite, t > 0 {
                        let waited = start.duration(to: .now)
                        let ms = (Double(waited.components.attoseconds) / 1e15 + Double(waited.components.seconds) * 1000) - t * 1000
                        NSLog("HANDOVER %@ -> %@: %.0f ms", from, self.item?.name ?? "?", ms)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
    #endif

    // MARK: - Wiring

    private func nextToken() -> Int {
        loadToken += 1
        return loadToken
    }

    private func adopt(_ stream: ResolvedStream) {
        resolved = stream
        streamStartTicks = stream.startTicks
        isTranscoding = !stream.direct
        isLoading = false
    }

    private func seekPlayer(to seconds: Double) async {
        await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func observePlayer() {
        // Position comes from the player rather than a wall clock, so pausing,
        // buffering and rate changes are all accounted for without extra code.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // assumeIsolated is safe HERE, unlike in the remote command
            // handlers below, because this observer was registered with
            // queue: .main and the main dispatch queue is the main actor's
            // executor. Keeping it avoids hopping through a Task twice a
            // second just to move a progress bar.
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.positionSeconds = CascadeKit.seconds(fromTicks: self.streamStartTicks) + time.seconds
            }
        }

        // An async sequence rather than block observers, so cancelling one task
        // unregisters both and there is nothing to remove by hand.
        eventTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await note in NotificationCenter.default.notifications(
                        named: AVPlayerItem.didPlayToEndTimeNotification) {
                        guard let self else { return }
                        let ended = note.object.map { ObjectIdentifier($0 as AnyObject) }
                        await self.handleTrackEnded(ended)
                    }
                }
                group.addTask {
                    // A stream that starts and then dies mid-track is what this
                    // catches. One that never starts surfaces via resolveStream.
                    for await note in NotificationCenter.default.notifications(
                        named: AVPlayerItem.failedToPlayToEndTimeNotification) {
                        guard let self else { return }
                        let underlying = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                        let message = underlying?.localizedDescription ?? "Playback failed"
                        let failed = note.object.map { ObjectIdentifier($0 as AnyObject) }
                        await self.handleItemFailed(failed, message)
                    }
                }
            }
        }
    }

    /// Only the playing item's failure is the user's problem. A preload that
    /// dies while buffering is just dropped, and the end of this track falls
    /// back to load(), which reports properly if it fails again.
    private func handleItemFailed(_ failed: ObjectIdentifier?, _ message: String) {
        if let preload, failed == ObjectIdentifier(preload.playerItem) {
            dropPreload()
            return
        }
        guard let currentPlayerItem, failed == ObjectIdentifier(currentPlayerItem) else { return }
        error = message
        isLoading = false
    }

    /// Without this the app is silent when the screen locks, and on iOS it also
    /// loses audio to any other app that takes the session. Checking this works
    /// under free provisioning is the point of the first device build.
    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Not fatal: audio still plays in the foreground, so this is worth
            // surfacing rather than trapping.
            self.error = "Audio session: \(error.localizedDescription)"
        }
        #endif
    }

    // MARK: - Reporting

    private func state() -> PlaybackState {
        PlaybackState(
            itemId: item?.id ?? "",
            positionTicks: ticks(fromSeconds: positionSeconds),
            isPaused: isPaused,
            isMuted: isMuted,
            volumeLevel: Int((volume * 100).rounded()),
            playSessionId: resolved?.playSessionId,
            mediaSourceId: resolved?.mediaSourceId,
            playMethod: resolved?.playMethod ?? .directPlay
        )
    }

    /// Fired on every state change as well as on the timer. Without the
    /// on-change reports the server's view of this session freezes between
    /// ticks, so a controller's scrubber and volume slider sit still.
    private func reportNow() {
        let snapshot = state()
        Task { await PlaybackReporter.progress(client, snapshot) }
    }

    private func reportStopped() async {
        await PlaybackReporter.stopped(client, state())
    }

    private func startReporting() {
        stopReporting()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: progressInterval)
                guard let self, self.item != nil else { return }
                self.reportNow()
            }
        }
    }

    private func stopReporting() {
        progressTask?.cancel()
        progressTask = nil
    }

    /// Tell the server to give up on a transcode we are about to walk away
    /// from. Abandoned encoders do not stop on their own, and with throttling
    /// off each one keeps encoding at full speed for a track nobody is hearing.
    /// A few scrubs becomes several ffmpegs fighting over the same cores, which
    /// looks exactly like "transcoding got slow" while being self-inflicted.
    private func abandonEncode() {
        if let resolved { abandon(resolved) }
    }

    private func abandon(_ stream: ResolvedStream) {
        guard !stream.direct, let session = stream.playSessionId else { return }
        let client = self.client
        let config = self.config
        // Never awaited: a seek should feel instant, and a server that never
        // hears about this wastes CPU, not correctness.
        Task.detached { await stopActiveEncoding(client: client, config: config, playSessionId: session) }
    }

    // MARK: - Lock screen and remote controls

    private func configureRemoteCommands() {
        #if canImport(MediaPlayer)
        // Task rather than MainActor.assumeIsolated. MPRemoteCommandCenter does
        // not promise to call these on the main thread, and assumeIsolated does
        // not check-and-recover when the assumption is wrong, it traps. That
        // shows up as a debugger stop on no breakpoint the first time anyone
        // touches a lock screen control.
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in await self?.seek(to: event.positionTime) }
            return .success
        }
        #endif
    }

    // MARK: - Lock screen art
    //
    // This once trapped in dispatch_assert_queue_fail and was taken out. The
    // cause was Swift 6 isolation, not MediaPlayer: a closure written inside a
    // @MainActor method is itself main-actor isolated, Swift 6 inserts a
    // runtime check that it really runs on main, and MediaPlayer calls the
    // artwork request handler on its own background queue. The check fails
    // and traps. Routing the nowPlayingInfo write to main and honoring the
    // size contract, the two earlier attempts, could not help because the
    // closure itself was the problem. makeArtwork is nonisolated, so the
    // closure it builds carries no isolation and no check.
    // https://developer.apple.com/forums/thread/764874

    #if canImport(MediaPlayer) && canImport(UIKit)
    /// Artwork for whatever is playing, kept so a position update does not
    /// download it again. Keyed by the art's item id (the album, usually), so
    /// the next track on the same album reuses it.
    private var artwork: (itemId: String, image: MPMediaItemArtwork)?

    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    #endif

    /// Fetch the current item's art for the lock screen. Separate from
    /// updateNowPlaying because that runs on every transport change and this
    /// is a download. The art lands a moment after the track, as it does in
    /// every other music app. Not awaited by callers: decoration only.
    private func loadArtwork() async {
        #if canImport(MediaPlayer) && canImport(UIKit)
        guard let item else { return }
        let artId = item.albumId ?? item.id
        guard artwork?.itemId != artId,
              let url = await client.imageUrl(itemId: artId, size: 600),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        // A slow download must not land on a track the user has skipped past.
        guard (self.item?.albumId ?? self.item?.id) == artId else { return }
        artwork = (artId, Self.makeArtwork(image))
        updateNowPlaying()
        #endif
    }

    private func updateNowPlaying() {
        #if canImport(MediaPlayer)
        guard let item else { return clearNowPlaying() }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name ?? "Unknown",
            MPMediaItemPropertyArtist: item.albumArtist ?? item.artists?.first ?? "",
            MPMediaItemPropertyAlbumTitle: item.album ?? "",
            MPMediaItemPropertyPlaybackDuration: durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: positionSeconds,
            // Zero rather than absent while paused: an absent rate leaves the
            // lock screen's scrubber running on its own after a pause.
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
        ]
        #if canImport(UIKit)
        if let artwork, artwork.itemId == (item.albumId ?? item.id) {
            info[MPMediaItemPropertyArtwork] = artwork.image
        }
        #endif
        // A NaN or infinite duration reaches MediaPlayer as a corrupt payload
        // rather than an error. A live stream and an asset whose duration is
        // still indefinite both produce one.
        info = info.filter { _, value in
            guard let number = value as? Double else { return true }
            return number.isFinite
        }
        // MediaPlayer asserts it is on the main queue here and TRAPS when it is
        // not, which is a debugger stop on no breakpoint rather than an error.
        // Being MainActor-isolated should have been enough and in practice was
        // not, so the write is routed rather than assumed. Costs nothing when
        // already on main, which is the normal case.
        //
        // nonisolated(unsafe) because the dictionary is built here, handed over
        // once, and never read or mutated again.
        nonisolated(unsafe) let payload = info
        if Thread.isMainThread {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = payload
        } else {
            DispatchQueue.main.async { MPNowPlayingInfoCenter.default().nowPlayingInfo = payload }
        }
        #endif
    }

    private func clearNowPlaying() {
        #if canImport(MediaPlayer)
        // Same main queue requirement as the setter above.
        if Thread.isMainThread {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        } else {
            DispatchQueue.main.async { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        }
        #endif
    }
}
