#if os(iOS)
import SwiftUI
import AVKit
import CascadeKit

// Cascade's own video player on iOS. AVPlayerViewController has no hooks there
// for what a Jellyfin client needs on the timeline (chapter ticks, the server's
// trickplay frames, Skip Intro where the thumb is), so the picture is an
// AVPlayerLayer and the controls are drawn here. tvOS keeps Apple's player
// (VideoPlayerView), which already shows chapters and the skip button.
//
// What the system player gave for free and this file does by hand: closing,
// subtitle and audio menus (from the stream's own media selection groups),
// speed, AirPlay (AVRoutePickerView), picture in picture, and VoiceOver labels.
// Not done here, as before: lock screen controls during video.

/// Which ways the app may face. The player narrows it to landscape for a
/// landscape video and puts it back on the way out; AppDelegate reports it.
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    static func set(_ new: UIInterfaceOrientationMask) {
        guard new != mask else { return }
        mask = new
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            // UIKit asks the front-most controller (the full-screen cover's), so
            // every one in the chain hears that the answer changed.
            var controller = scene.keyWindow?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            // Allowing portrait again does not turn the screen back by itself
            // until the phone moves, so a phone held upright is turned now.
            let upright = new.contains(.portrait) && !UIDevice.current.orientation.isLandscape
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: upright ? .portrait : new))
        }
    }
}

struct CascadeVideoPlayer: View {
    let session: VideoSession
    let close: () -> Void

    @State private var controlsShown = true
    @State private var hideTask: Task<Void, Never>?
    /// Where the finger is while scrubbing, on the player's clock.
    @State private var scrubbing: Double?
    @State private var pip = PictureInPicture()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayer(player: session.player, pip: pip).ignoresSafeArea()
            Color.clear.contentShape(.rect).ignoresSafeArea()
                .onTapGesture { toggleControls() }
                .accessibilityHidden(true)
            controls
                .opacity(controlsShown ? 1 : 0)
                .allowsHitTesting(controlsShown)
            skipButton
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .animation(.easeOut(duration: 0.2), value: controlsShown)
        .onAppear { poke() }
        .onChange(of: session.isPlaying) { poke() }
        .onChange(of: scrubbing == nil) { poke() }
        .onChange(of: session.isLandscapeVideo, initial: true) { _, landscape in
            // A film is watched sideways, so turning the phone upright does not
            // shrink it to a strip. A vertical video may still turn.
            OrientationLock.set(landscape == true ? .landscape : .allButUpsideDown)
        }
        .onDisappear { OrientationLock.set(.allButUpsideDown) }
    }

    // MARK: Layout

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 8)
            centerButtons
            Spacer(minLength: 8)
            Scrubber(session: session, scrubbing: $scrubbing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background { Color.black.opacity(0.35).ignoresSafeArea().allowsHitTesting(false) }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            CircleButton(systemImage: "chevron.down", label: "Close") { close() }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.item?.name ?? "").font(.headline)
                if !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.white.opacity(0.75))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let group = session.subtitleGroup {
                selectionMenu(group, systemImage: "captions.bubble", label: "Subtitles")
            }
            if let group = session.audioGroup {
                selectionMenu(group, systemImage: "waveform", label: "Audio")
            }
            speedMenu
            RoutePicker()
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: .circle)
                .accessibilityLabel("AirPlay")
            if AVPictureInPictureController.isPictureInPictureSupported() {
                CircleButton(systemImage: "pip.enter", label: "Picture in Picture") { pip.start() }
            }
        }
        .foregroundStyle(.white)
    }

    /// The show and episode for an episode, then the chapter playing.
    private var caption: String {
        var parts: [String] = []
        if let item = session.item, let series = item.seriesName {
            if let season = item.parentIndexNumber, let episode = item.indexNumber {
                parts.append("\(series) · S\(season) E\(episode)")
            } else {
                parts.append(series)
            }
        }
        if let chapter = Chapters.current(in: session.chapters, at: session.time) { parts.append(chapter.name) }
        return parts.joined(separator: " · ")
    }

    private var centerButtons: some View {
        HStack(spacing: 44) {
            CircleButton(systemImage: "gobackward.10", label: "Back 10 seconds", size: 52) { session.skip(by: -10); poke() }
            CircleButton(systemImage: session.isPlaying ? "pause.fill" : "play.fill",
                         label: session.isPlaying ? "Pause" : "Play", size: 72) { session.togglePlay(); poke() }
            CircleButton(systemImage: "goforward.10", label: "Forward 10 seconds", size: 52) { session.skip(by: 10); poke() }
        }
    }

    /// Netflix's place for it: bottom right, above the scrubber when the
    /// controls are up and on its own when they are not.
    @ViewBuilder private var skipButton: some View {
        if let segment = session.activeSegment {
            Button { session.skipSegment() } label: {
                Label(segment.skipLabel, systemImage: "forward.end.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.white, in: .capsule)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 24)
            .padding(.bottom, controlsShown ? 88 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    // MARK: Menus

    private func selectionMenu(_ group: AVMediaSelectionGroup, systemImage: String, label: String) -> some View {
        Menu {
            let _ = session.selectionRevision
            let current = session.selected(in: group)
            if group.allowsEmptySelection {
                Button { session.select(nil, in: group) } label: { checked("Off", current == nil) }
            }
            ForEach(group.options, id: \.self) { option in
                Button { session.select(option, in: group) } label: { checked(session.label(for: option), current == option) }
            }
        } label: {
            CircleIcon(systemImage: systemImage)
        }
        .accessibilityLabel(label)
    }

    private var speedMenu: some View {
        Menu {
            let _ = session.selectionRevision
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { rate in
                Button { session.setSpeed(rate) } label: { checked(speedLabel(rate), session.speed == rate) }
            }
        } label: {
            Text(speedLabel(session.speed))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: .circle)
        }
        .accessibilityLabel("Playback speed")
    }

    private func speedLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : "\(rate.formatted())x"
    }

    @ViewBuilder private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: Showing and hiding

    /// Shows the controls and, while playing and not scrubbing, hides them
    /// again after a few seconds. Paused, they stay.
    private func poke() {
        controlsShown = true
        hideTask?.cancel()
        guard session.isPlaying, scrubbing == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { controlsShown = false }
        }
    }

    private func toggleControls() {
        if controlsShown {
            hideTask?.cancel()
            controlsShown = false
        } else {
            poke()
        }
    }
}

// MARK: - Scrubber

/// The timeline: chapter ticks, and while dragging, the server's trickplay
/// frame with the time and chapter above the finger. On the player's clock;
/// film time (which a transcode starts partway into) only for what is shown.
private struct Scrubber: View {
    let session: VideoSession
    @Binding var scrubbing: Double?
    @State private var preview: UIImage?
    @State private var previewTask: Task<Void, Never>?

    private let previewWidth: CGFloat = 176

    var body: some View {
        let shown = scrubbing ?? session.time
        let fraction = session.duration > 0 ? min(max(shown / session.duration, 0), 1) : 0
        let barHeight: CGFloat = scrubbing == nil ? 5 : 8
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3)).frame(height: barHeight)
                    Capsule().fill(.white).frame(width: max(barHeight, width * fraction), height: barHeight)
                    ForEach(Chapters.tickFractions(session.chapters, duration: session.duration), id: \.self) { tick in
                        Rectangle()
                            .fill(tick <= fraction ? Color.black.opacity(0.55) : Color.white.opacity(0.75))
                            .frame(width: 2, height: barHeight + 2)
                            .offset(x: width * tick - 1)
                    }
                    Circle().fill(.white)
                        .frame(width: scrubbing == nil ? 14 : 22, height: scrubbing == nil ? 14 : 22)
                        .offset(x: width * fraction - (scrubbing == nil ? 7 : 11))
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard session.duration > 0 else { return }
                        scrubbing = min(max(value.location.x / width, 0), 1) * session.duration
                        updatePreview()
                    }
                    .onEnded { _ in
                        if let target = scrubbing { session.seek(toPlayerSeconds: target) }
                        scrubbing = nil
                        previewTask?.cancel()
                        preview = nil
                    })
                .overlay(alignment: .bottomLeading) {
                    if let scrubbing {
                        previewBubble(at: scrubbing)
                            .offset(x: min(max(width * fraction - previewWidth / 2, 0), width - previewWidth),
                                    y: -(geo.size.height + 6))
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 28)
            HStack {
                Text(clock(session.streamStartSeconds + shown))
                Spacer()
                Text("-" + clock(max(0, session.duration - shown)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(clock(session.streamStartSeconds + shown)) of \(clock(session.streamStartSeconds + session.duration))")
        .accessibilityAdjustableAction { direction in
            session.skip(by: direction == .increment ? 10 : -10)
        }
    }

    private func previewBubble(at seconds: Double) -> some View {
        VStack(spacing: 6) {
            if session.trickplay != nil {
                Group {
                    if let preview {
                        Image(uiImage: preview).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
                .frame(width: previewWidth, height: previewWidth * 9 / 16)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
            }
            Text([clock(session.streamStartSeconds + seconds), Chapters.current(in: session.chapters, at: seconds)?.name]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: .capsule)
        }
        .frame(width: previewWidth)
    }

    /// Cheap once a sheet is in: every frame on it is a crop.
    private func updatePreview() {
        guard session.trickplay != nil, let scrubbing else { return }
        let film = session.streamStartSeconds + scrubbing
        previewTask?.cancel()
        previewTask = Task {
            let image = await session.trickplayFrame(atFilmSeconds: film)
            if !Task.isCancelled, let image { preview = image }
        }
    }
}

// MARK: - Pieces

private struct CircleIcon: View {
    let systemImage: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .frame(width: size, height: size)
            .background(.black.opacity(0.35), in: .circle)
            .foregroundStyle(.white)
    }
}

private struct CircleButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) { CircleIcon(systemImage: systemImage, size: size) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

private final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The picture. AVPlayerLayer also draws the selected subtitles.
private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let pip: PictureInPicture

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        pip.attach(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}

/// Picture in picture from the layer. It also starts by itself when the app
/// goes to the background mid-film, the way the system player did.
@MainActor
private final class PictureInPicture {
    private var controller: AVPictureInPictureController?
    private let delegate = PictureInPictureDelegate()

    func attach(_ layer: AVPlayerLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        controller?.delegate = delegate
        self.controller = controller
    }

    func start() { controller?.startPictureInPicture() }
}

private final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    /// The full-screen player is still there behind the window, so returning
    /// to it needs nothing restored.
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
#endif
