import SwiftUI
import AVKit
import CascadeKit

/// One movie or run of episodes playing: the desktop's playVideo. Apart from
/// the music PlaybackService on purpose: that one is built around gapless
/// audio decks, the lock screen's music controls and the queue, none of which
/// a movie wants. Apple's player view does the drawing; on the Mac the
/// controls are our own (App/Mac/MacVideoControls.swift) and read from here.
@MainActor
@Observable
final class VideoSession {
    let player = AVPlayer()
    private(set) var item: JfItem?
    private(set) var error: String?
    /// Set when the last episode ends, so the player closes itself.
    private(set) var finished = false
    /// A stream is being negotiated or has not started yet.
    private(set) var isLoading = false
    /// Where playback is in the item, in seconds, refreshed a few times a
    /// second. A transcode's own clock may start elsewhere; this never does.
    private(set) var position: Double = 0
    private(set) var isPlaying = false
    private(set) var rate: Double = 1
    private(set) var chapters: [Chapter] = []
    /// What the subtitle picker lists, default and forced first. Empty when
    /// the stream carries none (picture subtitles are burned in, not listed).
    private(set) var subtitles: [SubtitleChoice] = []
    /// The `SubtitleChoice.id` showing, nil for off.
    private(set) var subtitleSelection: Int?
    /// The audio stream asked for: the person's pick, or the one forced
    /// because the file's own default is a codec this player lacks.
    private(set) var audioIndex: Int?
    /// True while the scrubber is being dragged, so the clock stops moving it.
    var isScrubbing = false

    private let client: JellyfinClient
    private let config: ServerConfig
    private var queue: [JfItem] = []
    private(set) var index = 0
    @ObservationIgnored private var pickedAudio: (index: Int, language: String?)?
    @ObservationIgnored private var resolved: ResolvedStream?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0

    // Subtitles. The options are AVFoundation's own (an HLS manifest's
    // subtitle group, or a file's text tracks), not Jellyfin's stream
    // indices, which they do not map back to reliably.
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleOptions: [AVMediaSelectionOption] = []
    private enum SubtitlePick { case unset, off, track(String) }
    /// What the person last chose, by label, so the next episode (or the same
    /// one after an audio switch) comes up the same way.
    @ObservationIgnored private var subtitlePick = SubtitlePick.unset
    /// The track C turns back on.
    @ObservationIgnored private var lastSubtitle = 0

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusWatch: NSKeyValueObservation?
    @ObservationIgnored private var itemWatch: NSKeyValueObservation?
    @ObservationIgnored private var pendingSkip: Double?
    @ObservationIgnored private var skipTask: Task<Void, Never>?

    // The Video EQ: a tap on the item, only for a direct stream (AVFoundation
    // will not tap an HLS transcode, which is what an MKV becomes).
    @ObservationIgnored private var tap: TapContext?
    private(set) var equalizer = EQProfile()

    /// The app's volume and mute, shared with music as on the desktop (one
    /// choke point), when the app hands it over. Nil: the player's own.
    @ObservationIgnored private weak var audio: PlaybackService?

    init(client: JellyfinClient, config: ServerConfig) {
        self.client = client
        self.config = config
        // AVPlayer's own default already follows the system's caption
        // preferences (Settings > Accessibility > Subtitles & Captioning).
        player.appliesMediaSelectionCriteriaAutomatically = true
        statusWatch = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let paused = player.timeControlStatus == .paused
            Task { @MainActor in self?.isPlaying = !paused }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            // The queue is main, so this is already isolated; the closure just
            // is not declared that way.
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard !isScrubbing, pendingSkip == nil, item != nil, !isLoading else { return }
        position = livePosition
    }

    // MARK: - Starting

    /// `resume` picks up at the saved position; otherwise from the start.
    func play(_ items: [JfItem], startIndex: Int = 0, audioStreamIndex: Int? = nil, resume: Bool = true) async {
        guard items.indices.contains(startIndex) else { return }
        queue = items
        index = startIndex
        finished = false
        pickedAudio = audioStreamIndex.map { picked in
            (picked, items[startIndex].mediaStreams?.first { $0.index == picked }?.language)
        }
        await load(startTicks: resume ? resumeTicks(for: items[startIndex]) : 0, autoplay: true)
    }

    /// Follows the app's volume and mute (Mac), so Up and Down, the Playback
    /// menu and the player bar's slider all move the same value.
    func follow(_ service: PlaybackService?) {
        audio = service
        syncVolume()
    }

    private func syncVolume() {
        guard let audio else { return }
        withObservationTracking {
            player.volume = audio.volume
            player.isMuted = audio.isMuted
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncVolume() }
        }
    }

    var volume: Float { audio?.volume ?? player.volume }
    var isMuted: Bool { audio?.isMuted ?? player.isMuted }

    func setVolume(_ v: Float) {
        let clamped = min(1, max(0, v))
        if let audio { audio.setVolume(clamped) } else { player.volume = clamped }
    }

    func toggleMute() {
        if let audio { audio.setMuted(!audio.isMuted) } else { player.isMuted.toggle() }
    }

    /// `startTicks` is where in the item to begin. A transcode asked to start
    /// partway in was the old way of resuming; an HLS playlist spans the whole
    /// item, so now everything begins at 0 and seeks.
    private func load(startTicks start: Int, autoplay: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        await reportStopped()
        guard generation == loadGeneration, queue.indices.contains(index) else { return }
        let item = queue[index]
        let sameItem = self.item?.id == item.id
        self.item = item
        error = nil
        isLoading = true
        position = seconds(fromTicks: start)
        pendingSkip = nil
        if !sameItem {
            chapters = []
            subtitles = []
            subtitleSelection = nil
            Task { [weak self] in
                guard let self else { return }
                let found = await client.chapters(of: item)
                if self.item?.id == item.id { self.chapters = found }
            }
        }
        audioIndex = pickedAudioIndex(for: item)
        do {
            let stream = try await VideoPlayback.resolve(client: client, config: config, item: item,
                                                         audioStreamIndex: audioIndex, startTicks: start)
            guard generation == loadGeneration else { return }
            resolved = stream
            // Precise timing on a direct file, as the music side learned: a
            // file with no index otherwise seeks seconds off its target.
            let options: [String: Any]? = stream.direct ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : nil
            let playerItem = AVPlayerItem(asset: AVURLAsset(url: stream.url, options: options))
            tap = nil
            if stream.direct, equalizer.enabled {
                let context = TapContext()
                context.update(profile: equalizer)
                if await AudioTap.attach(context, to: playerItem) { tap = context }
                guard generation == loadGeneration else { return }
            }
            player.replaceCurrentItem(with: playerItem)
            watch(playerItem, generation: generation)
            // Direct files and HLS playlists both begin at 0: seek to where
            // the person was.
            if stream.startTicks == 0, start > 0 {
                player.seek(to: CMTime(seconds: seconds(fromTicks: start), preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }
            player.defaultRate = Float(rate)
            if autoplay { player.play() }
            isLoading = false
            _ = await PlaybackReporter.start(client, state(positionTicks: start))
            guard generation == loadGeneration else { return }
            startReporting()
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    /// The audio stream to request for `item`: the person's pick (matched by
    /// language when this is another episode, whose stream numbering may
    /// differ), else the one forced when the file's default track is a codec
    /// this player lacks, else the server's choice.
    private func pickedAudioIndex(for item: JfItem) -> Int? {
        if let pick = pickedAudio {
            let tracks = VideoPlayback.audioTracks(item)
            if tracks.contains(where: { $0.index == pick.index && $0.language == pick.language }) { return pick.index }
            if let language = pick.language, let match = tracks.first(where: { $0.language == language }) { return match.index }
        }
        return neededAudioStreamIndex(item.mediaStreams, decodable: DeviceProfile.appleVideo.videoDirectPlayAudioCodecs)
    }

    // MARK: - Where it is

    /// The position in the item, in ticks: a transcode's clock starts where
    /// it was asked to.
    private func positionTicks() -> Int {
        let t = player.currentTime().seconds
        return (resolved?.startTicks ?? 0) + ticks(fromSeconds: t.isFinite ? t : 0)
    }

    /// The position right now, from the player rather than the sampled one.
    var livePosition: Double { seconds(fromTicks: positionTicks()) }

    /// The item's length. The server's runtime when it gave one: an HLS
    /// item's own duration grows as the playlist is read.
    var duration: Double {
        if let t = item?.runTimeTicks, t > 0 { return seconds(fromTicks: t) }
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    private func state(positionTicks override: Int? = nil) -> PlaybackState {
        PlaybackState(itemId: item?.id ?? "", positionTicks: override ?? positionTicks(), isPaused: player.rate == 0,
                      playSessionId: resolved?.playSessionId, mediaSourceId: resolved?.mediaSourceId,
                      playMethod: resolved?.playMethod ?? .directPlay, mediaType: "Video")
    }

    private func startReporting() {
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: progressInterval)
                guard let self, self.item != nil else { return }
                await PlaybackReporter.progress(self.client, self.state())
            }
        }
    }

    /// Where the person stopped is what the server resumes from next time.
    private func reportStopped() async {
        reportTask?.cancel()
        guard item != nil, let resolved else { return }
        let snapshot = state()
        self.resolved = nil
        await PlaybackReporter.stopped(client, snapshot)
        if !resolved.direct { await stopActiveEncoding(client: client, config: config, playSessionId: resolved.playSessionId) }
    }

    // MARK: - Watching the item

    private func watch(_ playerItem: AVPlayerItem, generation: Int) {
        endTask?.cancel()
        endTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification,
                                                                    object: playerItem) {
                guard let self else { return }
                await self.advance()
                return
            }
        }
        itemWatch = playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let failed = observed.status == .failed
            let message = observed.error?.localizedDescription
            Task { @MainActor in
                guard let self, generation == self.loadGeneration, failed else { return }
                self.error = message ?? "This video could not be played."
            }
        }
        Task { [weak self] in await self?.loadSubtitles(for: playerItem, generation: generation) }
    }

    /// The next episode, from its start, or the end.
    private func advance() async {
        guard index + 1 < queue.count else {
            await stop()
            finished = true
            return
        }
        index += 1
        await load(startTicks: 0, autoplay: true)
    }

    var hasNext: Bool { index + 1 < queue.count }
    var hasPrevious: Bool { index > 0 }

    func next() async {
        guard hasNext else { return }
        index += 1
        await load(startTicks: 0, autoplay: true)
    }

    func previous() async {
        guard hasPrevious else { return }
        index -= 1
        await load(startTicks: 0, autoplay: true)
    }

    func stop() async {
        loadGeneration += 1
        endTask?.cancel()
        skipTask?.cancel()
        player.pause()
        await reportStopped()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        tap = nil
        item = nil
    }

    // MARK: - Transport

    func togglePlayPause() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    /// Seeks inside the item. Exact, not to the nearest keyframe: a skip of
    /// five seconds should land five seconds on.
    func seek(to target: Double) {
        let total = duration
        let t = max(0, total > 0 ? min(total, target) : target)
        pendingSkip = nil
        skipTask?.cancel()
        position = t
        let clock = t - seconds(fromTicks: resolved?.startTicks ?? 0)
        player.seek(to: CMTime(seconds: max(0, clock), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
    }

    /// Jump by `delta` seconds. A direct file moves at once. A transcode's
    /// every landing costs the server a new encode, so a run of taps is
    /// collected and sent once, after the last one; the clock follows each tap
    /// so the run stays legible.
    func skip(by delta: Double) {
        let total = duration
        guard total > 0 else { return }
        if resolved?.direct != false {
            seek(to: VideoControls.skipTarget(from: livePosition, by: delta, duration: total))
            return
        }
        let target = VideoControls.skipTarget(from: pendingSkip ?? livePosition, by: delta, duration: total)
        pendingSkip = target
        position = target
        skipTask?.cancel()
        skipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(VideoControls.skipBatchDelay))
            guard !Task.isCancelled, let self else { return }
            self.seek(to: target)
        }
    }

    /// One frame while paused, at the film's own rate when the server said.
    func step(forward: Bool) {
        guard player.timeControlStatus == .paused, let current = player.currentItem else { return }
        if forward ? current.canStepForward : current.canStepBackward {
            current.step(byCount: forward ? 1 : -1)
        } else {
            // An HLS stream often cannot step back; a tiny seek is the next best.
            let fps = item?.mediaStreams?.first { $0.type == "Video" }?.realFrameRate
            let frame = VideoControls.frameDuration(fps: fps)
            seek(to: livePosition + (forward ? frame : -frame))
        }
    }

    func setRate(_ r: Double) {
        rate = r
        player.defaultRate = Float(r)
        if player.timeControlStatus != .paused { player.rate = Float(r) }
    }

    /// Previous or next chapter, from where it is. Returns the chapter landed on.
    @discardableResult
    func jumpChapter(forward: Bool) -> Chapter? {
        guard let target = chapterTarget(chapters, livePosition, forward: forward) else { return nil }
        seek(to: target)
        let at = chapterAt(chapters, target)
        return chapters.indices.contains(at) ? chapters[at] : nil
    }

    // MARK: - Audio track

    /// The audio stream playing, for the picker's tick: the one asked for, or
    /// the file's own default.
    var audioTracks: [JfMediaStream] { item.map(VideoPlayback.audioTracks) ?? [] }

    var currentAudioIndex: Int? {
        let tracks = item.map(VideoPlayback.audioTracks) ?? []
        return audioIndex ?? (tracks.first { $0.isDefault == true } ?? tracks.first)?.index
    }

    /// A different audio track is a different stream from the server (it
    /// honors a track only alongside the media source id, and the transcode
    /// carries that one alone), so playback restarts where it was. Stays
    /// paused if it was paused.
    func selectAudio(_ streamIndex: Int) async {
        guard let item, streamIndex != currentAudioIndex else { return }
        pickedAudio = (streamIndex, VideoPlayback.audioTracks(item).first { $0.index == streamIndex }?.language)
        let wasPlaying = player.timeControlStatus != .paused
        await load(startTicks: ticks(fromSeconds: pendingSkip ?? livePosition), autoplay: wasPlaying)
    }

    // MARK: - Subtitles

    private func loadSubtitles(for playerItem: AVPlayerItem, generation: Int) async {
        guard let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible),
              generation == loadGeneration else { return }
        let options = group.options
        legibleGroup = group
        legibleOptions = options
        subtitles = orderedSubtitles(options.enumerated().map { i, option in
            SubtitleChoice(id: i, label: option.displayName,
                           isDefault: group.defaultOption == option,
                           isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
        })
        // The system picks one on its own once the item is ready; wait for
        // that rather than reading before it has happened.
        for _ in 0..<30 where playerItem.status == .unknown {
            try? await Task.sleep(for: .milliseconds(100))
            guard generation == loadGeneration else { return }
        }
        switch subtitlePick {
        case .unset: break
        case .off: playerItem.select(nil, in: group)
        case .track(let label):
            if let match = options.first(where: { $0.displayName == label }) { playerItem.select(match, in: group) }
        }
        refreshSubtitleSelection()
    }

    private func refreshSubtitleSelection() {
        guard let group = legibleGroup, let current = player.currentItem,
              let option = current.currentMediaSelection.selectedMediaOption(in: group),
              let i = legibleOptions.firstIndex(of: option) else {
            subtitleSelection = nil
            return
        }
        subtitleSelection = i
    }

    /// Off, or a `SubtitleChoice.id`. Remembered for the next item.
    func selectSubtitle(_ id: Int?) {
        guard let group = legibleGroup, let current = player.currentItem else { return }
        if let id, legibleOptions.indices.contains(id) {
            current.select(legibleOptions[id], in: group)
            subtitlePick = .track(legibleOptions[id].displayName)
            lastSubtitle = id
        } else {
            if let showing = subtitleSelection { lastSubtitle = showing }
            current.select(nil, in: group)
            subtitlePick = .off
        }
        refreshSubtitleSelection()
    }

    /// C: off and back on to the last pick. Returns what to say, or nil when
    /// there is nothing to toggle.
    func toggleSubtitles() -> String? {
        guard let result = toggledSubtitle(showing: subtitleSelection, remembered: lastSubtitle, count: legibleOptions.count) else {
            return nil
        }
        lastSubtitle = result.remembered
        selectSubtitle(result.selection)
        return result.selection.map { legibleOptions[$0].displayName } ?? "Subtitles off"
    }

    // MARK: - Equalizer

    /// The Video EQ curve. Live: a curve change moves the tap already on the
    /// item, and switching it on mid-film taps the item playing (direct
    /// streams only, as at load).
    func setEqualizer(_ profile: EQProfile) {
        equalizer = profile
        if let tap {
            tap.update(profile: profile)
        } else if profile.enabled, resolved?.direct == true, let current = player.currentItem {
            let context = TapContext()
            context.update(profile: profile)
            Task { [weak self] in
                if await AudioTap.attach(context, to: current), self?.player.currentItem === current { self?.tap = context }
            }
        }
    }

    /// Whether the EQ is actually on the audio: it is off for a transcode.
    var equalizerActive: Bool { tap != nil && equalizer.enabled }
}

#if os(macOS)
/// Apple's picture, with our own controls over it (App/Mac/MacVideoControls):
/// AVPlayerView's scrubber cannot show chapter ticks, host our subtitle and
/// audio pickers, or share its idle timer with the window's traffic lights.
/// It still draws the video and the subtitles.
struct VideoPlayerView: NSViewRepresentable {
    let session: VideoSession

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = session.player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== session.player { view.player = session.player }
    }
}
#else
/// Apple's player, full screen.
struct VideoPlayerView: UIViewControllerRepresentable {
    let session: VideoSession

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = session.player
        #if os(iOS)
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== session.player { controller.player = session.player }
    }
}
#endif

/// What the full-screen cover shows: the player, with any error over it.
/// Closing is the player's own X, which dismisses the cover.
struct VideoScreen: View {
    let session: VideoSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VideoPlayerView(session: session)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if let error = session.error {
                    Text(error)
                        .padding()
                        .background(.red.opacity(0.85), in: .rect(cornerRadius: 12))
                        .foregroundStyle(.white)
                        .padding()
                }
            }
            .onChange(of: session.finished) { _, done in if done { dismiss() } }
    }
}
