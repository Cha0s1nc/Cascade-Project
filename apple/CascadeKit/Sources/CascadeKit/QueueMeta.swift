import Foundation

// What the queue panel says under "Up Next": where the queue came from, how far
// through it we are and when it ends. A port of src/core/queue.ts's
// queueRemainingSec, formatQueueSpan and queueSourceFallback.

public enum QueueMeta {
    /// Seconds left in the queue: what remains of the current track plus every
    /// track after it. A track with no RunTimeTicks counts as 0.
    public static func remainingSeconds(_ queue: [JfItem], index: Int, position: Double) -> Double {
        guard queue.indices.contains(index) else { return 0 }
        func length(_ i: Int) -> Double { Double(queue[i].runTimeTicks ?? 0) / Double(Lyrics.ticksPerSecond) }
        let played = position.isFinite ? max(0, position) : 0
        var total = max(0, length(index) - played)
        for i in (index + 1)..<max(index + 1, queue.count) { total += length(i) }
        return total
    }

    /// A long span as the panel shows it: "1d 1h", "2h 5m", "34m", "<1m".
    public static func formatSpan(_ seconds: Double) -> String {
        let m = Int(max(0, seconds.isFinite ? seconds : 0) / 60)
        if m < 1 { return "<1m" }
        let d = m / 1440, h = m / 60 % 24, min = m % 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return min > 0 ? "\(h)h \(min)m" : "\(h)h" }
        return "\(min)m"
    }

    /// What to call a queue in "From ..." when the caller did not say: the
    /// album's name when every track is from one album, otherwise nothing.
    public static func sourceFallback(_ items: [JfItem]) -> String? {
        guard let first = items.first, let albumId = first.albumId, let album = first.album else { return nil }
        return items.allSatisfy { $0.albumId == albumId } ? album : nil
    }

    /// "12 of 40 · 1h 5m · ends 10:12 PM". The end time is only worked out
    /// when the queue has one: with repeat or auto-mix on it never ends.
    /// `now` and `formatTime` are injectable so a test can pin the clock and the locale.
    public static func summary(queue: [JfItem], index: Int, position: Double, repeating: Bool, autoMix: Bool,
                               now: Date = .now,
                               formatTime: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String {
        guard queue.indices.contains(index) else { return "" }
        var parts = ["\(index + 1) of \(queue.count)"]
        if !repeating && !autoMix {
            let left = remainingSeconds(queue, index: index, position: position)
            parts.append("\(formatSpan(left)) · ends \(formatTime(now.addingTimeInterval(left)))")
        }
        return parts.joined(separator: " · ")
    }
}
