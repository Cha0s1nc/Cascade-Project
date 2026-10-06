import SwiftUI
import AppKit
import Darwin
import CascadeKit

/// The performance debug panel, for comparing against the Electron build. Shown at launch when a
/// `.cascade-debug` file sits next to the app or in Application Support; a normal run never sees it.
/// Shift-click the text to copy it.
@MainActor
enum DebugPanel {
    private static var panel: NSPanel?

    static func sentinelExists() -> Bool {
        let fm = FileManager.default
        var dirs = [Bundle.main.bundleURL.deletingLastPathComponent()]
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // This build's own folder, and the Electron app's, so one sentinel serves both.
            dirs.append(support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "xyz.chaosinc.cascade"))
            dirs.append(support.appendingPathComponent("Cascade"))
        }
        return dirs.contains { fm.fileExists(atPath: $0.appendingPathComponent(".cascade-debug").path) }
    }

    static func showIfEnabled(state: AppState) {
        guard panel == nil, sentinelExists() else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Cascade Debug"
        p.isFloatingPanel = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: DebugPanelView(state: state))
        p.setFrameTopLeftPoint(NSPoint(x: 40, y: (NSScreen.main?.visibleFrame.maxY ?? 800) - 40))
        // Handover timing costs a little per track change, so it is only on while someone is looking.
        let before = state.player?.measureHandovers
        state.player?.measureHandovers = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let before { state.player?.measureHandovers = before }
                panel = nil
            }
        }
        p.orderFrontRegardless()
        panel = p
    }
}

private struct DebugPanelView: View {
    let state: AppState
    @State private var cpu = 0.0
    @State private var mem = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let text = lines().joined(separator: "\n")
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard NSEvent.modifierFlags.contains(.shift) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func lines() -> [String] {
        // Called once a second from the timeline; sampling here keeps CPU and memory in step with the lines.
        let cpu = ProcessStats.cpuPercent(), mem = ProcessStats.footprintMB()
        var out = ["memory \(String(format: "%.0f", mem)) MB, cpu \(String(format: "%.1f", cpu))%", ""]
        out += state.player?.debugLines() ?? ["no player yet"]
        out += ["", "shift-click to copy"]
        return out
    }
}

/// Memory and CPU of this process from `task_info` and the thread list.
enum ProcessStats {
    /// phys_footprint is what Activity Monitor calls Memory.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Instantaneous CPU, summed over live threads; 100 is one core.
    static func cpuPercent() -> Double {
        var list: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(n) * MemoryLayout<thread_t>.size)) }
        var total = 0.0
        for i in 0..<Int(n) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 { total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100 }
        }
        return total
    }
}
