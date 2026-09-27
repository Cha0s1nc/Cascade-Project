import SwiftUI
import CascadeKit
#if os(iOS)
import AVKit
#endif

/// Full screen player. iOS gets a sheet with a scrub slider and transport
/// buttons; tvOS gets the chrome-less Apple Music style screen: artwork as the
/// only focus target, remote directions for transport, queue shown alongside.
struct NowPlayingView: View {
    let player: PlaybackService
    @Environment(AppState.self) private var state
    @State private var lyrics = LyricsModel()
    /// Whether the current track is a favourite. Local, because the player's
    /// item is a snapshot the server's answer does not update.
    @State private var isFavorite = false

    #if !os(tvOS)
    @Environment(\.dismiss) private var dismiss
    /// Lyrics in place of the artwork, the way Apple Music's toggle works.
    @State private var showLyrics = false
    // While the user is dragging, the slider owns the value; the player still
    // publishes a position every half second underneath and would otherwise
    // yank the thumb back under the finger.
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var showingQueue = false
    #endif

    var body: some View {
        Group {
            #if os(tvOS)
            tvBody
            #else
            iosBody
            #endif
        }
        .task(id: "\(player.item?.id ?? "")|\(String(describing: state.cascadePluginApi))") {
            isFavorite = player.item?.userData?.isFavorite ?? false
            await lyrics.load(itemId: player.item?.id, client: state.client, api: state.cascadePluginApi)
        }
    }

    /// Flips only once the server has accepted it: a refused write must not
    /// look like a successful one (CODEMAP rule 1).
    private func toggleFavorite() {
        guard let id = player.item?.id, let client = state.client else { return }
        let target = !isFavorite
        Task {
            do {
                try await client.setFavorite(target, itemId: id)
                if player.item?.id == id { isFavorite = target }
            } catch {}
        }
    }

    #if os(tvOS)
    private var tvBody: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(spacing: 24) {
                ArtworkView(itemId: player.item?.albumId ?? player.item?.id, size: 480)
                    .focusable()
                    .onTapGesture { player.togglePlayPause() }
                    .onMoveCommand { direction in
                        switch direction {
                        case .right: Task { await player.next() }
                        case .left: Task { await player.previous() }
                        default: break
                        }
                    }
                    .onPlayPauseCommand { player.togglePlayPause() }

                VStack(spacing: 6) {
                    Text(player.item?.name ?? "Nothing playing")
                        .font(.title2)
                        .lineLimit(1)
                    Text(player.item?.albumArtist ?? player.item?.artists?.first ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(player.item?.album ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressView(value: player.positionSeconds, total: max(player.durationSeconds, 1))
                    .frame(width: 480)
            }

            if let lines = lyrics.lines {
                LyricsView(lines: lines, player: player)
                    .frame(maxWidth: 900)
            } else if !player.queue.items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(player.queue.items.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track, showsArtwork: false)
                                .fontWeight(index == player.queue.index ? .bold : .regular)
                                .foregroundStyle(index == player.queue.index ? .primary : .secondary)
                        }
                    }
                }
                .frame(maxWidth: 480)
            }
        }
        .padding(60)
    }
    #else
    /// The desktop's sleep timer choices. Filled and tinted while one is set.
    private var sleepMenu: some View {
        Menu {
            switch player.sleepTimer {
            case .at(let date):
                Text("Pauses at \(date.formatted(date: .omitted, time: .shortened))")
            case .endOfTrack:
                Text("Pauses after this track")
            case .off:
                EmptyView()
            }
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) Minutes") { player.setSleepTimer(minutes: minutes) }
            }
            #if DEBUG
            // So the timed path can be checked without waiting 15 minutes.
            Button("1 Minute (Debug)") { player.setSleepTimer(minutes: 1) }
            #endif
            Button("End of Current Track") { player.setSleepTimerAtEndOfTrack() }
            if player.sleepTimer != .off {
                Button("Turn Off", role: .destructive) { player.cancelSleepTimer() }
            }
        } label: {
            Image(systemName: player.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
                .font(.title3)
        }
        .foregroundStyle(player.sleepTimer == .off ? Color.secondary : Color.accentColor)
        .accessibilityLabel("Sleep Timer")
    }

    private var iosBody: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

            if showLyrics, let lines = lyrics.lines {
                LyricsView(lines: lines, player: player)
                    .frame(maxHeight: .infinity)
            } else {
                ArtworkView(itemId: player.item?.albumId ?? player.item?.id, size: 300)
            }

            VStack(spacing: 4) {
                Text(player.item?.name ?? "Nothing playing")
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(player.item?.albumArtist ?? player.item?.artists?.first ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(player.item?.album ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 36) {
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.title3)
                }
                .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
                .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")

                Button {
                    withAnimation { showLyrics.toggle() }
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.title3)
                }
                .foregroundStyle(showLyrics ? Color.accentColor : Color.secondary)
                .disabled(lyrics.lines == nil)
                .accessibilityLabel(showLyrics ? "Hide lyrics" : "Show lyrics")

                Button {
                    showingQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                }
                .foregroundStyle(Color.secondary)
                .accessibilityLabel("Queue")

                RoutePicker()
                    .frame(width: 30, height: 30)

                sleepMenu
            }
            .sheet(isPresented: $showingQueue) {
                QueueView(player: player)
            }

            if let error = player.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            // On this library the device profile and server always agree, so
            // seeing this means something is off worth noticing.
            if player.isTranscoding {
                Text("Transcoding")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubPosition : player.positionSeconds },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(player.durationSeconds, 1),
                    onEditingChanged: { editing in
                        if editing {
                            isScrubbing = true
                            scrubPosition = player.positionSeconds
                        } else {
                            isScrubbing = false
                            Task { await player.seek(to: scrubPosition) }
                        }
                    }
                )
                HStack {
                    Text(clock(isScrubbing ? scrubPosition : player.positionSeconds))
                    Spacer()
                    let shown = isScrubbing ? scrubPosition : player.positionSeconds
                    Text("-\(clock(max(player.durationSeconds - shown, 0)))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 40) {
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                }
                .foregroundStyle(player.shuffle ? Color.accentColor : Color.secondary)
                // The state is only a color otherwise, which VoiceOver cannot see.
                .accessibilityLabel("Shuffle")
                .accessibilityValue(player.shuffle ? "On" : "Off")

                Button {
                    Task { await player.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title)
                }

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 64))
                }

                Button {
                    Task { await player.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title)
                }

                Button {
                    player.cycleRepeat()
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                }
                .foregroundStyle(player.repeatMode == .none ? Color.secondary : Color.accentColor)
                // Without these VoiceOver read the repeat-one symbol as "Go Forward".
                .accessibilityLabel("Repeat")
                .accessibilityValue(player.repeatMode == .one ? "One" : player.repeatMode == .all ? "All" : "Off")
            }

            Spacer()
        }
        .padding()
    }
    #endif
}

#if os(iOS)
/// The system AirPlay button. Apple's own picker rather than a custom list:
/// it knows the routes, the permissions and the current output, and SwiftUI
/// has no equivalent.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .secondaryLabel
        view.activeTintColor = .tintColor
        view.accessibilityLabel = "AirPlay"
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
