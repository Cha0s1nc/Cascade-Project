import SwiftUI
import AVKit
import Combine
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
    /// Trickplay sheets fetched for this item, by sheet number.
    @ObservationIgnored private var sheets: [Int: UIImage] = [:]

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
        Task { await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600)) }
    }

    func skip(by seconds: Double) { seek(toPlayerSeconds: time + seconds) }

    func togglePlay() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        isPlaying = player.timeControlStatus != .paused
    }

    /// 1 is normal. Kept across play and pause.
    var speed: Float { player.defaultRate }

    func setSpeed(_ rate: Float) {
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
        selectionRevision += 1
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
    func trickplayFrame(atFilmSeconds seconds: Double) async -> UIImage? {
        guard let trickplay, let item, let frame = trickplay.frame(atSeconds: seconds) else { return nil }
        let sheet: UIImage
        if let cached = sheets[frame.sheet] {
            sheet = cached
        } else {
            guard let data = try? await client.trickplaySheet(itemId: item.id, mediaSourceId: resolved?.mediaSourceId,
                                                              frameWidth: trickplay.frameWidth, sheet: frame.sheet),
                  let image = UIImage(data: data), self.item?.id == item.id else { return nil }
            sheets[frame.sheet] = image
            sheet = image
        }
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        return sheet.cgImage?.cropping(to: rect).map { UIImage(cgImage: $0) }
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

    func stop() async {
        endTask?.cancel()
        segmentTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
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

/// What the full-screen cover shows: the player, with any error over it.
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
