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
    @Environment(\.uiScale) private var zoom
    @AppStorage(MacNowPlayingUI.layoutKey) private var npLayout = MacNowPlayingUI.Layout.bar
    private var ui: MacNowPlayingUI { .shared }
    /// Now Playing shows the cover big beside the bar: this one steps aside (Flutter's).
    private var coverAside: Bool { npLayout == .bar && state.nowPlayingOpen }

    var body: some View {
        HStack(spacing: 16) {
            // A button too (not only the bar's tap below), so it is reachable by keyboard and VoiceOver.
            // The artist is a link of its own, so the button stops short of it.
            HStack(spacing: 10) {
                Button(action: openNowPlaying) {
                    ArtworkView(itemId: player.item?.albumId ?? player.item?.id, size: 48, animated: true)
                        .overlay { CoverSliceOverlay(player: player, size: 48, showsSeam: false).clipShape(ProportionalRoundedRectangle()) }
                        .overlay { LoadingCoverOverlay(active: player.isWaitingToPlay).clipShape(ProportionalRoundedRectangle()) }
                }
                .buttonStyle(.plain)
                .frame(width: coverAside ? 0 : nil, alignment: .leading)
                .opacity(coverAside ? 0 : 1)
                .scaleEffect(coverAside ? 0.6 : 1, anchor: .leading)
                .animation(.easeInOut(duration: 0.32), value: coverAside)
                .accessibilityHidden(coverAside)
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
                        Text(player.item?.name ?? "Not playing").cx(.strong).foregroundStyle(Cx.text)
                            .lineLimit(1).explicitMark(player.item?.id ?? "")
                    }
                    .buttonStyle(.plain)
                    ArtistLink(name: player.item?.albumArtist ?? player.item?.artists?.first ?? "",
                               id: (player.item?.albumArtists?.first ?? player.item?.artistItems?.first)?.id)
                        .cx(.small).foregroundStyle(Cx.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.item != nil {
                    let liked = ui.isFavorite(player.item)
                    Button { ui.toggleFavorite(player.item, client: state.client) } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                    }
                    .buttonStyle(.hover)
                    .foregroundStyle(liked ? MacTheme.favorite : Cx.text2)
                    .help(liked ? "Unfavorite" : "Favorite")
                    .accessibilityLabel(liked ? "Unfavorite" : "Favorite")
                }
            }
            // The desktop's grid (1fr auto 1fr): the two sides share what the window has
            // equally, so the controls stay centered and the title gets room as it grows.
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                HStack(spacing: 18) {
                    // On shows as color and a dot, as in Apple Music: color alone is easy to miss.
                    Button { player.toggleShuffle() } label: { Image(systemName: "shuffle").overlay(alignment: .bottom) { OnDot(isOn: player.shuffle) } }
                        .foregroundStyle(player.shuffle ? MacTheme.shared.accent : Cx.text2)
                        .help("Shuffle")
                        .accessibilityLabel("Shuffle")
                        .accessibilityValue(player.shuffle ? "On" : "Off")
                    Button { Task { await player.previous() } } label: { Image(systemName: "backward.fill") }
                        .help("Previous")
                        .accessibilityLabel("Previous")
                    // Personality v1's solid accent button with dark ink.
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 15 * zoom, weight: .bold))
                            .foregroundStyle(Cx.ink)
                            .frame(width: 38 * zoom, height: 38 * zoom)
                            .background(Cx.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(player.isPaused ? "Play" : "Pause")
                    .accessibilityLabel(player.isPaused ? "Play" : "Pause")
                    Button { Task { await player.next() } } label: { Image(systemName: "forward.fill") }
                        .help("Next")
                        .accessibilityLabel("Next")
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .overlay(alignment: .bottom) { OnDot(isOn: player.repeatMode != .none) }
                    }
                    .foregroundStyle(player.repeatMode == .none ? Cx.text2 : MacTheme.shared.accent)
                    .help("Repeat")
                    .accessibilityLabel("Repeat")
                    .accessibilityValue(player.repeatMode == .one ? "One" : player.repeatMode == .all ? "All" : "Off")
                }
                .buttonStyle(.hover)
                .foregroundStyle(Cx.text2)
                if player.isRadio { LiveBadge().frame(height: 18) } else { Scrubber(player: player) }
            }
            .frame(minWidth: 300, maxWidth: 560)

            HStack(spacing: 10) {
                // Now Playing on its Lyrics or Queue, or closed again (Flutter's player bar).
                panelButton(.lyrics, symbol: "quote.bubble", label: "Lyrics")
                panelButton(.queue, symbol: "list.bullet", label: "Queue")
                // The side lyrics column beside whatever is on screen.
                Button { ui.sidePanelOpen.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.hover)
                    .foregroundStyle(ui.sidePanelOpen ? MacTheme.shared.accent : Cx.text2)
                    .help("Lyrics beside the library")
                    .accessibilityLabel("Lyrics beside the library")
                    .accessibilityValue(ui.sidePanelOpen ? "Open" : "Closed")
                Button { openWindow(id: "miniplayer") } label: { Image(systemName: "pip") }
                    .buttonStyle(.hover)
                    .foregroundStyle(Cx.text2)
                    .help("Miniplayer")
                    .accessibilityLabel("Open the miniplayer")
                HStack(spacing: 6) {
                    Button { player.setMuted(!player.isMuted) } label: {
                        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    }
                    .buttonStyle(.hover)
                    .help(player.isMuted ? "Unmute" : "Mute")
                    .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
                    MacSlider(value: Double(player.isMuted ? 0 : player.volume), fill: Cx.text2, track: Cx.track, label: "Volume") {
                        // Moving the slider is a wish to hear it.
                        if player.isMuted { player.setMuted(false) }
                        player.setVolume(Float($0))
                    }
                    .frame(width: 130)
                }
            }
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .trailing)
            .foregroundStyle(Cx.text2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Cx.surface)
        .overlay(alignment: .top) { Cx.line.frame(height: 1) }
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

    private func panelButton(_ panel: MacNowPlayingUI.RightPanel, symbol: String, label: String) -> some View {
        let on = state.nowPlayingOpen && ui.rightPanel == panel
        return Button { ui.show(panel, state: state) } label: { Image(systemName: symbol) }
            .buttonStyle(.hover)
            .foregroundStyle(on ? MacTheme.shared.accent : Cx.text2)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Opens Now Playing; with the player bar staying under it, the bar closes it again.
    private func openNowPlaying() {
        guard player.item != nil else { return }
        withAnimation(.easeInOut(duration: 0.38)) { state.nowPlayingOpen = npLayout == .bar ? !state.nowPlayingOpen : true }
    }
}

/// The position slider. Holds its own value while dragging so the half-second
/// position updates do not yank the knob back under the pointer.
struct Scrubber: View {
    let player: PlaybackService
    @State private var dragging: Double?

    var body: some View {
        let duration = max(player.durationSeconds, 1)
        let position = dragging ?? player.positionSeconds
        HStack(spacing: 12) {
            Text(clock(position)).cx(.small).monospacedDigit().foregroundStyle(Cx.text3)
            // Personality v1's 4 pt bar: the accent over the track color.
            MacSlider(value: position / duration, step: 5 / duration, bigStep: 30 / duration,
                      track: Cx.track, label: "Position",
                      valueText: { "\(clock($0 * duration)) of \(clock(duration))" },
                      onChange: { dragging = $0 * duration },
                      onCommit: { target in
                          Task {
                              await player.seek(to: target * duration)
                              dragging = nil
                          }
                      })
            Text(clock(player.durationSeconds)).cx(.small).monospacedDigit().foregroundStyle(Cx.text3)
        }
    }
}

/// The small dot under an on shuffle or repeat. Always laid out, so turning one on never
/// moves the buttons.
struct OnDot: View {
    let isOn: Bool
    var body: some View {
        Circle().frame(width: 3, height: 3).offset(y: 5).opacity(isOn ? 1 : 0).accessibilityHidden(true)
    }
}

/// Internet radio in place of a scrubber: a stream has no length to scrub (the desktop's
/// red LIVE badge, in the bar and the miniplayer).
struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(red: 0.94, green: 0.27, blue: 0.27), in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("Live stream")
    }
}
