import SwiftUI
import CascadeKit
#if os(iOS)
import AVKit
import MediaPlayer
#endif

/// Full screen player, over the desktop's album-art background.
///
/// iOS follows Apple Music's layout: big artwork with the title, a heart and a
/// ··· menu under it, a thin scrubber, borderless transport, the system volume
/// slider, and a bottom bar of lyrics, AirPlay and queue. Lyrics and queue
/// replace the artwork, which shrinks into a compact header, rather than
/// opening screens of their own. tvOS gets the chrome-less screen: artwork as
/// the only focus target, remote directions for transport, lyrics or the
/// queue alongside.
struct NowPlayingView: View {
    let player: PlaybackService
    @Environment(AppState.self) private var state
    @State private var lyrics = LyricsModel()
    /// Overrides of the playing item's snapshot, which a server answer does
    /// not update. Nil until toggled; reset on every track change.
    @State private var favoriteOverride: Bool?
    @State private var playedOverride: Bool?

    #if !os(tvOS)
    enum Mode { case artwork, lyrics, queue }
    @State private var mode: Mode = .artwork
    @Namespace private var artworkSpace
    // While the user is dragging, the scrubber owns the value; the player still
    // publishes a position every half second underneath and would otherwise
    // yank the thumb back under the finger.
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var addingToPlaylist = false
    @State private var routeName = ""
    #endif

    private var artId: String? { player.item?.albumId ?? player.item?.id }
    private var isFavorite: Bool { favoriteOverride ?? player.item?.userData?.isFavorite ?? false }

    var body: some View {
        Group {
            #if os(tvOS)
            tvBody
            #else
            iosBody
            #endif
        }
        .background { NowPlayingBackground(itemId: artId) }
        // White on the blobs whatever the rest of the app is using. Not
        // preferredColorScheme: from inside a sheet that flips the whole app.
        .environment(\.colorScheme, .dark)
        .task(id: "\(player.item?.id ?? "")|\(String(describing: state.cascadePluginApi))") {
            favoriteOverride = nil
            playedOverride = nil
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
                if player.item?.id == id { favoriteOverride = target }
            } catch {}
        }
    }

    #if os(tvOS)
    private var tvBody: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(spacing: 24) {
                ArtworkView(itemId: artId, size: 480)
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

    // MARK: - iOS layout

    private var iosBody: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if mode == .artwork {
                    Spacer(minLength: 16)
                    bigArtwork(side: min(geo.size.width - 56, geo.size.height * 0.46))
                    Spacer(minLength: 24)
                    titleRow(compact: false)
                } else {
                    compactHeader
                        .padding(.top, 20)
                    Group {
                        if mode == .lyrics { lyricsPanel } else { queuePanel }
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                }
                if let error = player.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                scrubber.padding(.top, 20)
                transport.padding(.vertical, 18)
                volume
                bottomBar.padding(.top, 18)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
            .foregroundStyle(.white)
        }
        .sheet(isPresented: $addingToPlaylist) {
            if let track = player.item {
                AddToPlaylistSheet(track: track).environment(state)
            }
        }
        .onChange(of: lyrics.lines == nil) { _, missing in
            // A track without lyrics started while they were showing.
            if missing && mode == .lyrics { withAnimation(.spring(duration: 0.4)) { mode = .artwork } }
        }
        .onAppear(perform: updateRouteName)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            updateRouteName()
        }
    }

    /// Apple's artwork breathes with playback: full size while playing, eased
    /// back a little when paused.
    private func bigArtwork(side: CGFloat) -> some View {
        ArtworkView(itemId: artId, size: side)
            .matchedGeometryEffect(id: "artwork", in: artworkSpace)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .scaleEffect(player.isPaused ? 0.86 : 1)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: player.isPaused)
            .frame(maxWidth: .infinity)
    }

    private var compactHeader: some View {
        HStack(spacing: 14) {
            ArtworkView(itemId: artId, size: 64)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                .onTapGesture { setMode(.artwork) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Show artwork")
            titleRow(compact: true)
        }
    }

    private func titleRow(compact: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.item?.name ?? "Nothing playing")
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .lineLimit(1)
                Text(player.item?.albumArtist ?? player.item?.artists?.first ?? "")
                    .font(compact ? .subheadline : .title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            circleButton(isFavorite ? "heart.fill" : "heart", action: toggleFavorite)
                .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")
            moreMenu
        }
    }

    /// Everything that is not worth a button of its own: the same actions as a
    /// track row's long-press menu, then the sleep timer.
    private var moreMenu: some View {
        Menu {
            if let track = player.item {
                TrackMenuItems(track: track, favorite: $favoriteOverride, played: $playedOverride,
                               addingToPlaylist: $addingToPlaylist)
            }
            Section { sleepMenu }
        } label: {
            circleLabel("ellipsis")
        }
        .accessibilityLabel("More")
    }

    /// The desktop's sleep timer choices, as a submenu of ···.
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
            Label(player.sleepTimer == .off ? "Sleep Timer" : "Sleep Timer (On)",
                  systemImage: player.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
        }
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(symbol) }
            .buttonStyle(.plain)
    }

    private func circleLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .frame(width: 34, height: 34)
            .background(Circle().fill(.white.opacity(0.14)))
            .contentShape(Circle())
    }

    // MARK: Scrubber and transport

    private var shownPosition: Double { isScrubbing ? scrubPosition : player.positionSeconds }

    /// A thin bar that thickens under the finger, like Apple's. Drag anywhere
    /// on it; the seek happens on release, not on every movement.
    private var scrubber: some View {
        VStack(spacing: 7) {
            GeometryReader { bar in
                let duration = max(player.durationSeconds, 1)
                let fraction = min(1, max(0, shownPosition / duration))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(isScrubbing ? 0.95 : 0.7))
                        .frame(width: fraction * bar.size.width)
                }
                .frame(height: isScrubbing ? 12 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !isScrubbing { isScrubbing = true }
                            scrubPosition = min(1, max(0, drag.location.x / bar.size.width)) * duration
                        }
                        .onEnded { _ in
                            let target = scrubPosition
                            Task {
                                await player.seek(to: target)
                                isScrubbing = false
                            }
                        }
                )
            }
            .frame(height: 22)
            .animation(.spring(duration: 0.25), value: isScrubbing)

            HStack {
                Text(clock(shownPosition))
                Spacer()
                // In Apple's "Lossless" spot. Expected under a quality cap; at
                // Original it means the profile and the server disagree.
                if player.isTranscoding {
                    Text("TRANSCODING")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(.white.opacity(0.35)))
                }
                Spacer()
                Text("-\(clock(max(player.durationSeconds - shownPosition, 0)))")
            }
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Track position")
        .accessibilityValue("\(clock(shownPosition)) of \(clock(player.durationSeconds))")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 10.0 : -10.0
            let target = min(max(player.positionSeconds + step, 0), player.durationSeconds)
            Task { await player.seek(to: target) }
        }
    }

    private var transport: some View {
        HStack {
            Spacer()
            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.fill").font(.system(size: 32))
            }
            .accessibilityLabel("Previous")
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 46))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 64, height: 64)
            }
            .accessibilityLabel(player.isPaused ? "Play" : "Pause")
            Spacer()
            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.fill").font(.system(size: 32))
            }
            .accessibilityLabel("Next")
            Spacer()
        }
        .buttonStyle(.plain)
    }

    /// The system volume, as Apple Music shows it, rather than the player's
    /// own gain.
    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            SystemVolumeSlider().frame(height: 34)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: Bottom bar and modes

    private var bottomBar: some View {
        HStack(alignment: .top) {
            modeButton(.lyrics, symbol: "quote.bubble", label: "Lyrics")
                .disabled(lyrics.lines == nil)
                .opacity(lyrics.lines == nil ? 0.35 : 1)
            Spacer()
            VStack(spacing: 3) {
                RoutePicker().frame(width: 30, height: 30)
                Text(routeName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            modeButton(.queue, symbol: "list.bullet", label: "Queue")
                .overlay(alignment: .topTrailing) {
                    if player.shuffle {
                        Image(systemName: "shuffle")
                            .font(.system(size: 8, weight: .bold))
                            .padding(4)
                            .background(Circle().fill(.white.opacity(0.3)))
                            .offset(x: 2, y: -2)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func modeButton(_ target: Mode, symbol: String, label: String) -> some View {
        Button { setMode(mode == target ? .artwork : target) } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(mode == target ? 0.22 : 0)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(mode == target ? "Showing" : "")
    }

    private func setMode(_ target: Mode) {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { mode = target }
    }

    @ViewBuilder private var lyricsPanel: some View {
        if let lines = lyrics.lines {
            LyricsView(lines: lines, player: player)
        } else {
            Text("No lyrics for this song")
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Apple's queue page: the play mode toggles as capsules, then what plays
    /// next, dragged by its handles.
    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                capsuleToggle("shuffle", isOn: player.shuffle, label: "Shuffle") { player.toggleShuffle() }
                capsuleToggle(player.repeatMode == .one ? "repeat.1" : "repeat",
                              isOn: player.repeatMode != .none, label: "Repeat",
                              value: player.repeatMode == .one ? "One" : player.repeatMode == .all ? "All" : "Off") {
                    player.cycleRepeat()
                }
            }
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 1) {
                Text("Up Next").font(.headline)
                let upcoming = max(0, player.queue.items.count - player.queue.index - 1)
                Text(upcoming == 1 ? "1 song" : "\(upcoming) songs")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            List {
                QueueList(player: player, upcomingOnly: true, deleteFromMenu: true)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // For the drag handles; rows are removed from their long-press menu.
            .environment(\.editMode, .constant(.active))
        }
    }

    private func capsuleToggle(_ symbol: String, isOn: Bool, label: String, value: String? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(.white.opacity(isOn ? 0.34 : 0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? (isOn ? "On" : "Off"))
    }

    private func updateRouteName() {
        routeName = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? ""
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
        view.tintColor = UIColor.white.withAlphaComponent(0.8)
        view.activeTintColor = .tintColor
        view.accessibilityLabel = "AirPlay"
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// The system volume slider. MPVolumeView is the only public way to show and
/// set it; it draws nothing in the Simulator.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.tintColor = .white
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
#endif
