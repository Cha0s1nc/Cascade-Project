import SwiftUI
import AVKit
import Combine
#if os(iOS)
import MediaPlayer
#endif
import CascadeKit

/// One movie or run of episodes playing: the desktop's playVideo. Apart from
/// the music PlaybackService on purpose: that one is built around gapless
/// audio decks, the lock screen's music controls and the queue, none of which
/// a movie wants. Apple's player view does the controls, subtitles, AirPlay
/// and picture in picture.
@MainActor
@Observable
final class VideoSession {
    let player = AVPlayer()
    private(set) var item: JfItem?
    private(set) var error: String?
    /// Set when the last episode ends, so the player closes itself.
    private(set) var finished = false
    /// The intro or outro playing now, which the player offers to skip.
    private(set) var activeSegment: MediaSegment?
    /// The playing video's chapters, on the player's clock. tvOS hands them to
    /// the system player as markers; iOS draws them as ticks on its scrubber.
    private(set) var chapters: [Chapter] = []
    /// The server's preview frames for scrubbing, when the library makes them.
    private(set) var trickplay: Trickplay?
    /// The player's clock and length, twice a second, for the iOS controls.
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// Wider than tall, so the iOS player holds landscape. Nil until known.
    private(set) var isLandscapeVideo: Bool?
    /// The stream's subtitle and audio choices, for the iOS menus.
    private(set) var subtitleGroup: AVMediaSelectionGroup?
    private(set) var audioGroup: AVMediaSelectionGroup?
    /// What the menus call each track, read once when the stream loads.
    private(set) var trackLabels: [AVMediaSelectionOption: String] = [:]
    /// Bumped on a selection, so the menus redraw their checkmarks.
    private(set) var selectionRevision = 0

    private let client: JellyfinClient
    private let config: ServerConfig
    private var queue: [JfItem] = []
    private var index = 0
    private var audioStreamIndex: Int?
    @ObservationIgnored private var resolved: ResolvedStream?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var segmentTask: Task<Void, Never>?
    @ObservationIgnored private var segments: [MediaSegment] = []
    /// Segments auto-skip already fired for, so seeking back is not fought.
    @ObservationIgnored private var autoSkipped: Set<String> = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusWatch: AnyCancellable?
    #if os(iOS)
    /// The remote command targets this video added, removed on close.
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var lockScreenArt: (itemId: String, art: MPMediaItemArtwork)?
    /// What the lock screen was last told, so it is written on a change only.
    @ObservationIgnored private var lockScreenShown: (playing: Bool, duration: Double)?
    #endif
    /// Trickplay sheets fetched for this item, by sheet number.
    @ObservationIgnored private var sheets: [Int: PlatformImage] = [:]
    /// The Video EQ: a tap on the item, only for a direct stream (AVFoundation
    /// will not tap an HLS transcode, which is what an MKV becomes).
    @ObservationIgnored private var tap: TapContext?
    private(set) var equalizer = EQProfile()

    init(client: JellyfinClient, config: ServerConfig) {
        self.client = client
        self.config = config
        // AVPlayer's own default already follows the system's caption
        // preferences (Settings > Accessibility > Subtitles & Captioning).
        player.appliesMediaSelectionCriteriaAutomatically = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
    }

    private func tick(_ seconds: Double) {
        time = seconds.isFinite ? seconds : 0
        let length = player.currentItem?.duration.seconds ?? 0
        duration = length.isFinite ? length : 0
        isPlaying = player.timeControlStatus != .paused
        #if os(iOS)
        // The lock screen runs its own clock from the rate; it needs telling
        // only when that or the length changes.
        if lockScreenShown?.playing != isPlaying || lockScreenShown?.duration != duration { updateLockScreen() }
        #endif
        // The picture's real size, for an item the list did not say it of.
        if isLandscapeVideo == nil, let size = player.currentItem?.presentationSize, size.width > 0, size.height > 0 {
            isLandscapeVideo = size.width > size.height
        }
    }

    /// `resume` picks up at the saved position; otherwise from the start.
    func play(_ items: [JfItem], startIndex: Int = 0, audioStreamIndex: Int? = nil, resume: Bool = true) async {
        guard items.indices.contains(startIndex) else { return }
        queue = items
        index = startIndex
        self.audioStreamIndex = audioStreamIndex
        #if os(iOS)
        claimLockScreen()
        #endif
        await load(resume: resume)
    }

    private func load(resume: Bool) async {
        await reportStopped()
        let item = queue[index]
        self.item = item
        error = nil
        chapters = []
        trickplay = nil
        sheets = [:]
        subtitleGroup = nil
        audioGroup = nil
        trackLabels = [:]
        time = 0
        duration = 0
        // The list's MediaStreams say it before the first frame does.
        let video = item.mediaStreams?.first { $0.type == "Video" }
        isLandscapeVideo = video.flatMap { v in v.width.flatMap { w in v.height.map { h in w > h } } }
        let start = resume ? resumeTicks(for: item) : 0
        do {
            let stream = try await VideoPlayback.resolve(client: client, config: config, item: item,
                                                         audioStreamIndex: audioStreamIndex)
            guard self.item?.id == item.id else { return }
            resolved = stream
            // Through ProxyConnection: AVPlayer's own networking needs the reverse
            // proxy headers set on the asset.
            let playerItem = AVPlayerItem(asset: ProxyConnection.shared.asset(url: stream.url))
            tap = nil
            if stream.direct, equalizer.enabled {
                let context = TapContext()
                context.update(profile: equalizer)
                if await AudioTap.attach(context, to: playerItem) { tap = context }
                guard self.item?.id == item.id else { return }
            }
            player.replaceCurrentItem(with: playerItem)
            // Apple's player drew its own broken-play icon for a stream that
            // fails; the iOS controls would just sit over black.
            statusWatch = playerItem.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard status == .failed, let self, self.error == nil else { return }
                    self.error = "This video stopped loading. The server may have refused the stream."
                }
            }
            // Both a direct file and a transcode's playlist start at the top
            // of the film, so a resume is a seek (see VideoPlayback.resolve).
            if start > 0 {
                await player.seek(to: CMTime(seconds: seconds(fromTicks: start), preferredTimescale: 600))
            }
            player.play()
            #if os(iOS)
            loadLockScreenArt(for: item)
            #endif
            watchForEnd(playerItem)
            watchSegments(for: item)
            addChapterMarkers(for: item, to: playerItem, streamStartSeconds: seconds(fromTicks: stream.startTicks))
            loadSelectionGroups(for: playerItem)
            _ = await PlaybackReporter.start(client, state())
            startReporting()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The position in the item, in ticks: a transcode's clock starts where
    /// it was asked to.
    private func positionTicks() -> Int {
        let t = player.currentTime().seconds
        return (resolved?.startTicks ?? 0) + ticks(fromSeconds: t.isFinite ? t : 0)
    }

    private func state() -> PlaybackState {
        PlaybackState(itemId: item?.id ?? "", positionTicks: positionTicks(), isPaused: player.rate == 0,
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

    // MARK: Chapters

    /// The video's chapters and trickplay manifest, in one request. On tvOS the
    /// chapters become the player's navigation markers (its scrubber shows them,
    /// swipe up to jump); iOS draws its own scrubber with them as ticks.
    /// Fetched after playback has started, so a slow answer costs nothing; a
    /// film with neither (or an older server) just has none.
    private func addChapterMarkers(for item: JfItem, to playerItem: AVPlayerItem, streamStartSeconds: Double) {
        let mediaSourceId = resolved?.mediaSourceId
        Task { [weak self] in
            guard let self else { return }
            let details = await self.client.videoDetails(for: item)
            // The item may have changed while this was out.
            guard self.item?.id == item.id, self.player.currentItem === playerItem else { return }
            self.trickplay = Trickplay.pick(details.trickplay, mediaSourceId: mediaSourceId)
            let chapters = Chapters.onPlayerTimeline(details.chapters, streamStartSeconds: streamStartSeconds)
            guard chapters.count > 1 else { return }
            self.chapters = chapters
            #if os(tvOS)
            let markers = chapters.enumerated().map { i, chapter -> AVTimedMetadataGroup in
                let title = AVMutableMetadataItem()
                title.identifier = .commonIdentifierTitle
                title.value = chapter.name as NSString
                title.extendedLanguageTag = "und"
                // A marker runs to the next chapter's start (the last, to the end).
                let end = i + 1 < chapters.count ? chapters[i + 1].startSeconds : chapter.startSeconds + 1
                let start = CMTime(seconds: chapter.startSeconds, preferredTimescale: 600)
                let range = CMTimeRange(start: start, end: CMTime(seconds: end, preferredTimescale: 600))
                return AVTimedMetadataGroup(items: [title], timeRange: range)
            }
            playerItem.navigationMarkerGroups = [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
            #endif
        }
    }

    // MARK: The iOS controls

    /// Where the player's clock starts in the film: zero but for a transcode
    /// asked to start partway in. Add it for anything shown as film time.
    var streamStartSeconds: Double { seconds(fromTicks: resolved?.startTicks ?? 0) }

    /// On the player's clock. A transcode cannot go before its own start.
    func seek(toPlayerSeconds target: Double) {
        let clamped = max(0, duration > 0 ? min(target, duration) : target)
        time = clamped
        Task {
            await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
            #if os(iOS)
            updateLockScreen()
            #endif
        }
    }

    func skip(by seconds: Double) { seek(toPlayerSeconds: time + seconds) }

    func togglePlay() { setPlaying(player.timeControlStatus == .paused) }

    func setPlaying(_ on: Bool) {
        if on { player.play() } else { player.pause() }
        isPlaying = player.timeControlStatus != .paused
        #if os(iOS)
        updateLockScreen()
        #endif
    }

    /// 1 is normal. Kept across play and pause.
    var speed: Float { player.defaultRate }

    func setSpeed(_ rate: Float) {
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
        selectionRevision += 1
        #if os(iOS)
        updateLockScreen()
        #endif
    }

    private func loadSelectionGroups(for playerItem: AVPlayerItem) {
        Task { [weak self] in
            let legible = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible)
            let audible = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible)
            var labels: [AVMediaSelectionOption: String] = [:]
            for option in (legible?.options ?? []) + (audible?.options ?? []) {
                let item = option.commonMetadata.first { $0.identifier?.rawValue == "m3u8/NAME" }
                let name = try? await item?.load(.stringValue)
                labels[option] = mediaTrackLabel(playlistName: name ?? nil, fallback: option.displayName)
            }
            guard let self, self.player.currentItem === playerItem else { return }
            self.trackLabels = labels
            self.subtitleGroup = legible?.options.isEmpty == false ? legible : nil
            // One audio track is no choice at all.
            self.audioGroup = (audible?.options.count ?? 0) > 1 ? audible : nil
        }
    }

    /// The server's name for a track, which tells five English tracks apart.
    func label(for option: AVMediaSelectionOption) -> String {
        trackLabels[option] ?? option.displayName
    }

    func selected(in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        player.currentItem?.currentMediaSelection.selectedMediaOption(in: group)
    }

    /// Nil turns subtitles off (only a group that allows empty selection).
    func select(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        player.currentItem?.select(option, in: group)
        selectionRevision += 1
    }

    /// The preview frame at a film position, from the server's trickplay sheets,
    /// fetched once each and kept for this item.
    func trickplayFrame(atFilmSeconds seconds: Double) async -> PlatformImage? {
        guard let trickplay, let item, let frame = trickplay.frame(atSeconds: seconds) else { return nil }
        let sheet: PlatformImage
        if let cached = sheets[frame.sheet] {
            sheet = cached
        } else {
            guard let data = try? await client.trickplaySheet(itemId: item.id, mediaSourceId: resolved?.mediaSourceId,
                                                              frameWidth: trickplay.frameWidth, sheet: frame.sheet),
                  let image = PlatformImage(data: data), self.item?.id == item.id else { return nil }
            sheets[frame.sheet] = image
            sheet = image
        }
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        return sheet.cgImage?.cropping(to: rect).map { PlatformImage(cgImage: $0) }
    }

    // MARK: Skip intro and outro

    /// Settings > Video. Off unless turned on.
    private var autoSkip: Bool { UserDefaults.standard.bool(forKey: "cascade.autoSkipSegments") }

    /// Fetches the item's Media Segments (none on an older server or with no
    /// provider) and then follows the playhead, twice a second, for the one
    /// that is playing.
    private func watchSegments(for item: JfItem) {
        segmentTask?.cancel()
        segments = []
        autoSkipped = []
        activeSegment = nil
        segmentTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.client.mediaSegments(for: item.id)
            guard !found.isEmpty, !Task.isCancelled, self.item?.id == item.id else { return }
            self.segments = found
            while !Task.isCancelled {
                self.updateActiveSegment()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func updateActiveSegment() {
        let position = seconds(fromTicks: positionTicks())
        let segment = MediaSegments.active(in: segments, at: position)
        if segment != activeSegment { activeSegment = segment }
        guard let segment, autoSkip, player.rate != 0 else { return }
        let key = "\(segment.type.rawValue):\(segment.startSeconds)"
        if autoSkipped.insert(key).inserted { skipSegment() }
    }

    /// What the player's Skip button does: past an intro, or past an outro,
    /// which when it runs to the end goes on to the next episode.
    func skipSegment() {
        guard let segment = activeSegment else { return }
        let duration = item?.runTimeTicks.map { seconds(fromTicks: $0) } ?? 0
        switch MediaSegments.skipAction(for: segment, duration: duration) {
        case .next:
            Task { await advance() }
        case .seek(let target):
            // A transcode's clock starts where it was asked to.
            let local = max(0, target - seconds(fromTicks: resolved?.startTicks ?? 0))
            Task { await player.seek(to: CMTime(seconds: local, preferredTimescale: 600)) }
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

    private func watchForEnd(_ playerItem: AVPlayerItem) {
        endTask?.cancel()
        endTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification,
                                                                    object: playerItem) {
                guard let self else { return }
                await self.advance()
                return
            }
        }
    }

    /// The next episode, from its start, or the end.
    private func advance() async {
        guard index + 1 < queue.count else {
            await stop()
            finished = true
            return
        }
        index += 1
        await load(resume: false)
    }

    #if os(iOS)
    // MARK: Lock screen (iOS)
    //
    // AVPlayerViewController used to fill this in by itself. With Cascade's own
    // player nothing did, so the lock screen kept the paused song and its
    // buttons still drove the music player. While a video is open it owns the
    // lock screen; the music player stands aside (PlaybackService
    // .lockScreenSuspended, set by AppState) and takes it back on close.

    private func claimLockScreen() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ run: @escaping @Sendable () async -> Void) {
            commandTargets.append((command, command.addTarget(handler: Self.handler(run))))
        }
        on(center.playCommand) { [weak self] in await self?.setPlaying(true) }
        on(center.pauseCommand) { [weak self] in await self?.setPlaying(false) }
        on(center.togglePlayPauseCommand) { [weak self] in await self?.togglePlay() }
        on(center.skipForwardCommand) { [weak self] in await self?.skip(by: 10) }
        on(center.skipBackwardCommand) { [weak self] in await self?.skip(by: -10) }
        let position = center.changePlaybackPositionCommand
        commandTargets.append((position, position.addTarget(handler: Self.positionHandler { [weak self] seconds in
            await self?.seek(toPlayerSeconds: seconds)
        })))
        // A film skips by ten seconds; next and previous are the music's.
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func releaseLockScreen() {
        guard !commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        lockScreenShown = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateLockScreen() {
        guard !commandTargets.isEmpty, let item else { return }
        var subtitle = item.productionYear.map(String.init) ?? ""
        if let series = item.seriesName {
            subtitle = VideoPlayback.episodeCode(item).map { "\(series) · \($0)" } ?? series
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name ?? "",
            MPMediaItemPropertyArtist: subtitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            // Zero while paused, or the lock screen's clock keeps running.
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art = lockScreenArt, art.itemId == item.id { info[MPMediaItemPropertyArtwork] = art.art }
        lockScreenShown = (isPlaying, duration)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The poster (a still, for an episode), a moment after playback starts.
    private func loadLockScreenArt(for item: JfItem) {
        guard lockScreenArt?.itemId != item.id else { return updateLockScreen() }
        Task { [weak self] in
            guard let self, let url = await self.client.imageUrl(itemId: item.id, size: 600),
                  let (data, response) = try? await ProxyConnection.shared.session(for: url).data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = await UIImage(data: data)?.byPreparingForDisplay(),
                  self.item?.id == item.id else { return }
            self.lockScreenArt = (item.id, Self.makeArtwork(image))
            self.updateLockScreen()
        }
    }

    // Built outside the main actor: MediaPlayer calls these from its own queue,
    // and a closure written in a main-actor method would trap there (see
    // PlaybackService's lock screen art).
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    nonisolated private static func handler(_ run: @escaping @Sendable () async -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { await run() }
            return .success
        }
    }

    nonisolated private static func positionHandler(_ run: @escaping @Sendable (Double) async -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { await run(seconds) }
            return .success
        }
    }
    #endif

    // MARK: Equalizer

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

    #if os(macOS)
    // MARK: The Mac player (App/Mac/MacVideo.swift, MacVideoControls.swift)

    /// The Mac's scrubber is being dragged, so idle hiding waits.
    var isScrubbing = false
    /// Resolving the stream: nothing on screen yet.
    var isLoading: Bool { item != nil && player.currentItem == nil && error == nil }
    var position: Double { time }
    var rate: Double { Double(speed) }
    func setRate(_ rate: Double) { setSpeed(Float(rate)) }
    func togglePlayPause() { togglePlay() }
    func seek(to seconds: Double) { seek(toPlayerSeconds: seconds) }

    var hasNext: Bool { index + 1 < queue.count }
    var hasPrevious: Bool { index > 0 }

    /// Shift-N and Shift-P: the next or previous episode, from its start.
    func next() async {
        guard hasNext else { return }
        index += 1
        await load(resume: false)
    }

    func previous() async {
        guard hasPrevious else { return }
        index -= 1
        await load(resume: false)
    }

    /// Comma and period: one frame, only while paused (playing, the next
    /// frame would be gone before it was seen).
    func step(forward: Bool) {
        guard player.rate == 0 else { return }
        player.currentItem?.step(byCount: forward ? 1 : -1)
    }

    /// Option-Left and Option-Right. Returns the chapter it went to, for the readout.
    func jumpChapter(forward: Bool) -> Chapter? {
        guard let target = Chapters.jumpTarget(in: chapters, from: time, forward: forward) else { return nil }
        seek(toPlayerSeconds: target)
        return Chapters.current(in: chapters, at: target)
    }

    /// The last subtitle track turned off with C, for C to bring back.
    @ObservationIgnored private var lastSubtitle: AVMediaSelectionOption?

    /// C: subtitles off, or back to the last track (the first one if none
    /// yet). Returns what to show in the readout, nil when there are none.
    func toggleSubtitles() -> String? {
        guard let group = subtitleGroup else { return nil }
        if let on = selected(in: group) {
            lastSubtitle = on
            select(nil, in: group)
            return "Subtitles off"
        }
        guard let pick = lastSubtitle ?? group.options.first else { return nil }
        select(pick, in: group)
        return label(for: pick)
    }

    /// The Mac video follows the music player's volume and mute, the app's
    /// one volume, so the slider means the same thing in both.
    @ObservationIgnored private weak var audio: PlaybackService?

    func follow(_ service: PlaybackService?) {
        audio = service
        syncVolume()
    }

    private func syncVolume() {
        player.volume = audio?.volume ?? player.volume
        player.isMuted = audio?.isMuted ?? player.isMuted
        selectionRevision += 1
    }

    var volume: Float { audio?.volume ?? player.volume }
    var isMuted: Bool { audio?.isMuted ?? player.isMuted }

    func setVolume(_ value: Float) {
        let v = min(1, max(0, value))
        if let audio { audio.setVolume(v) } else { player.volume = v }
        syncVolume()
    }

    func toggleMute() {
        if let audio { audio.setMuted(!audio.isMuted) } else { player.isMuted.toggle() }
        syncVolume()
    }
    #endif

    func stop() async {
        endTask?.cancel()
        segmentTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        #if os(iOS)
        releaseLockScreen()
        #endif
        activeSegment = nil
        chapters = []
        player.pause()
        await reportStopped()
        player.replaceCurrentItem(with: nil)
        item = nil
    }
}

#if os(tvOS)
/// Apple's player, full screen. tvOS only: its remote-driven scrubbing, focus
/// and info panels are the system's to get right. iOS draws its own
/// (CascadeVideoPlayer, VideoControls.swift).
struct VideoPlayerView: UIViewControllerRepresentable {
    let session: VideoSession
    /// The intro or outro to offer to skip. A parameter, not read inside
    /// updateUIViewController, so a change rebuilds this view and updates it.
    let skippable: MediaSegment?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = session.player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== session.player { controller.player = session.player }
        // Apple's contextual action: drawn over the player and, on tvOS, a
        // button the remote reaches by itself, so select keeps meaning
        // play/pause rather than being taken by ours.
        let activeSession = session
        controller.contextualActions = skippable.map { segment in
            [UIAction(title: segment.skipLabel, image: UIImage(systemName: "forward.end.fill")) { _ in
                Task { @MainActor in activeSession.skipSegment() }
            }]
        } ?? []
    }
}
#endif

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
#endif

#if !os(macOS)
/// What the full-screen cover shows: the player, with any error over it.
/// The Mac has its own (MacVideoHost).
struct VideoScreen: View {
    let session: VideoSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        player
            .overlay(alignment: .top) {
                if let error = session.error {
                    Text(error)
                        .padding()
                        .background(.red.opacity(0.85), in: .rect(cornerRadius: 12))
                        .foregroundStyle(.white)
                        .padding()
                        #if os(iOS)
                        // Under the iOS controls' top bar, not over it.
                        .padding(.top, 48)
                        #endif
                }
            }
            .onChange(of: session.finished) { _, done in if done { dismiss() } }
    }

    @ViewBuilder private var player: some View {
        #if os(iOS)
        CascadeVideoPlayer(session: session) { dismiss() }
        #else
        // Closing is the player's own Menu button, which dismisses the cover.
        VideoPlayerView(session: session, skippable: session.activeSegment)
            .ignoresSafeArea()
        #endif
    }
}
#endif
