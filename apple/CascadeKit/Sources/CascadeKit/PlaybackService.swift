import Foundation
import AVFoundation
import Observation

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

    /// Load a track and start playing it.
    public func play(_ item: JfItem) async {
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
        if let seconds = try? await playerItem.asset.load(.duration).seconds,
           seconds.isFinite, seconds > 0 {
            guard token == loadToken else { return }
            durationSeconds = seconds
            if stream.direct && startTicks > 0 {
                await seekPlayer(to: CascadeKit.seconds(fromTicks: startTicks))
                positionSeconds = CascadeKit.seconds(fromTicks: startTicks)
            }
        }

        guard token == loadToken else { return }
        player.play()
        updateNowPlaying()
        await PlaybackReporter.start(client, state())
        startReporting()
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
        isPaused = true
        isLoading = false
        isTranscoding = false
        positionSeconds = 0
        durationSeconds = 0
        clearNowPlaying()
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
                        await self.stop()
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
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in await self?.seek(to: event.positionTime) }
            return .success
        }
        #endif
    }

    private func updateNowPlaying() {
        #if canImport(MediaPlayer)
        guard let item else { return clearNowPlaying() }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.name ?? "Unknown",
            MPMediaItemPropertyArtist: item.albumArtist ?? item.artists?.first ?? "",
            MPMediaItemPropertyAlbumTitle: item.album ?? "",
            MPMediaItemPropertyPlaybackDuration: durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: positionSeconds,
            // Zero rather than absent while paused: an absent rate leaves the
            // lock screen's scrubber running on its own after a pause.
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
        ]
        #endif
    }

    private func clearNowPlaying() {
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }
}
