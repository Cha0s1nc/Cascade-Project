import SwiftUI
import CascadeKit

/// Our controls over the picture: title and close along the top, the
/// scrubber (with chapter ticks) and transport along the bottom, the speed,
/// chapter, subtitle and audio pickers, the volume readout and the keys panel.
/// Everything but the keys panel hides with the controller's idle timer.
struct MacVideoOverlay: View {
    let controller: MacVideoController
    private var session: VideoSession { controller.session }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .opacity(controller.controlsVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: controller.controlsVisible)
            .allowsHitTesting(controller.controlsVisible)

            if let osd = controller.osd {
                Text(osd)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.black.opacity(0.65), in: .rect(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
            if session.isLoading && session.error == nil { ProgressView().controlSize(.large).tint(.white) }
            if let error = session.error {
                VStack(spacing: 10) {
                    Text(error).multilineTextAlignment(.center)
                    Button("Close") { controller.requestClose() }
                }
                .padding()
                .background(.red.opacity(0.85), in: .rect(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            if controller.showsKeys { KeysPanel(dismiss: { controller.showsKeys = false }) }
        }
        .preferredColorScheme(.dark)
    }

    private var title: String {
        guard let item = session.item else { return "" }
        if item.type == "Episode" {
            return [item.seriesName, VideoPlayback.episodeCode(item), item.name].compactMap { $0 }.joined(separator: " \u{00b7} ")
        }
        return item.name ?? ""
    }

    /// Below the title bar strip, which keeps clicks for dragging the window:
    /// a close button up there did nothing.
    private var topBar: some View {
        ZStack {
            // As Now Playing's: down to the corner, still playing.
            Button { controller.minimize() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                    Text("Minimize").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .help("Keep playing in the corner (Esc)")
            .accessibilityLabel("Minimize video")
            HStack(spacing: 16) {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if controller.pip.isSupported {
                    Button { controller.pip.toggle() } label: { Image(systemName: "pip.enter") }
                        .help("Picture in Picture").accessibilityLabel("Picture in Picture")
                }
                Button { controller.requestClose() } label: { Image(systemName: "xmark") }
                    .help("Stop the video").accessibilityLabel("Stop the video")
            }
        }
        .buttonStyle(.hover)
        .padding(.horizontal, 16).padding(.bottom, 10).padding(.top, 34)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            ChapterScrubber(session: session)
            HStack(spacing: 16) {
                Button { Task { await session.previous() } } label: { Image(systemName: "backward.end.fill") }
                    .disabled(!session.hasPrevious).accessibilityLabel("Previous episode")
                Button { session.skip(by: -VideoControls.skipSeconds) } label: { Image(systemName: "gobackward.10") }
                    .accessibilityLabel("Back 10 seconds")
                Button { session.togglePlayPause() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                Button { session.skip(by: VideoControls.skipSeconds) } label: { Image(systemName: "goforward.10") }
                    .accessibilityLabel("Forward 10 seconds")
                Button { Task { await session.next() } } label: { Image(systemName: "forward.end.fill") }
                    .disabled(!session.hasNext).accessibilityLabel("Next episode")

                HStack(spacing: 6) {
                    Button { session.toggleMute() } label: {
                        Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 20)
                    }
                    .accessibilityLabel("Mute")
                    Slider(value: Binding(get: { Double(session.volume) }, set: { session.setVolume(Float($0)) }), in: 0...1)
                        .frame(width: 90).controlSize(.small).accessibilityLabel("Volume")
                }
                Spacer()
                speedMenu
                if !session.chapters.isEmpty { chapterMenu }
                subtitleMenu
                if session.audioGroup != nil { audioMenu }
                Button { controller.showsKeys.toggle() } label: { Image(systemName: "keyboard") }
                    .accessibilityLabel("Keyboard shortcuts")
                Button { controller.toggleFullscreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel("Fullscreen")
            }
            .buttonStyle(.hover)
            .menuStyle(.button).menuIndicator(.hidden)
        }
        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 20)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    private var speedMenu: some View {
        Menu(VideoControls.rateLabel(session.rate)) {
            ForEach(VideoControls.rates, id: \.self) { rate in
                Button { session.setRate(rate) } label: {
                    if rate == session.rate { Label(VideoControls.rateLabel(rate), systemImage: "checkmark") }
                    else { Text(VideoControls.rateLabel(rate)) }
                }
            }
        }
        .accessibilityLabel("Speed")
    }

    private var chapterMenu: some View {
        Menu {
            let current = Chapters.current(in: session.chapters, at: session.position)
            ForEach(Array(session.chapters.enumerated()), id: \.offset) { _, chapter in
                Button { session.seek(to: chapter.startSeconds) } label: {
                    let text = "\(chapter.name)  \(VideoControls.clock(chapter.startSeconds))"
                    if chapter == current { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
        } label: { Image(systemName: "list.bullet") }
        .accessibilityLabel("Chapters")
    }

    // The stream's own subtitle and audio renditions, as the iOS player
    // offers them (VideoSession.subtitleGroup / audioGroup). Picture
    // subtitles are burned in by the server, so a film can have none.
    private var subtitleMenu: some View {
        let _ = session.selectionRevision
        let group = session.subtitleGroup
        let on = group.flatMap { session.selected(in: $0) }
        return Menu {
            if let group {
                Button { session.select(nil, in: group) } label: {
                    if on == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                ForEach(group.options, id: \.self) { option in
                    Button { session.select(option, in: group) } label: {
                        if option == on { Label(session.label(for: option), systemImage: "checkmark") }
                        else { Text(session.label(for: option)) }
                    }
                }
            } else {
                Text("None available")
            }
        } label: { Image(systemName: on == nil ? "captions.bubble" : "captions.bubble.fill") }
        .accessibilityLabel("Subtitles")
    }

    private var audioMenu: some View {
        let _ = session.selectionRevision
        return Menu {
            if let group = session.audioGroup {
                let on = session.selected(in: group)
                ForEach(group.options, id: \.self) { option in
                    Button { session.select(option, in: group) } label: {
                        if option == on { Label(session.label(for: option), systemImage: "checkmark") }
                        else { Text(session.label(for: option)) }
                    }
                }
            }
        } label: { Image(systemName: "waveform") }
        .accessibilityLabel("Audio")
    }
}

/// The position slider, with a tick at each chapter start. Holds its own value
/// while dragging so the clock does not fight the pointer.
private struct ChapterScrubber: View {
    let session: VideoSession
    @State private var dragging: Double?

    var body: some View {
        let total = max(session.duration, 1)
        let shown = dragging ?? session.position
        HStack(spacing: 10) {
            Text(VideoControls.clock(shown)).font(.caption.monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * min(1, shown / total), height: 4)
                    ForEach(Array(session.chapters.enumerated()), id: \.offset) { _, chapter in
                        Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: 8)
                            .offset(x: geo.size.width * min(1, chapter.startSeconds / total) - 1)
                    }
                    Circle().fill(.white).frame(width: 12, height: 12)
                        .offset(x: geo.size.width * min(1, shown / total) - 6)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        session.isScrubbing = true
                        dragging = max(0, min(1, value.location.x / geo.size.width)) * total
                    }
                    .onEnded { value in
                        session.seek(to: max(0, min(1, value.location.x / geo.size.width)) * total)
                        dragging = nil
                        session.isScrubbing = false
                    })
            }
            .frame(height: 20)
            Text(VideoControls.clock(total)).font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
    }
}

/// The `?` list, from VideoControls.shortcuts.
private struct KeysPanel: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard shortcuts").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                ForEach(VideoControls.shortcuts, id: \.keys) { row in
                    GridRow {
                        Text(row.keys).font(.system(.body, design: .monospaced))
                        Text(row.what).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(.black.opacity(0.85), in: .rect(cornerRadius: 14))
        .foregroundStyle(.white)
        .onTapGesture { dismiss() }
    }
}
