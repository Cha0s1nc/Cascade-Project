import SwiftUI
import AVKit
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

    private let client: JellyfinClient
    private let config: ServerConfig
    private var queue: [JfItem] = []
    private var index = 0
    private var audioStreamIndex: Int?
    @ObservationIgnored private var resolved: ResolvedStream?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var endTask: Task<Void, Never>?

    init(client: JellyfinClient, config: ServerConfig) {
        self.client = client
        self.config = config
        // AVPlayer's own default already follows the system's caption
        // preferences (Settings > Accessibility > Subtitles & Captioning).
        player.appliesMediaSelectionCriteriaAutomatically = true
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
        let start = resume ? resumeTicks(for: item) : 0
        do {
            let stream = try await VideoPlayback.resolve(client: client, config: config, item: item,
                                                         audioStreamIndex: audioStreamIndex, startTicks: start)
            guard self.item?.id == item.id else { return }
            resolved = stream
            let playerItem = AVPlayerItem(url: stream.url)
            player.replaceCurrentItem(with: playerItem)
            // A direct file starts at 0 and seeks locally; a transcode was
            // asked to start at `start` and its clock counts from there.
            if stream.direct && start > 0 {
                await player.seek(to: CMTime(seconds: seconds(fromTicks: start), preferredTimescale: 600))
            }
            player.play()
            watchForEnd(playerItem)
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
        player.pause()
        await reportStopped()
        player.replaceCurrentItem(with: nil)
        item = nil
    }
}

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
