import SwiftUI
import CascadeKit

/// What is playing, along the bottom of the window: art and title, transport,
/// a scrubber and the volume. Any empty part of the bar opens Now Playing (the controls keep
/// their own clicks), as on the desktop, where the right half was once a dead zone.
struct PlayerBar: View {
    let player: PlaybackService
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var playedOverride: Bool?
    @State private var addingToPlaylist = false
    private var ui: MacNowPlayingUI { .shared }

    var body: some View {
        HStack(spacing: 16) {
            // A button too (not only the bar's tap below), so it is reachable by keyboard and VoiceOver.
            // The artist is a link of its own, so the button stops short of it.
            HStack(spacing: 10) {
                Button(action: openNowPlaying) {
                    ArtworkView(itemId: player.item?.albumId ?? player.item?.id, size: 44, animated: true)
                        .overlay { CoverSliceOverlay(player: player, size: 44, showsSeam: false).clipShape(ProportionalRoundedRectangle()) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Now Playing")
                // The desktop's right-click on the bar's cover: the Now Playing menu.
                .contextMenu {
                    if let track = player.item {
                        TrackMenuItems(track: track, favorite: ui.favoriteBinding(track.id), played: $playedOverride,
                                       addingToPlaylist: $addingToPlaylist, nowPlaying: true)
                        Section { SleepTimerMenu(player: player) }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: openNowPlaying) {
                        Text(player.item?.name ?? "Not playing").lineLimit(1).explicitMark(player.item?.id ?? "")
                    }
                    .buttonStyle(.plain)
                    ArtistLink(name: player.item?.albumArtist ?? player.item?.artists?.first ?? "",
                               id: (player.item?.albumArtists?.first ?? player.item?.artistItems?.first)?.id)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.item != nil {
                    let liked = ui.isFavorite(player.item)
                    Button { ui.toggleFavorite(player.item, client: state.client) } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                    }
                    .buttonStyle(.hover)
                    .foregroundStyle(liked ? Color(red: 1, green: 0.42, blue: 0.54) : .secondary)
                    .help(liked ? "Unfavorite" : "Favorite")
                    .accessibilityLabel(liked ? "Unfavorite" : "Favorite")
                }
            }
            .frame(width: 260, alignment: .leading)

            VStack(spacing: 4) {
                HStack(spacing: 18) {
                    Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                        .foregroundStyle(player.shuffle ? MacTheme.shared.accent : .secondary)
                        .accessibilityLabel("Shuffle")
                    Button { Task { await player.previous() } } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous")
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPaused ? "Play" : "Pause")
                    Button { Task { await player.next() } } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Next")
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    }
                    .foregroundStyle(player.repeatMode == .none ? .secondary : MacTheme.shared.accent)
                    .accessibilityLabel("Repeat")
                }
                .buttonStyle(.hover)
                Scrubber(player: player)
            }
            .frame(maxWidth: 520)

            HStack(spacing: 10) {
                // The side lyrics panel, over whatever is on screen.
                Button { ui.sidePanelOpen.toggle() } label: {
                    Image(systemName: ui.sidePanelOpen ? "quote.bubble.fill" : "quote.bubble")
                }
                .buttonStyle(.hover)
                .foregroundStyle(ui.sidePanelOpen ? MacTheme.shared.accent : .secondary)
                .help("Lyrics")
                .accessibilityLabel("Lyrics")
                Button { openWindow(id: "miniplayer") } label: { Image(systemName: "pip") }
                    .buttonStyle(.hover)
                    .foregroundStyle(.secondary)
                    .help("Miniplayer")
                    .accessibilityLabel("Open the miniplayer")
                HStack(spacing: 6) {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .onTapGesture { player.setMuted(!player.isMuted) }
                        .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
                        .accessibilityAddTraits(.isButton)
                    MacSlider(value: Double(player.isMuted ? 0 : player.volume), fill: .secondary, label: "Volume") {
                        // Moving the slider is a wish to hear it.
                        if player.isMuted { player.setMuted(false) }
                        player.setVolume(Float($0))
                    }
                    .frame(width: 110)
                }
            }
            .frame(width: 240, alignment: .trailing)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        // The whole bar, but a control's own click wins over this one, so only what is not a
        // control opens Now Playing.
        .contentShape(Rectangle())
        .onTapGesture(perform: openNowPlaying)
        .disabled(player.item == nil)
        .sheet(isPresented: $addingToPlaylist) {
            if let track = player.item { AddToPlaylistSheet(track: track).environment(state) }
        }
        .onChange(of: player.item?.id) { playedOverride = nil }
    }

    private func openNowPlaying() {
        if player.item != nil { withAnimation(.easeInOut(duration: 0.38)) { state.nowPlayingOpen = true } }
    }
}

/// The position slider. Holds its own value while dragging so the half-second
/// position updates do not yank the knob back under the pointer.
struct Scrubber: View {
    let player: PlaybackService
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(clock(dragging ?? player.positionSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { dragging ?? player.positionSeconds }, set: { dragging = $0 }),
                   in: 0...max(player.durationSeconds, 1)) { editing in
                if !editing, let target = dragging {
                    Task {
                        await player.seek(to: target)
                        dragging = nil
                    }
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Position")
            Text(clock(player.durationSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
