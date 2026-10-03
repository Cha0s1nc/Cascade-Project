import Foundation
import AVFoundation
import Observation
import Network

#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if canImport(AppKit)
import AppKit
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
    /// The queue was started from a list too long to fetch before playing
    /// (Play on a whole library) and more of it is still on the server.
    /// The queue view's "Add Next 200 Songs" shows while this is true.
    public private(set) var hasMoreQueue = false
    public private(set) var isLoadingMoreQueue = false
    public private(set) var isPaused = true
    /// Between a play() call landing and its stream actually resolving, so a
    /// view can show "loading" rather than a stale track.
    public private(set) var isLoading = false
    public private(set) var positionSeconds: Double = 0
    /// The position right now, read from the player rather than from the
    /// half-second observer behind `positionSeconds`: for the lyrics' word
    /// fill, which needs it every frame. Not observed; read it from a
    /// TimelineView or a clock of your own.
    public var livePositionSeconds: Double {
        let t = player.currentTime().seconds
        guard t.isFinite else { return positionSeconds }
        return CascadeKit.seconds(fromTicks: streamStartTicks) + t
    }
    public private(set) var durationSeconds: Double = 0
    public private(set) var error: String?
    /// 0-1, the scale AVPlayer takes. Jellyfin talks in 0-100.
    public private(set) var volume: Float = 1
    public private(set) var isMuted = false
    /// True when the server chose to transcode rather than hand over the file.
    /// Expected when Settings caps the streaming quality. At Original it
    /// should essentially never happen, so seeing it then means the device
    /// profile and the server disagree.
    public private(set) var isTranscoding = false

    /// A live radio station is playing (a Live TV channel). It has no length
    /// to scrub, no lyrics, and nothing next to prefetch, and reports nothing
    /// to the server: views read this to show LIVE instead of a time.
    public var isRadio: Bool { isRadioItem(item) }

    /// When the queue runs out, append an instant mix of 25 and play on. Not
    /// persisted: the desktop starts it off every launch too.
    public var autoMix = false

    // MARK: - Mac: output device

    /// CoreAudio device UID both decks play to; nil is the system default. A
    /// device that is not there (unplugged since it was saved, or since it was
    /// picked) falls back to the default and says so in `outputNotice`. The
    /// app persists whatever this becomes, through `onOutputDeviceChange`.
    public var outputDeviceId: String? {
        didSet {
            guard outputDeviceId != oldValue else { return }
            applyOutputDevice()
            onOutputDeviceChange?(outputDeviceId)
        }
    }
    /// Set when the chosen output vanished and playback moved to the system
    /// default. The settings row shows it; assigning nil dismisses it.
    public var outputNotice: String?
    /// Every output the Mac has right now (empty off the Mac), kept current
    /// as devices come and go.
    public private(set) var outputDevices: [AudioOutputDevice] = []
    /// Called with the new value whenever `outputDeviceId` changes, including
    /// the fall-back, so the app saves what is really in use.
    @ObservationIgnored public var onOutputDeviceChange: ((String?) -> Void)?
    /// Called when volume, shuffle or repeat change, for the app to save.
    @ObservationIgnored public var onSettingsChange: (() -> Void)?
    #if os(macOS)
    @ObservationIgnored private var deviceWatcher: AudioOutput.DeviceWatcher?
    #endif

    /// Whether a video is on, so the music service's remote commands (media
    /// keys, Control Center, AirPods) leave a paused song alone: they are
    /// registered app-wide, and a play press during a movie would otherwise
    /// start the song under it. Set by the app from its video session.
    @ObservationIgnored public var isVideoActive: (() -> Bool)?

    /// The Video equalizer profile. Held here with the music one so a single
    /// object has both; this service applies only `equalizer` (the tracks it
    /// plays), and the video player applies this one to its own audio.
    public var videoEqualizer = EQProfile()

    // MARK: - Internals

    private let client: JellyfinClient
    private let config: ServerConfig
    private let profile: DeviceProfile

    /// Downloads: a track on disk plays from there, and a play the server
    /// could not hear about is kept for later. Nil on tvOS.
    public var offline: OfflineLibrary?

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
    ///
    /// One of two decks: a crossfade starts the next track on the other one
    /// and swaps them, so `player` is always the deck that is playing `item`.
    @ObservationIgnored private var player = AVQueuePlayer()
    @ObservationIgnored private var otherDeck = AVQueuePlayer()
    /// The AVPlayerItem that belongs to `item`. Tracked here rather than read
    /// from player.currentItem, because a queue player moves that on its own,
    /// and an end notification from any other item (a track already skipped
    /// past, a preload) must not move the queue.
    private var currentPlayerItem: AVPlayerItem?
    /// The EQ and normalization on the item playing; nil for one
    /// AVFoundation will not tap (an HLS transcode). See AudioTap.
    private var currentTap: TapContext?

    /// Settings > Equalizer. Applied to what plays and what is preloaded.
    /// Turning it on or off changes whether items are tapped at all (see
    /// `tap`), so the preload is redone, and one turned on mid-track taps the
    /// playing item on the spot.
    public var equalizer = EQProfile() {
        didSet {
            currentTap?.update(profile: equalizer)
            preload?.tap?.update(profile: equalizer)
            guard equalizer.enabled != oldValue.enabled else { return }
            dropPreload()
            syncPreload()
            if equalizer.enabled, currentTap == nil, let playerItem = currentPlayerItem,
               let resolved, let item {
                Task {
                    guard let tap = await tap(playerItem, resolved), currentPlayerItem === playerItem else { return }
                    currentTap = tap
                    await applyNormalization(for: item)
                }
            }
        }
    }
    private var timeObservers: [Any] = []
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
        watchOutputDevices()
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
    ///
    /// `more`, when given, fetches the rest of the list a page at a time: the
    /// queue starts at once with `items`, and each further page is appended as
    /// the queue nears its end (see loadMoreQueue). `moreFrom` is the server
    /// offset of the first page `items` does not cover.
    public func play(_ items: [JfItem], startIndex: Int = 0,
                     more: QueuePageFetch? = nil, moreFrom: Int = 0) async {
        guard items.indices.contains(startIndex) else { return }
        if transportGate?(.replaceQueue) == true { return }
        debugLog("play \(items.count) tracks from #\(startIndex)" + (more == nil ? "" : ", more from offset \(moreFrom)"))
        queueFeed = more.map { QueueFeed(fetch: $0, next: moreFrom) }
        hasMoreQueue = more != nil
        queue = QueueOrder(items: items, index: startIndex, unshuffled: nil)
        shuffle = false
        playRequests += 1
        await load(items[startIndex])
    }

    /// Skip forward. Distinct from a track ending on its own: with repeat-one
    /// this still moves on, because a next button that refused to skip would
    /// read as broken.
    public func next() async {
        if transportGate?(.next) == true { return }
        // A station is a queue of one with nowhere to go: the same press
        // reconnects it, as on the desktop.
        if let item, isRadio { return await loadRadio(item) }
        guard let index = manualNextIndex(length: queue.items.count,
                                          index: queue.index, repeatMode: repeatMode) else {
            await stop()
            return
        }
        queue.index = index
        await load(queue.items[index])
    }

    public func previous() async {
        if transportGate?(.previous) == true { return }
        if let item, isRadio { return await loadRadio(item) }
        guard let index = manualPreviousIndex(length: queue.items.count,
                                              index: queue.index, repeatMode: repeatMode) else { return }
        queue.index = index
        await load(queue.items[index])
    }

    public func cycleRepeat() {
        repeatMode = repeatMode.next
        syncPreload()
        onSettingsChange?()
    }

    /// Restores what was saved: used at launch, before anything plays.
    public func setRepeatMode(_ mode: RepeatMode) {
        guard mode != repeatMode else { return }
        repeatMode = mode
        syncPreload()
    }

    /// Reorders the queue around whatever is playing. The track keeps playing
    /// untouched; only the order around it changes.
    public func toggleShuffle() {
        shuffle.toggle()
        queue = setShuffle(queue, on: shuffle)
        syncPreload()
        onSettingsChange?()
    }

    // MARK: - Someone else's room

    /// What a person asked the transport for, for `transportGate`.
    public enum TransportRequest {
        case playPause, next, previous, seek(Double), enqueue([JfItem]), replaceQueue
    }

    /// Set while this app is a guest in a Waterfall room, where the host owns
    /// playback: every transport entry point (the app's buttons, the lock
    /// screen, remote control) asks it first, and a true means it took the
    /// request (sent it to the host, or explained why not) and nothing plays
    /// here. The room's own following passes straight through.
    public var transportGate: ((TransportRequest) -> Bool)?

    /// Takes on a queue whose `index` is the track already playing, without
    /// restarting it: a Waterfall guest mirroring the host's queue. False
    /// when that track is not the one playing, so nothing changed.
    @discardableResult
    public func adoptQueue(_ items: [JfItem], index: Int) -> Bool {
        guard items.indices.contains(index), items[index].id == item?.id else { return false }
        queueFeed = nil
        hasMoreQueue = false
        shuffle = false
        queue = QueueOrder(items: items, index: index, unshuffled: nil)
        syncPreload()
        return true
    }

    /// The queue as shown, for a Waterfall host to publish.
    public var queueIds: [String] { queue.items.map(\.id) }

    // MARK: - Paged queue
    //
    // Play on a whole library used to wait for every song to be fetched before
    // the first one started. Now it starts with what is at hand and pulls the
    // rest in 200 at a time, so a 10,000-song library starts as fast as a
    // 20-song album.

    /// Fetches `limit` items of the list the queue came from, starting at a
    /// server offset.
    public typealias QueuePageFetch = @Sendable (_ startIndex: Int, _ limit: Int) async throws -> [JfItem]
    public static let queuePageSize = 200

    private struct QueueFeed {
        let fetch: QueuePageFetch
        var next: Int
    }
    private var queueFeed: QueueFeed?

    /// Append the next page of the list the queue came from. Runs by itself
    /// when the queue is down to its last two tracks (so the gapless preload
    /// always has a next track to take), and from the queue view's button.
    public func loadMoreQueue() async {
        guard var feed = queueFeed, !isLoadingMoreQueue else { return }
        isLoadingMoreQueue = true
        defer { isLoadingMoreQueue = false }
        let size = Self.queuePageSize
        // A few tries, not one: a page that only repeats what is already
        // queued (overlapping libraries, or a random draw) should not end the
        // feed early. Five in a row with nothing new does end it: a random
        // feed never runs dry by itself, and by then nearly every song is in.
        var added = false
        for _ in 0..<5 {
            guard let page = try? await feed.fetch(feed.next, size) else { return }   // kept; the next top-up retries
            // Replaced (a new play) or stopped while that was in flight.
            guard queueFeed?.next == feed.next else { return }
            feed.next += size
            let before = queue.items.count
            queue = appendingPage(queue, shuffle ? page.shuffled() : page)
            debugLog("queue page at offset \(feed.next - size): \(page.count) fetched, \(queue.items.count - before) new, \(queue.items.count) queued")
            if page.isEmpty {
                queueFeed = nil
                hasMoreQueue = false
            } else {
                queueFeed = feed
            }
            if queue.items.count > before { added = true }
            if added || page.isEmpty { break }
        }
        if !added, queueFeed != nil {
            queueFeed = nil
            hasMoreQueue = false
        }
        syncPreload()
    }

    /// Nearly out of queue, with more on the server: fetch it now.
    private func topUpQueueIfNeeded() {
        guard hasMoreQueue, !isLoadingMoreQueue, item != nil,
              queue.items.count - queue.index <= 2 else { return }
        Task { await loadMoreQueue() }
    }

    // MARK: - Queue edits
    //
    // The order logic is in QueueActions.swift. Each of these re-syncs the
    // gapless preload, because each can change what plays next.

    /// Right after the current track. With nothing playing, plays them. Over a
    /// station too: a live stream never ends, so anything queued behind it
    /// would never be reached.
    public func playNext(_ items: [JfItem]) async {
        guard !items.isEmpty else { return }
        if transportGate?(.enqueue(items)) == true { return }
        guard item != nil, !isRadio else { return await play(items) }
        queue = playingNext(queue, items)
        syncPreload()
    }

    /// At the end of the queue. With nothing playing, plays them.
    public func addToQueue(_ items: [JfItem]) async {
        guard !items.isEmpty else { return }
        if transportGate?(.enqueue(items)) == true { return }
        guard item != nil, !isRadio else { return await play(items) }
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
        if transportGate?(.replaceQueue) == true { return }
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

    /// `startTicks` overrides where to begin: a restored queue's saved
    /// position, which the item's own resume point knows nothing about.
    private func load(_ item: JfItem, autoplay: Bool = true, startTicks override: Int? = nil) async {
        // Whatever was playing is finished as far as the server is concerned,
        // and its transcode, if any, is now waste.
        if self.item != nil { reportStopped() }
        abandonEncode()
        closeRadioStream()
        restoredTicks = nil
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

        let startTicks = override ?? resumeTicks(for: item)
        let stream = await stream(for: item, startTicks: startTicks)
        // A later play() or stop() won the race; its result is the real one.
        guard token == loadToken else { return }

        adopt(stream)

        let playerItem = makePlayerItem(stream)
        setPlayerItem(playerItem)
        currentTap = nil

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
            currentTap = await tap(playerItem, stream)
            guard token == loadToken else { return }
            Task { await applyNormalization(for: item) }
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
        reportStart()
        startReporting()
    }

    /// Make `playerItem` the only thing the queue player holds. Not
    /// replaceCurrentItem: on a queue player that leaves whatever was queued
    /// behind it in place.
    private func setPlayerItem(_ playerItem: AVPlayerItem) {
        endCrossfade()
        dropPreload()
        player.removeAllItems()
        player.insert(playerItem, after: nil)
        currentPlayerItem = playerItem
    }

    public func pause() {
        guard item != nil, !isPaused else { return }
        if transportGate?(.playPause) == true { return }
        isPaused = true
        // A fade does not survive a pause: the tail is cut, the new track
        // resumes at full level.
        endCrossfade()
        player.pause()
        updateNowPlaying()
        reportNow()
    }

    public func resume() {
        guard let item, isPaused else { return }
        if transportGate?(.playPause) == true { return }
        // A restored queue shows the track but has loaded nothing: playing is
        // loading it, where it was left.
        if currentPlayerItem == nil, !isLoading {
            let ticks = restoredTicks
            if isRadioItem(item) {
                Task { await loadRadio(item) }
            } else {
                Task { await load(item, startTicks: ticks) }
            }
            return
        }
        // A station paused is a connection left idle, and resuming it would
        // play what was buffered, then lag behind the live edge. Tune in again.
        if isRadioItem(item) {
            Task { await loadRadio(item) }
            return
        }
        isPaused = false
        player.play()
        // A pause cuts any fade, and with it the arming of the next one.
        scheduleCrossfade()
        updateNowPlaying()
        reportNow()
    }

    public func togglePlayPause() {
        isPaused ? resume() : pause()
    }

    /// Seek to an absolute position in the current track, in seconds.
    public func seek(to seconds: Double) async {
        guard let item, !isRadio else { return }   // a live stream has no position to go to
        if transportGate?(.seek(seconds)) == true { return }
        let target = max(0, min(seconds, durationSeconds > 0 ? durationSeconds : seconds))
        // A restored queue has loaded nothing yet: the scrubber just moves the
        // place it will start from.
        guard let resolved else {
            if currentPlayerItem == nil, !isLoading, restoredTicks != nil {
                restoredTicks = ticks(fromSeconds: target)
                positionSeconds = target
            }
            return
        }

        endCrossfade()
        if resolved.direct {
            // The whole file is already there, so this costs no round trip.
            await seekPlayer(to: target)
            positionSeconds = target
            updateNowPlaying()
            reportNow()
            // A seek past the fade's start skips its boundary; arm it again
            // for where playback is now.
            scheduleCrossfade()
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
        setPlayerItem(makePlayerItem(stream))
        currentTap = nil   // a transcode, which cannot be tapped
        player.play()
        positionSeconds = target
        updateNowPlaying()
        reportNow()
        syncPreload()
    }

    /// 0-1, clamped. Persisting it is the app's business, not this service's.
    public func setVolume(_ v: Float) {
        volume = min(1, max(0, v))
        applyVolumes()
        reportNow()
        onSettingsChange?()
    }

    /// Each deck's volume: the user's, times the untapped normalization cut,
    /// times where it is in a crossfade.
    private func applyVolumes() {
        player.volume = volume * normalizationVolume * fadeIn
        if let tail { tail.deck.volume = volume * tail.normalization * fadeOut }
    }

    // MARK: - Volume normalization
    //
    // The desktop's: each track's NormalizationGain from the server, or its
    // album's in album mode (the track's own when the album has none: 10.11
    // writes one on far fewer albums than tracks). Fetched per item, since no
    // list query asks for the field, and cached. The next track's is fetched
    // while it preloads, so a gapless handover switches level on the spot.

    /// Off, by track or by album. Applied to what is playing at once.
    public var normalization: Normalization.Mode = .off {
        didSet {
            guard normalization != oldValue else { return }
            if let item { Task { await applyNormalization(for: item) } }
            // The preloaded track's gain was set for the old mode.
            dropPreload()
            syncPreload()
        }
    }

    /// The multiplier on the player itself, for an item with no tap (a
    /// transcode), where only a cut can be applied. 1 whenever the tap
    /// carries the gain.
    private var normalizationVolume: Float = 1
    /// "track:<id>" or "album:<id>" to its gain in dB, nil when it has none.
    private var gainCache: [String: Double?] = [:]

    private func gainDb(id: String, key: String) async -> Double? {
        if let hit = gainCache[key] { return hit }
        let db = (try? await client.item(id: id))?.normalizationGain
        gainCache[key] = db
        return db
    }

    private func normalizationDb(for item: JfItem) async -> Double? {
        guard normalization != .off else { return nil }
        // A downloaded track was saved with its gain, and its album's when
        // the album was downloaded too. Never the network: offline, a lookup
        // hangs until it times out and the gapless handover misses.
        if let offline, let saved = offline.savedItem(item.id) {
            if normalization == .album, let albumId = item.albumId,
               let db = offline.index.albumGains[albumId] { return db }
            return saved.normalizationGain
        }
        if normalization == .album, let albumId = item.albumId,
           let db = await gainDb(id: albumId, key: "album:\(albumId)") {
            return db
        }
        return await gainDb(id: item.id, key: "track:\(item.id)")
    }

    /// Unity first, so a track never plays at the last one's level while its
    /// own is fetched, then the real value if the track is still the one
    /// playing when it lands.
    private func applyNormalization(for item: JfItem) async {
        setNormalizationVolume(1)
        guard !isRadioItem(item) else { return }   // a station has no loudness scan
        let tap = currentTap
        guard normalization != .off else {
            tap?.update(normalization: 1)
            return
        }
        let db = await normalizationDb(for: item)
        guard self.item?.id == item.id else { return }
        if let tap {
            // In the tap a boost is possible too.
            tap.update(normalization: Normalization.linear(db: db))
        } else {
            setNormalizationVolume(Normalization.playerVolume(db: db))
        }
        debugLog("normalization \(normalization.rawValue): \(db.map { String(format: "%+.1f dB", $0) } ?? "none") for \(item.name ?? item.id)")
    }

    private func setNormalizationVolume(_ v: Float) {
        normalizationVolume = v
        applyVolumes()
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        player.isMuted = muted
        otherDeck.isMuted = muted
        reportNow()
    }

    public func stop() async {
        if item != nil { reportStopped() }
        abandonEncode()
        closeRadioStream()
        restoredTicks = nil
        stopReporting()
        _ = nextToken()          // invalidates anything still resolving
        endCrossfade()
        dropPreload()
        player.removeAllItems()
        currentPlayerItem = nil
        currentTap = nil
        resolved = nil
        streamStartTicks = 0
        item = nil
        queue = QueueOrder()
        queueFeed = nil
        hasMoreQueue = false
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
        debugLog("load failed for \(item?.name ?? "?") (\(item?.id ?? "?")): \(playerItem.error ?? thrown)")
        error = "Could not play this track: \(detail)"
        isLoading = false
        isPaused = true
    }

    /// A track finishing on its own, which is not the same as pressing next.
    private func handleTrackEnded(_ ended: ObjectIdentifier?) async {
        // Only the end of the item we are playing counts. A late one from a
        // track already skipped past would otherwise skip this one too.
        guard let ended, let currentPlayerItem, ended == ObjectIdentifier(currentPlayerItem) else { return }
        // A live stream "ending" almost always means the connection dropped,
        // not that the station finished: tune in again rather than run the
        // queue-advance logic below, which assumes a finite track. A second's
        // wait, so a server that answers and then hangs up does not spin.
        if let item, isRadio {
            let token = loadToken
            try? await Task.sleep(for: .seconds(1))
            guard token == loadToken, self.item?.id == item.id, !isPaused else { return }
            return await loadRadio(item)
        }
        if sleepTimer == .endOfTrack { return await sleepAtTrackEnd() }
        if measureHandovers { measureHandover(from: ended) }
        switch advanceOnEnd(length: queue.items.count, index: queue.index, repeatMode: repeatMode) {
        case .stop:
            // The queue ran out. With auto-mix on, keep playing from an
            // instant mix of the last track; otherwise that is the end.
            if autoMix, await continueWithAutoMix() { return }
            await stop()
        case .restart:
            // Explicit play: the item paused at its end, and a seek alone
            // left repeat-one sitting silent at 0:00 while showing "playing".
            await seek(to: 0)
            if !isPaused { player.play() }
        case .play(let index):
            if let preload, preload.index == index, preload.itemId == queue.items[index].id,
               player.items().contains(preload.playerItem) {
                handOver(to: preload)
            } else if let preload, preload.parked, preload.index == index,
                      preload.itemId == queue.items[index].id {
                // Crossfade was on but never started (a seek past its start,
                // or too little left): the parked track follows straight on.
                player.removeAllItems()
                player.insert(preload.playerItem, after: nil)
                player.play()
                handOver(to: preload)
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
        let tap: TapContext?
        /// Held back for a crossfade rather than queued behind the current
        /// item on the same deck.
        let parked: Bool
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
        guard item != nil, !isRadio, sleepTimer != .endOfTrack,
              case .play(let index) = advanceOnEnd(length: queue.items.count, index: queue.index,
                                                  repeatMode: repeatMode) else { return nil }
        let next = queue.items[index]
        guard resumeTicks(for: next) == 0 else { return nil }
        return (index, next)
    }

    /// Bring the enqueued next item in line with what should play next.
    private func syncPreload() {
        // Every track change and queue edit lands here, which makes it the
        // one place that notices the queue running low.
        topUpQueueIfNeeded()
        let want = expectedNext()
        if let want {
            if let preload, preload.index == want.index, preload.itemId == want.item.id,
               preload.parked == (crossfadeSeconds > 0),
               preload.parked || player.items().contains(preload.playerItem) { return }
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
        let stream = await stream(for: next)
        guard token == preloadToken else { return abandon(stream) }
        // Warms the gain cache, so the handover applies it without a wait.
        let db = await normalizationDb(for: next)
        let playerItem = makePlayerItem(stream)
        // Tapped with its own gain already set, so the level changes at the
        // exact sample the handover lands on.
        let nextTap = await tap(playerItem, stream)
        nextTap?.update(normalization: normalization == .off ? 1 : Normalization.linear(db: db))
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
        let parked = crossfadeSeconds > 0
        if !parked {
            player.insert(playerItem, after: current)
            player.actionAtItemEnd = .advance
        }
        preload = Preload(index: index, itemId: next.id, stream: stream,
                          playerItem: playerItem, duration: duration, tap: nextTap, parked: parked)
        preloadTarget = nil
        if parked { scheduleCrossfade() }
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
        clearCrossfadeObserver()
        guard let preload else { return }
        self.preload = nil
        if !preload.parked { player.remove(preload.playerItem) }
        abandon(preload.stream)
    }

    // MARK: - Crossfade
    //
    // The desktop's two-deck crossfade. AVQueuePlayer cannot overlap two
    // items, so with a crossfade set the next track is resolved as usual but
    // parked instead of queued, and when the current one reaches its end
    // minus the fade, it starts on the other deck and the two swap: `player`
    // becomes the new track's deck at once (Now Playing, reports and the
    // queue move on as the fade begins, as in Apple Music), and the old one
    // plays on as the tail, fading out under an equal-power curve. Anything
    // that changes what plays (a seek, a skip, pause, stop) cuts the tail.

    /// Settings > Playback > Crossfade; 0 is off, which keeps the gapless
    /// handover.
    public var crossfadeSeconds: Double = 0 {
        didSet {
            guard crossfadeSeconds != oldValue else { return }
            dropPreload()
            syncPreload()
        }
    }

    /// The deck still playing the previous track while it fades out.
    @ObservationIgnored private var tail: (deck: AVQueuePlayer, item: AVPlayerItem,
                                           stream: ResolvedStream, normalization: Float)?
    @ObservationIgnored private var fadeIn: Float = 1
    @ObservationIgnored private var fadeOut: Float = 1
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var crossfadeObserver: (deck: AVQueuePlayer, token: Any)?

    private func clearCrossfadeObserver() {
        guard let crossfadeObserver else { return }
        crossfadeObserver.deck.removeTimeObserver(crossfadeObserver.token)
        self.crossfadeObserver = nil
    }

    /// Arms the start of the fade on the current item's clock.
    private func scheduleCrossfade() {
        clearCrossfadeObserver()
        guard crossfadeSeconds > 0, let preload, preload.parked, tail == nil,
              let current = currentPlayerItem else { return }
        let length = current.duration.seconds
        guard length.isFinite, length > 0 else { return }
        let start = length - crossfadeSeconds
        let now = player.currentTime().seconds
        // The preload landed inside the window (a slow resolve, a short
        // track): start now, for what is left.
        if now.isFinite, start <= now { return beginCrossfade() }
        let token = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: max(0, start), preferredTimescale: 600))], queue: .main
        ) { [weak self] in
            // Registered on .main, so on the main actor, as with the
            // periodic observer.
            MainActor.assumeIsolated { self?.beginCrossfade() }
        }
        crossfadeObserver = (player, token)
    }

    private func beginCrossfade() {
        clearCrossfadeObserver()
        guard crossfadeSeconds > 0, !isPaused, tail == nil, let next = preload, next.parked,
              let outgoing = currentPlayerItem, let resolved else { return }
        let remaining = outgoing.duration.seconds - player.currentTime().seconds
        // Too little left: the parked track follows at the end instead.
        guard let fade = Crossfade.duration(configured: crossfadeSeconds, remaining: remaining) else { return }
        debugLog("crossfade \(String(format: "%.1f", fade)) s into #\(next.index + 1)")

        let incoming = otherDeck
        incoming.removeAllItems()
        incoming.insert(next.playerItem, after: nil)
        incoming.actionAtItemEnd = .pause
        incoming.isMuted = isMuted
        tail = (player, outgoing, resolved, normalizationVolume)
        otherDeck = player
        player = incoming
        fadeIn = 0
        fadeOut = 1
        applyVolumes()
        player.play()
        // The handover's stopped report still reads the old stream from
        // `resolved`, then adopts the new one; the tail's transcode, if any,
        // is abandoned when the tail stops.
        handOver(to: next)

        let started = ContinuousClock.now
        fadeTask = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = started.duration(to: .now)
                let progress = (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) / fade
                guard let self else { return }
                let gains = Crossfade.gains(at: progress)
                self.fadeOut = gains.out
                self.fadeIn = gains.in
                self.applyVolumes()
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled else { return }
            debugLog("crossfade done")
            self?.endCrossfade()
            // The next track, parked while this fade ran, could not arm its own.
            self?.scheduleCrossfade()
        }
    }

    /// Stops the tail and puts the playing deck at full level. Also how a
    /// fade is cut short.
    private func endCrossfade() {
        fadeTask?.cancel()
        fadeTask = nil
        if let tail {
            self.tail = nil
            tail.deck.pause()
            tail.deck.removeAllItems()
            abandon(tail.stream)
        }
        fadeIn = 1
        fadeOut = 1
        applyVolumes()
        // Never re-arms here: seek and stop call this before doing their own
        // work, and arming inside the fade window starts a fade on the spot,
        // which a seek would then land on the wrong deck and a stop would
        // leave playing. Callers that should re-arm (a fade that ran its
        // course, a seek that landed, a resume) do so themselves.
    }

    /// The player has already moved onto the preloaded item by itself; bring
    /// this object's state, the server and the lock screen along with it.
    private func handOver(to next: Preload) {
        debugLog("handover to #\(next.index + 1)")
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
        currentTap = next.tap
        adopt(next.stream)
        durationSeconds = next.duration
        let t = player.currentTime().seconds
        positionSeconds = t.isFinite ? t : 0
        error = nil
        updateNowPlaying()
        Task { await loadArtwork() }
        let current = queue.items[next.index]
        Task { await applyNormalization(for: current) }
        syncPreload()

        let client = self.client
        let report = finished
        enqueueReport { await PlaybackReporter.stopped(client, report) }
        reportStart()
        startReporting()
    }

    /// Whether to time each handover. On in debug builds; the Mac debug panel
    /// turns it on in release builds while it is open, since the timing polls
    /// the player every few milliseconds around each track change.
    #if DEBUG
    @ObservationIgnored public var measureHandovers = true
    #else
    @ObservationIgnored public var measureHandovers = false
    #endif
    /// The last handover's measure, in ms, and what it was between.
    @ObservationIgnored public private(set) var lastHandover: (ms: Double, label: String)?

    /// How long the timeline sat between one track ending and the next one
    /// producing audio: time since the end notification, minus how far the
    /// new item's clock has already run. Near zero means the next item was
    /// already playing when we heard the old one end. This is the player's
    /// timeline, not a sample-level check of the audio. Read it with
    /// `log show --predicate 'eventMessage CONTAINS "HANDOVER"'`, or in the
    /// debug panel.
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
                        let to = self.item?.name ?? "?"
                        self.lastHandover = (ms, "\(from) -> \(to)")
                        NSLog("HANDOVER %@ -> %@: %.0f ms", from, to, ms)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    // MARK: - Radio
    //
    // A Live TV channel played as a station. Its own path, not `load`: that
    // one's prefetch, resume and crossfade logic all assume a finite track, and
    // bending it around a channel (no length, no media source until
    // PlaybackInfo opens the tuner, a LiveStreamId to close afterwards) would
    // risk the ordinary path that every song goes through. The places a
    // continuous stream would trip are guarded where they are (isRadio).

    /// Tunes in to a station: a queue of one.
    public func playRadio(_ channel: JfItem) async {
        guard isRadioItem(channel) else { return }
        if transportGate?(.replaceQueue) == true { return }
        queueFeed = nil
        hasMoreQueue = false
        playRequests += 1
        await loadRadio(channel)
    }

    private func loadRadio(_ channel: JfItem) async {
        if self.item != nil { reportStopped() }
        abandonEncode()
        stopReporting()
        dropPreload()
        restoredTicks = nil
        currentPlayerItem = nil
        currentTap = nil
        // Closed before the next one opens, as on the desktop, so a retune of
        // the same channel never holds two sessions.
        await closeRadioStreamNow()

        let token = nextToken()
        item = channel
        queue = QueueOrder(items: [channel], index: 0, unshuffled: nil)
        isPaused = false
        isLoading = true
        error = nil
        positionSeconds = 0
        durationSeconds = 0
        resolved = nil
        streamStartTicks = 0
        isTranscoding = false
        setNormalizationVolume(1)

        let profile = currentProfile
        do {
            let stream = try await client.resolveRadioStream(
                channelId: channel.id, profile: profile, maxBitrate: profile.maxStreamingBitrate ?? defaultMaxBitrate)
            // Another station, a stop or a track won the race while PlaybackInfo
            // was in flight: this one's open session is nobody's now.
            guard token == loadToken else {
                await client.closeRadioStream(liveStreamId: stream.liveStreamId)
                return
            }
            radioLiveStreamId = stream.liveStreamId
            debugLog("radio \(channel.name ?? channel.id), live stream \(stream.liveStreamId ?? "none")")
            // No precise-duration option: there is no duration to be precise about.
            setPlayerItem(AVPlayerItem(asset: AVURLAsset(url: stream.url)))
            isLoading = false
            player.play()
            updateNowPlaying()
            Task { await loadArtwork() }
        } catch {
            guard token == loadToken else { return }
            // Whatever was playing before kept going while this resolved.
            player.pause()
            player.removeAllItems()
            self.error = "Could not play that station: \(error.localizedDescription)"
            isLoading = false
            isPaused = true
        }
    }

    /// The server-side tuner session behind the station that is open, if any.
    private var radioLiveStreamId: String?

    private func closeRadioStream() {
        guard let id = radioLiveStreamId else { return }
        radioLiveStreamId = nil
        let client = self.client
        // Never awaited: leaving a station should be instant, and a session
        // the server never hears about costs it a process, not correctness.
        Task.detached { await client.closeRadioStream(liveStreamId: id) }
    }

    private func closeRadioStreamNow() async {
        guard let id = radioLiveStreamId else { return }
        radioLiveStreamId = nil
        await client.closeRadioStream(liveStreamId: id)
    }

    // MARK: - Auto-mix

    /// The queue just ran out: append an instant mix of 25 from the last
    /// track and play on. False when there is nothing to continue with, and
    /// the caller stops as usual. Music only, and never for a Waterfall guest,
    /// whose queue is the host's.
    private func continueWithAutoMix() async -> Bool {
        guard let seed = item, seed.type == "Audio", transportGate == nil else { return false }
        let token = loadToken
        guard let mix = try? await client.instantMix(seedId: seed.id, limit: 25) else { return false }
        // Something else took over while the mix was fetched.
        guard token == loadToken, item?.id == seed.id else { return false }
        let fresh = mix.filter { $0.id != seed.id }
        guard !fresh.isEmpty else { return false }
        let start = queue.items.count
        queue = appending(queue, fresh)
        queue.index = start
        debugLog("auto-mix added \(fresh.count) tracks after \(seed.name ?? seed.id)")
        await load(queue.items[start])
        return true
    }

    // MARK: - Saving and restoring the queue

    /// Where a restored queue will start from, in ticks: set while a queue is
    /// shown but nothing is loaded, and spent by the first play.
    private var restoredTicks: Int?

    /// What to keep of the queue across a restart; nil when there is nothing
    /// worth keeping (nothing playing, a video, a station). A station is left
    /// out rather than saved as nothing, so quitting while one plays does not
    /// erase the last music queue.
    public func savedQueue() -> SavedQueue? {
        guard item != nil, !isRadio else { return nil }
        return savedQueueOf(queue.items, index: queue.index, positionSec: positionSeconds,
                            unshuffled: queue.unshuffled ?? [])
    }

    /// Shows a queue from a previous launch without playing it: no stream is
    /// resolved, nothing is reported to the server, no lock screen entry is
    /// made. Play then loads the current track where it was left. Refused when
    /// anything else has started meanwhile, since the person's own play wins.
    public func adoptRestoredQueue(_ restored: RestoredQueue, shuffled: Bool, repeatMode mode: RepeatMode) {
        guard item == nil, queue.items.isEmpty, !isLoading else { return }
        queueFeed = nil
        hasMoreQueue = false
        shuffle = shuffled
        repeatMode = mode
        queue = QueueOrder(items: restored.queue, index: restored.index,
                           unshuffled: shuffled ? (restored.unshuffled.isEmpty ? restored.queue : restored.unshuffled) : nil)
        item = queue.current
        isPaused = true
        positionSeconds = restored.positionSec
        durationSeconds = Double(item?.runTimeTicks ?? 0) / ticksPerSecond
        restoredTicks = ticks(fromSeconds: restored.positionSec)
    }

    // MARK: - Output device

    private var outputNames: [String: String] = [:]

    private func watchOutputDevices() {
        #if os(macOS)
        refreshOutputDevices()
        deviceWatcher = AudioOutput.watchDevices(Self.deviceHandler { [weak self] in self?.refreshOutputDevices() })
        #endif
    }

    /// Built outside main-actor isolation for the reason `pathHandler` is:
    /// CoreAudio owns the queue this is called on.
    nonisolated private static func deviceHandler(_ apply: @escaping @MainActor @Sendable () -> Void) -> @Sendable () -> Void {
        { Task { @MainActor in apply() } }
    }

    private func refreshOutputDevices() {
        #if os(macOS)
        outputDevices = AudioOutput.devices()
        for d in outputDevices { outputNames[d.id] = d.name }
        applyOutputDevice()
        #endif
    }

    private func applyOutputDevice() {
        #if os(macOS)
        let target = AudioOutput.resolve(wanted: outputDeviceId, available: outputDevices.map(\.id))
        if target.vanished, let gone = outputDeviceId {
            outputNotice = "\(outputNames[gone] ?? "The selected output") is no longer available, so sound is playing on the system default."
            outputDeviceId = nil   // applies the default and tells the app to save it
            return
        }
        // Both decks, since a crossfade swaps which one plays.
        for deck in [player, otherDeck] { deck.audioOutputDeviceUniqueID = target.id }
        #endif
    }

    // MARK: - Debug panel

    /// What the player is doing, for the Mac debug panel: play method,
    /// decks, crossfade, prefetch, tap, last handover.
    public func debugLines() -> [String] {
        var lines: [String] = []
        func status(_ p: AVQueuePlayer) -> String {
            let s = p.timeControlStatus == .playing ? "playing" : p.timeControlStatus == .paused ? "paused" : "waiting"
            return "\(s) \(p.items().count) queued, volume \(String(format: "%.2f", p.volume))"
        }
        guard let item else {
            lines.append("nothing playing")
            lines.append("deck A: \(status(player))")
            return lines
        }
        let method: String
        if isRadio { method = "live radio" }
        else if let resolved { method = resolved.playSessionId == nil && resolved.direct ? "local file" : resolved.direct ? "direct play" : "transcode (HLS)" }
        else { method = isLoading ? "resolving" : "not loaded (restored queue)" }
        lines.append("now: \(item.name ?? item.id), #\(queue.index + 1) of \(queue.items.count)")
        lines.append("method: \(method), container \(item.mediaSources?.first?.container ?? "unknown")")
        lines.append("deck A (current): \(status(player))")
        lines.append("deck B: \(status(otherDeck))")
        if crossfadeSeconds > 0 {
            lines.append("crossfade: \(Int(crossfadeSeconds)) s" + (tail == nil ? ", idle" : String(format: ", fading (in %.2f, out %.2f)", fadeIn, fadeOut)))
        } else {
            lines.append("crossfade: off (gapless)")
        }
        if let preload {
            lines.append("prefetch: #\(preload.index + 1) \(preload.parked ? "parked for crossfade" : "queued"), \(preload.stream.direct ? "direct" : "transcode"), tap \(preload.tap == nil ? "none" : "on")")
        } else if let preloadTarget {
            lines.append("prefetch: resolving #\(preloadTarget.index + 1)")
        } else {
            lines.append("prefetch: none")
        }
        lines.append("equalizer: " + (equalizer.enabled ? "on" : "off") + ", tap " + (currentTap == nil ? "none" : "attached")
                     + (resolved.map { !$0.direct && equalizer.enabled ? " (transcodes cannot be tapped)" : "" } ?? ""))
        lines.append("normalization: \(normalization.rawValue)")
        lines.append("output: " + (outputDeviceId.flatMap { outputNames[$0] } ?? "system default")
                     + String(format: ", volume %.0f%%", volume * 100) + (isMuted ? ", muted" : ""))
        lines.append("quality: \(streamingQuality.label)\(onExpensiveNetwork ? " (cellular: \(cellularQuality.label))" : "")")
        if let lastHandover {
            lines.append(String(format: "last handover: %.0f ms, %@", lastHandover.ms, lastHandover.label))
        } else {
            lines.append(measureHandovers ? "last handover: none yet" : "last handover: timing off")
        }
        if let radioLiveStreamId { lines.append("live stream: \(radioLiveStreamId)") }
        return lines
    }

    // MARK: - Wiring

    private func nextToken() -> Int {
        loadToken += 1
        return loadToken
    }

    private func adopt(_ stream: ResolvedStream) {
        debugLog("now \(item?.name ?? "?") (\(item?.id ?? "?")), \(stream.direct ? "direct" : "transcode"), #\(queue.index + 1) of \(queue.items.count)")
        resolved = stream
        streamStartTicks = stream.startTicks
        isTranscoding = !stream.direct
        isLoading = false
    }

    /// A player item for a stream. A direct stream is the file itself, and
    /// without PreferPreciseDurationAndTiming AVFoundation seeks in one by
    /// guessing a byte offset from the average bitrate, then reports the time
    /// it was asked for rather than where it landed. For a FLAC with no
    /// SEEKTABLE (common: ffmpeg writes none) and cover art ahead of the
    /// audio, that guess was 1 to 4 s out, different on every seek, so
    /// lyrics ran early or late after tapping a line, scrubbing or resuming.
    /// Measured on such a file: default seeks landed -3.4 to +3.9 s from the
    /// reported time; precise ones all within 10 ms of each other, with no
    /// slower start. A transcode (HLS) is seeked by the server instead.
    /// A tap for a direct stream while the EQ is on, carrying it as it
    /// stands. None for a transcode, which AVFoundation plays as HLS and will
    /// not tap, and none while the EQ is off: a tapped item costs the gapless
    /// handover. Measured in the simulator on the player's clock, from one
    /// track's end to the next one running: 58 and 67 ms untapped, 422 and
    /// 430 ms with pre-effects taps, 262 and 256 ms with post-effects ones.
    /// So the EQ, and the normalization boosts that ride on it, come with a
    /// short pause between tracks, and everyone else keeps gapless.
    private func tap(_ playerItem: AVPlayerItem, _ stream: ResolvedStream) async -> TapContext? {
        guard stream.direct, equalizer.enabled else { return nil }
        let context = TapContext()
        context.update(profile: equalizer)
        return await AudioTap.attach(context, to: playerItem) ? context : nil
    }

    private func makePlayerItem(_ stream: ResolvedStream) -> AVPlayerItem {
        let options: [String: Any]? = stream.direct ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : nil
        return AVPlayerItem(asset: AVURLAsset(url: stream.url, options: options))
    }

    private func seekPlayer(to seconds: Double) async {
        await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func observePlayer() {
        // Position comes from the player rather than a wall clock, so pausing,
        // buffering and rate changes are all accounted for without extra code.
        // On both decks; only the one playing `item` moves the position.
        for deck in [player, otherDeck] {
            let id = ObjectIdentifier(deck)
            timeObservers.append(deck.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                // assumeIsolated is safe HERE, unlike in the remote command
                // handlers below, because this observer was registered with
                // queue: .main and the main dispatch queue is the main actor's
                // executor. Keeping it avoids hopping through a Task twice a
                // second just to move a progress bar.
                MainActor.assumeIsolated {
                    guard let self, time.isNumeric, ObjectIdentifier(self.player) == id else { return }
                    self.positionSeconds = CascadeKit.seconds(fromTicks: self.streamStartTicks) + time.seconds
                }
            })
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
        } catch {
            // Not fatal: audio still plays in the foreground, so this is worth
            // surfacing rather than trapping.
            self.error = "Audio session: \(error.localizedDescription)"
        }
        // Activating can block while iOS settles the session with other audio
        // apps, and Xcode's hang checker flagged it on the main actor. Off it,
        // it cannot stall the UI; the player activates the session itself if
        // playback starts first. (activate(options:) is the async form, but
        // only from iOS 27.)
        Task.detached {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                debugLog("audio session did not activate: \(error)")
                await MainActor.run { self.error = "Audio session: \(error.localizedDescription)" }
            }
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
        guard !isRadio else { return }
        let snapshot = state()
        Task { await PlaybackReporter.progress(client, snapshot) }
    }

    /// Start and stopped reports go out in order but never hold up
    /// playback: with the server unreachable (a tailnet down, a LAN-only
    /// server on cellular) each one hangs until it times out, and awaiting
    /// them held a track change, or even Stop, for up to a minute.
    @ObservationIgnored private var reportChain: Task<Void, Never>?

    private func enqueueReport(_ work: @escaping @Sendable () async -> Void) {
        let previous = reportChain
        reportChain = Task { await previous?.value; await work() }
    }

    private func reportStopped() {
        // A channel has no finite position to report, and the server has
        // nothing to do with a played-state update against a TvChannel.
        guard !isRadio else { return }
        let snapshot = state()
        let client = self.client
        enqueueReport { await PlaybackReporter.stopped(client, snapshot) }
    }

    /// Jellyfin counts a play on this report, not the stopped one, so one
    /// that fails is kept to send later; one that lands means the server is
    /// back and anything kept can go.
    private func reportStart() {
        guard !isRadio else { return }
        let snapshot = state()
        let client = self.client
        let userId = config.userId
        let offline = self.offline
        let startedAt = Date()
        enqueueReport {
            if await PlaybackReporter.start(client, snapshot) {
                await offline?.replayPlays(client: client)
            } else {
                await offline?.recordPlay(snapshot.itemId, userId: userId, at: startedAt)
            }
        }
    }

    /// The downloaded file when there is one, else a stream from the server.
    private func stream(for item: JfItem, startTicks: Int = 0) async -> ResolvedStream {
        if let file = offline?.localFile(item.id) {
            return ResolvedStream(url: file, playSessionId: nil, mediaSourceId: nil, direct: true, startTicks: 0)
        }
        return await resolveStream(client: client, config: config, itemId: item.id,
                                   profile: currentProfile, startTicks: startTicks)
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
        // Every handler checks whether a video is on. These targets are
        // registered app-wide and outlive a movie, so without the check a media
        // key or an AirPods squeeze during one would start the paused song (or
        // skip to another) under the film. Checked on main, where the answer
        // lives, not here on MediaPlayer's queue.
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isVideoActive?() != true { self?.resume() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isVideoActive?() != true { self?.pause() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isVideoActive?() != true { self?.togglePlayPause() } }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isVideoActive?() != true { await self?.next() } }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isVideoActive?() != true { await self?.previous() } }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in if self?.isVideoActive?() != true { await self?.seek(to: event.positionTime) } }
            return .success
        }
        // Off unless asked for: on the Mac, the system hands the media keys to
        // whichever app has these enabled and is the Now Playing app.
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = true
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

    #if canImport(MediaPlayer) && (canImport(UIKit) || canImport(AppKit))
    /// Artwork for whatever is playing, kept so a position update does not
    /// download it again. Keyed by the art's item id (the album, usually), so
    /// the next track on the same album reuses it.
    private var artwork: (itemId: String, image: MPMediaItemArtwork)?

    #if canImport(UIKit)
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Decoded off the main thread, rather than by MediaPlayer at draw time,
    /// where a damaged file only surfaced as ImageIO's anonymous
    /// "decompressing image -- possibly corrupt".
    nonisolated private static func decodeArt(_ data: Data) async -> UIImage? {
        guard let parsed = UIImage(data: data) else { return nil }
        return await parsed.byPreparingForDisplay()
    }
    #else
    // The Mac's lock screen and Control Center take an NSImage. Built here,
    // outside main-actor isolation, for the same reason as the UIKit one:
    // MediaPlayer calls the handler on its own queue.
    nonisolated private static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// AppKit decodes lazily, so asking for the CGImage here is what proves
    /// the bytes are an image at all, and does that work off the main thread.
    nonisolated private static func decodeArt(_ data: Data) async -> NSImage? {
        guard let image = NSImage(data: data),
              image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else { return nil }
        return image
    }
    #endif
    #endif

    /// Fetch the current item's art for the lock screen. Separate from
    /// updateNowPlaying because that runs on every transport change and this
    /// is a download. The art lands a moment after the track, as it does in
    /// every other music app. Not awaited by callers: decoration only.
    private func loadArtwork() async {
        #if canImport(MediaPlayer) && (canImport(UIKit) || canImport(AppKit))
        guard let item else { return }
        let artId = item.albumId ?? item.id
        guard artwork?.itemId != artId else { return }
        if let file = offline?.artFile(artId), let data = try? Data(contentsOf: file),
           let image = await Self.decodeArt(data) {
            guard (self.item?.albumId ?? self.item?.id) == artId else { return }
            artwork = (artId, Self.makeArtwork(image))
            return updateNowPlaying()
        }
        guard let url = await client.imageUrl(itemId: artId, size: 600),
              let (data, response) = try? await URLSession.shared.data(from: url) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status != 404 { debugLog("lock screen art for item \(artId): HTTP \(status)") }
            return
        }
        guard let image = await Self.decodeArt(data) else {
            debugLog("lock screen art for item \(artId) (\(item.album ?? item.name ?? "?")) did not decode: \(data.count) bytes, \(response.mimeType ?? "no type")")
            return
        }
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
        #if canImport(UIKit) || canImport(AppKit)
        if let artwork, artwork.itemId == (item.albumId ?? item.id) {
            info[MPMediaItemPropertyArtwork] = artwork.image
        }
        #endif
        if isRadio {
            // No length, and no position that means anything: the system
            // shows it as live rather than a scrubber stuck at zero.
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
            info[MPMediaItemPropertyPlaybackDuration] = nil
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nil
        }
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
        let paused = isPaused
        if Thread.isMainThread {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = payload
            Self.setPlaybackState(paused ? .paused : .playing)
        } else {
            DispatchQueue.main.async {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = payload
                Self.setPlaybackState(paused ? .paused : .playing)
            }
        }
        #endif
    }

    private func clearNowPlaying() {
        #if canImport(MediaPlayer)
        // Same main queue requirement as the setter above.
        if Thread.isMainThread {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            Self.setPlaybackState(.stopped)
        } else {
            DispatchQueue.main.async {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                Self.setPlaybackState(.stopped)
            }
        }
        #endif
    }

    #if canImport(MediaPlayer)
    /// On the Mac the system decides which app the media keys go to from this
    /// state, not from the info dictionary: an app that never sets it is not
    /// offered the play/pause key. iOS works it out from the audio session and
    /// ignores this.
    nonisolated private static func setPlaybackState(_ state: MPNowPlayingPlaybackState) {
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = state
        #endif
    }
    #endif
}
