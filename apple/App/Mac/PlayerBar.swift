import SwiftUI
import CascadeKit

/// What is playing, along the bottom of the window: art and title, transport,
/// a scrubber and the volume.
struct PlayerBar: View {
    let player: PlaybackService

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                ArtworkView(itemId: player.item?.albumId ?? player.item?.id, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.item?.name ?? "Not playing").lineLimit(1)
                    Text(player.item?.albumArtist ?? player.item?.artists?.first ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 240, alignment: .leading)

            VStack(spacing: 4) {
                HStack(spacing: 18) {
                    Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                        .foregroundStyle(player.shuffle ? Color.accentColor : .secondary)
                        .accessibilityLabel("Shuffle")
                    Button { Task { await player.previous() } } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous")
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.title2)
                    }
                    .accessibilityLabel(player.isPaused ? "Play" : "Pause")
                    Button { Task { await player.next() } } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Next")
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    }
                    .foregroundStyle(player.repeatMode == .none ? .secondary : Color.accentColor)
                    .accessibilityLabel("Repeat")
                }
                .buttonStyle(.plain)
                Scrubber(player: player)
            }
            .frame(maxWidth: 520)

            HStack(spacing: 6) {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .onTapGesture { player.setMuted(!player.isMuted) }
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                    .frame(width: 110)
                    .accessibilityLabel("Volume")
            }
            .frame(width: 240, alignment: .trailing)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .disabled(player.item == nil)
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
