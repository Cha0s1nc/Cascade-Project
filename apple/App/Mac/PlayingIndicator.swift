import SwiftUI
import CascadeKit

/// The bars on the playing row, for any track list to put on a row. Nothing is drawn for a
/// row that is not the playing track, or while it is paused. The bars only ever show the real
/// audio, from the playing item's tap (PlaybackService.tapBars, the desktop's analyser ported
/// in PlayingBars); with no tap attached they lie flat as a marker, never a canned animation.
/// A tap is never attached just for this: it costs the gapless handover (apple/CODEMAP.md),
/// so it is there only while the EQ is on. With Reduce Motion on they hold still too.
struct PlayingIndicator: View {
    let itemId: String
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let player = state.player, player.item?.id == itemId, !player.isPaused {
            let live = player.tapBars != nil && !reduceMotion
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { _ in
                let bars = (live ? player.tapBars : nil) ?? SIMD8(repeating: PlayingBars.minHeight)
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(0..<PlayingBars.count, id: \.self) { i in
                        Capsule().frame(width: 2, height: 14 * CGFloat(bars[i]))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .animation(.linear(duration: 0.08), value: bars)
                .foregroundStyle(MacTheme.shared.accent)
            }
            .frame(width: 20, height: 14)
            .accessibilityLabel("Playing")
        }
    }
}
