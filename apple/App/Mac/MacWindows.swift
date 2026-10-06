import SwiftUI
import AppKit
import CascadeKit

// Owner: windows agent (N2). The miniplayer is in Miniplayer.swift and the lyrics editor in
// LyricsEditor.swift; this file holds what they share and the menu entry that opens them.

/// A blurred, translucent backdrop behind the window's content (the desktop's `vibrancy:
/// 'under-window'`).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Reports the mouse wheel over the view it backs, with the scroll amount, without taking the
/// event: a local monitor only listens. A trackpad sends many small deltas and a wheel notch one
/// big one, so callers scale by `precise`.
struct WheelCatcher: NSViewRepresentable {
    /// Positive for a scroll up, `precise` for a trackpad.
    let onScroll: (_ delta: CGFloat, _ precise: Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = WheelCatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { (v as? WheelCatcherView)?.onScroll = onScroll }

    final class WheelCatcherView: NSView {
        var onScroll: (CGFloat, Bool) -> Void = { _, _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onScroll(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                }
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The main window, which the miniplayer stands in for. SwiftUI names a `WindowGroup(id: "main")`
/// window "main-AppWindow-N".
@MainActor
enum MainWindows {
    static func all(except mini: NSWindow? = nil) -> [NSWindow] {
        NSApp.windows.filter { $0 !== mini && !($0 is NSPanel) && ($0.identifier?.rawValue.hasPrefix("main") ?? false) }
    }

    static func minimize(except mini: NSWindow?) {
        for w in all(except: mini) where !w.isMiniaturized { w.miniaturize(nil) }
    }

    /// Always on the miniplayer's way out: every path that loses it must bring the main window
    /// back, or there is no window at all (miniplayer-restore in main.js).
    static func restore() {
        for w in all() {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
    }
}

/// "Open Miniplayer" in the Window menu, ahead of the stock items.
struct WindowCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .windowList) { OpenMiniplayerButton() }
    }
}

private struct OpenMiniplayerButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // No shortcut: Option-Command-M is macOS's Minimize All.
        Button("Open Miniplayer") { openWindow(id: "miniplayer") }
    }
}
