import SwiftUI

/// A thin bar you drag or click, and step with the keyboard once it has focus: the arrows by
/// `step`, Page Up and Page Down by `bigStep`, Home and End to either end (the desktop's
/// wireBar). SwiftUI's own Slider takes the arrows for itself with a step it does not let
/// you set and has no Page keys, so the volume and the overlay's scrubber are this instead.
struct MacSlider: View {
    /// 0 to 1.
    let value: Double
    var step = 0.05
    var bigStep = 0.2
    var height: CGFloat = 4
    /// The fill. The unfilled part is this at low opacity.
    var fill: Color = MacTheme.shared.accent
    /// Spoken name and value for VoiceOver.
    var label: String
    var valueText: (Double) -> String = { "\(Int(($0 * 100).rounded())) percent" }
    /// Called on every drag movement and key step.
    let onChange: (Double) -> Void
    /// Called when a drag ends, and a moment after the last key step (a held key repeats
    /// many times a second, and committing each would do to a seek what per-pixel dragging
    /// would). Nil: onChange is all there is.
    var onCommit: ((Double) -> Void)?

    @State private var dragging = false
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { bar in
            let knob = height * 3 + (dragging ? 2 : 0)
            let x = max(0, min(1, value)) * bar.size.width
            ZStack(alignment: .leading) {
                Group {
                    Capsule().fill(fill.opacity(0.25))
                    Capsule().fill(fill)
                        .frame(width: x)
                }
                .frame(height: dragging ? height + 3 : height)
                // The handle: where the value is, and something to grab.
                Circle().fill(fill)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: min(max(0, x - knob / 2), bar.size.width - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        onChange(min(1, max(0, drag.location.x / max(bar.size.width, 1))))
                    }
                    .onEnded { drag in
                        dragging = false
                        onCommit?(min(1, max(0, drag.location.x / max(bar.size.width, 1))))
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: max(18, height * 3 + 6))
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { press in
            let next: Double
            switch press.key {
            case .leftArrow, .downArrow: next = max(0, value - step)
            case .rightArrow, .upArrow: next = min(1, value + step)
            case .pageDown: next = max(0, value - bigStep)
            case .pageUp: next = min(1, value + bigStep)
            case .home: next = 0
            default: next = 1
            }
            // Handled here, so the video overlay's own arrow keys never also act on the press.
            onChange(next)
            if let onCommit {
                commitTask?.cancel()
                commitTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    onCommit(next)
                }
            }
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText(value))
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? min(1, value + step) : max(0, value - step)
            onChange(next)
            onCommit?(next)
        }
    }
}
