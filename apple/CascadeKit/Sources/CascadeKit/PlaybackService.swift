import Foundation
import AVFoundation
import Observation

#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if canImport(UIKit)
import UIKit
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
    public var repeatMode: RepeatMode = .none
    public private(set) var shuffle = false
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

    private let player = AVPlayer()
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
    }

    /// Reorders the queue around whatever is playing. The track keeps playing
    /// untouched; only the order around it changes.
    public func toggleShuffle() {
        shuffle.toggle()
        queue = setShuffle(queue, on: shuffle)
    }

    private func load(_ item: JfItem) async {
        // Whatever was playing is finished as far as the server is concerned,
        // and its transcode, if any, is now waste.
        if self.item != nil { await reportStopped() }
        abandonEncode()
        stopReporting()

        let token = nextToken()
        self.item = item
        isPaused = false
        isLoading = true
        error = nil
        positionSeconds = 0
        durationSeconds = 0
        resolved = nil
        streamStartTicks = 0
        isTranscoding = false

        let startTicks = resumeTicks(for: item)
        let stream = await resolveStream(client: client, config: config,
                                        itemId: item.id, profile: profile, startTicks: startTicks)
        // A later play() or stop() won the race; its result is the real one.
        guard token == loadToken else { return }

        adopt(stream)

        let playerItem = AVPlayerItem(url: stream.url)
        player.replaceCurrentItem(with: playerItem)

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
        player.play()
        updateNowPlaying()
        await PlaybackReporter.start(client, state())
        startReporting()
        // The URL is built here, on the way in, so the artwork task itself never
        // touches the client actor. Not awaited: the track is already playing
        // and the art is decoration.
        let artId = item.albumId ?? item.id
        let artUrl = await client.imageUrl(itemId: artId, size: 600)
        Task { await loadArtwork(id: artId, from: artUrl) }
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
                                         profile: profile, startTicks: ticks(fromSeconds: target))
        guard token == loadToken else { return }

        adopt(stream)
        player.replaceCurrentItem(with: AVPlayerItem(url: stream.url))
        player.play()
        positionSeconds = target
        updateNowPlaying()
        reportNow()
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
        player.replaceCurrentItem(with: nil)
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
    private func handleTrackEnded() async {
        switch advanceOnEnd(length: queue.items.count, index: queue.index, repeatMode: repeatMode) {
        case .stop:
            await stop()
        case .restart:
            await seek(to: 0)
        case .play(let index):
            queue.index = index
            await load(queue.items[index])
        }
    }

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
                    for await _ in NotificationCenter.default.notifications(
                        named: AVPlayerItem.didPlayToEndTimeNotification) {
                        guard let self else { return }
                        await self.handleTrackEnded()
                    }
                }
                group.addTask {
                    // A stream that starts and then dies mid-track is what this
                    // catches. One that never starts surfaces via resolveStream.
                    for await note in NotificationCenter.default.notifications(
                        named: AVPlayerItem.failedToPlayToEndTimeNotification) {
                        guard let self else { return }
                        let underlying = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                        await MainActor.run {
                            self.error = underlying?.localizedDescription ?? "Playback failed"
                            self.isLoading = false
                        }
                    }
                }
            }
        }
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
        guard let resolved, !resolved.direct, let session = resolved.playSessionId else { return }
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

    /// Artwork for whatever is playing, kept so a position update does not
    /// re-download the image every half second.
    private var artwork: (itemId: String, image: MPMediaItemArtwork)?

    /// Fetches the album art and puts it on the lock screen and Control Center.
    ///
    /// Separate from `updateNowPlaying` because that runs on every transport
    /// change and this is a network round trip. The art arrives a moment after
    /// the track does, which is what every other music app does too.
    /// Takes the URL rather than building it, so this has exactly one
    /// suspension point. It used to `await client.imageUrl(...)` first, which
    /// hopped to the JellyfinClient actor and back, and the resumption after
    /// that hop is where the executor stopped being the main one.
    private func loadArtwork(id artId: String, from url: URL?) async {
        #if canImport(MediaPlayer) && canImport(UIKit)
        guard let url, artwork?.itemId != artId else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }

        // Guard against a slow download landing after the user skipped on.
        guard (item?.albumId ?? item?.id) == artId else { return }
        artwork = (artId, MPMediaItemArtwork(boundsSize: image.size) { requested in
            // The handler MUST return an image of the size it was asked for.
            // Returning the original regardless is the common shortcut and it
            // is a contract violation: MediaPlayer calls this repeatedly at
            // different sizes and feeds the result into an internal pipeline
            // that asserts on its own queue when the size does not match.
            guard requested != image.size else { return image }
            return UIGraphicsImageRenderer(size: requested).image { _ in
                image.draw(in: CGRect(origin: .zero, size: requested))
            }
        })
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
        if let artwork, artwork.itemId == (item.albumId ?? item.id) {
            info[MPMediaItemPropertyArtwork] = artwork.image
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
        if Thread.isMainThread {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = payload
        } else {
            DispatchQueue.main.async { MPNowPlayingInfoCenter.default().nowPlayingInfo = payload }
        }
        #endif
    }

    private func clearNowPlaying() {
        #if canImport(MediaPlayer)
        artwork = nil
        // Same main queue requirement as the setter above.
        if Thread.isMainThread {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        } else {
            DispatchQueue.main.async { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        }
        #endif
    }
}
