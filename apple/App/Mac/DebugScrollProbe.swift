#if DEBUG
import AppKit

/// Debug builds only: `-cascade.debugAutoScroll YES` scrolls the biggest
/// scroll view in the window by itself for a few seconds, 120 steps a second,
/// and reports to stderr how evenly the steps landed. A long gap is the main
/// thread stalling mid-scroll, the jitter people see; measured without UI
/// scripting, which this machine does not allow.
@MainActor
enum DebugScrollProbe {
    static func runIfAsked() {
        guard UserDefaults.standard.bool(forKey: "cascade.debugAutoScroll") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { run() }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
    }

    private static func run() {
        guard let content = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 800 })?.contentView,
              let scroll = scrollViews(in: content).max(by: {
                  ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
              }) else {
            FileHandle.standardError.write("SCROLLPROBE no scroll view\n".data(using: .utf8)!)
            return
        }
        let clip = scroll.contentView
        var last = CACurrentMediaTime()
        var gaps: [Double] = []
        let start = last
        Task { @MainActor in
            while CACurrentMediaTime() - start <= 5 {
                try? await Task.sleep(for: .milliseconds(8))
                let now = CACurrentMediaTime()
                gaps.append((now - last) * 1000)
                last = now
                var origin = clip.bounds.origin
                origin.y += 12
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
            }
            let sorted = gaps.sorted()
            let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            let report = String(format: "SCROLLPROBE steps=%d median=%.1fms p95=%.1fms max=%.1fms over25ms=%d over50ms=%d\n",
                                gaps.count, p(0.5), p(0.95), sorted.last ?? 0,
                                gaps.filter { $0 > 25 }.count, gaps.filter { $0 > 50 }.count)
            FileHandle.standardError.write(report.data(using: .utf8)!)
        }
    }
}
#endif
