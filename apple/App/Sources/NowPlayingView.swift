import SwiftUI
import CascadeKit

/// Full screen player. iOS gets a sheet with a scrub slider and transport
/// buttons; tvOS gets the chrome-less Apple Music style screen: artwork as the
/// only focus target, remote directions for transport, queue shown alongside.
struct NowPlayingView: View {
    let player: PlaybackService

    #if !os(tvOS)
    @Environment(\.dismiss) private var dismiss
    // While the user is dragging, the slider owns the value; the player still
    // publishes a position every half second underneath and would otherwise
    // yank the thumb back under the finger.
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    #endif

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        iosBody
        #endif
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

            if !player.queue.items.isEmpty {
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

            ArtworkView(itemId: player.item?.albumId ?? player.item?.id, size: 300)

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
            }

            Spacer()
        }
        .padding()
    }
    #endif
}
