#if os(iOS)
import SwiftUI
import CascadeKit

/// Other Jellyfin devices this user can drive, the desktop's device panel:
/// pick one to see what it is playing and control it, or hand it what is
/// playing here. Polled every 3 s while open, and only then.
struct DevicesSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [RemoteSession] = []
    @State private var polledAt = Date.now
    @State private var loaded = false
    @State private var error: String?
    /// Moved by hand; the next poll does not snap it back mid-drag.
    @State private var volumeDraft: Double?
    /// While the finger is on the volume slider: the 3 s poll leaves the draft
    /// alone, or a level reported a moment ago would snap the thumb back.
    @State private var volumeEditing = false
    /// The pending live volume command, at most one per interval.
    @State private var volumeSend: Task<Void, Never>?

    private var selected: RemoteSession? {
        sessions.first { $0.id == state.controlledDevice?.id }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sessions) { session in
                        Button {
                            state.controlledDevice = state.controlledDevice?.id == session.id
                                ? nil : (session.id, session.label)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.label)
                                    Text(nowPlaying(session))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if session.id == state.controlledDevice?.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if loaded && sessions.isEmpty {
                        Text("No other devices. Open Jellyfin or Cascade on another device, signed in as you.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                if let selected { controls(selected) }
                Section {
                    NavigationLink {
                        WaterfallView()
                    } label: {
                        LabeledContent("Listen Together", value: state.waterfall?.isActive == true
                                       ? "Room \(state.waterfall?.code ?? "")" : "Waterfall")
                    }
                }
            }
            .navigationTitle("Control Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await poll() }
        }
    }

    private func nowPlaying(_ s: RemoteSession) -> String {
        guard let item = s.nowPlayingItem else { return s.client ?? "Idle" }
        let artist = item.albumArtist ?? item.artists?.first
        return [item.name, artist].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func controls(_ s: RemoteSession) -> some View {
        Section(s.label) {
            if s.nowPlayingItem == nil {
                Text("Not playing. Hand it this queue, or pick \"Play on \(s.label)\" in a song's menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if s.nowPlayingItem != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let position = SessionControl.position(s.playState, polledAt: polledAt, now: context.date)
                    let duration = Double(s.nowPlayingItem?.runTimeTicks ?? 0) / Double(Lyrics.ticksPerSecond)
                    VStack(spacing: 4) {
                        ProgressView(value: min(position, max(duration, 1)), total: max(duration, 1))
                        HStack {
                            Text(clock(position)); Spacer(); Text(clock(duration))
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 36) {
                    Spacer()
                    Button { send("PreviousTrack") } label: { Image(systemName: "backward.fill") }
                    Button { send("PlayPause") } label: {
                        Image(systemName: s.playState?.isPaused == false ? "pause.fill" : "play.fill")
                    }
                    Button { send("NextTrack") } label: { Image(systemName: "forward.fill") }
                    Spacer()
                }
                .font(.title2)
                .buttonStyle(.borderless)
            }
            if let level = s.playState?.volumeLevel {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { volumeDraft ?? Double(level) }, set: { v in
                        volumeDraft = v
                        sendVolumeSoon(to: s.id)
                    }), in: 0...100) { editing in
                        volumeEditing = editing
                        guard !editing, let draft = volumeDraft else { return }
                        // The exact final level, whatever the last live send was.
                        volumeSend?.cancel()
                        volumeSend = nil
                        Task { try? await state.client?.setVolume(Int(draft), on: s.id) }
                    }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
            if let player = state.player, !player.queue.items.isEmpty {
                Button("Play This Queue on \(s.label)", systemImage: "arrow.up.forward.app") {
                    Task { await handOff(to: s, from: player) }
                }
            }
        }
    }

    /// The queue from the current song on, then pause here: the music moves
    /// rather than playing in two places.
    private func handOff(to s: RemoteSession, from player: PlaybackService) async {
        let ids = player.queue.items.map(\.id)
        do {
            try await state.client?.play(ids, on: s.id, startIndex: player.queue.index)
            player.pause()
            await poll(once: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send(_ command: String) {
        guard let id = state.controlledDevice?.id else { return }
        Task {
            try? await state.client?.sendPlaystate(command, to: id)
            try? await Task.sleep(for: .milliseconds(400))
            await poll(once: true)
        }
    }

    /// Live volume while dragging: each step would be a request to the server
    /// and a hop to the device, so at most one goes out per 150 ms, carrying
    /// wherever the thumb is by then.
    private func sendVolumeSoon(to sessionId: String) {
        guard volumeSend == nil else { return }
        volumeSend = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if let level = volumeDraft { try? await state.client?.setVolume(Int(level), on: sessionId) }
            volumeSend = nil
        }
    }

    private func poll(once: Bool = false) async {
        repeat {
            do {
                sessions = try await state.client?.controllableSessions() ?? []
                polledAt = .now
                error = nil
                if !volumeEditing { volumeDraft = nil }
            } catch {
                self.error = error.localizedDescription
            }
            loaded = true
            if once { return }
            try? await Task.sleep(for: .seconds(3))
        } while !Task.isCancelled
    }
}
#endif
