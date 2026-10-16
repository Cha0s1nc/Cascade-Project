import Foundation

/// A downloaded video's text subtitles, saved as WebVTT beside the file.
///
/// AVPlayer only offers subtitles that come inside the stream (an HLS
/// manifest or the file itself); an AVURLAsset will not open a .vtt file, and
/// a remuxed download carries no subtitle track. So the cues are read here and
/// the player draws the one playing over the picture.
public struct WebVTT: Sendable, Equatable {
    public struct Cue: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    /// In start order.
    public var cues: [Cue]

    /// Parses what the server's subtitle endpoint sends (Stream.vtt). Styling
    /// tags (<i>, <b>, <c.x>, voice spans) are dropped: the overlay draws plain
    /// text. A cue that cannot be read is skipped, never fatal.
    public init(_ text: String) {
        var cues: [Cue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = Self.seconds(parts[0]),
                  let end = Self.seconds(parts[1].split(separator: " ").first.map(String.init) ?? ""), end > start else { continue }
            let body = lines[(timing + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
        }
        self.cues = cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03.456" or "02:03.456".
    static func seconds(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let last = Double(parts.last!) else { return nil }
        var total = last
        for (i, p) in parts.dropLast().reversed().enumerated() {
            guard let n = Double(p) else { return nil }
            total += n * (i == 0 ? 60 : 3600)
        }
        return total
    }

    /// The text showing at `time`, cues overlapping joined by line, or nil.
    public func text(at time: Double) -> String? {
        let showing = cues.filter { $0.start <= time && time < $0.end }.map(\.text)
        return showing.isEmpty ? nil : showing.joined(separator: "\n")
    }
}
