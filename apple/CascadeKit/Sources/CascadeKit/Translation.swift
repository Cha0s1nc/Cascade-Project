import Foundation
import NaturalLanguage

// Which language a lyric sheet would be translated from, and what is left of
// the desktop's two-engine choice. Cascade's own Mozilla models are not on the
// Mac (Apple's Translation framework is the only engine), so
// pickTranslationEngine reduces to Apple's three answers. A port of
// src/core/language.ts, with NaturalLanguage in place of franc, and the
// language half of src/core/translation-models.ts.

public enum LyricTranslation {
    /// Below this, language detection is guessing. A two-word line is not enough to
    /// separate English from Dutch, so callers hand in several joined lines.
    static let minChars = 24

    /// Languages asked about, as the codes Apple's Translation framework takes. Only what to
    /// ask: the framework's answer per Mac (installed, supported, unsupported) decides what
    /// is actually offered.
    public static let appleKeys: [String] = [
        "ar", "de", "es", "fr", "hi", "id", "it", "ja", "ko", "nl",
        "pl", "pt", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ]

    // MARK: Detection

    /// Best-guess language of `text` as ISO 639-1 ("zh" for either Chinese script, which
    /// chineseScript then settles), or "" when there is not enough signal to say. "" means
    /// "no idea", never "English": collapsing the two would put a translate button on every
    /// instrumental interlude.
    public static func detectLanguage(_ text: String) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count >= minChars else { return "" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(clean)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return "" }
        // "zh-Hans" and "zh-Hant" are the same answer here; "pt-PT" is Portuguese.
        return String(language.rawValue.split(separator: "-").first ?? "")
    }

    /// Whether to offer translation for these lines: any language that is not English.
    /// Takes the whole sheet rather than the first line, so a Spanish song opening on an
    /// English title line is still offered.
    public static func shouldOffer(_ lines: [String]) -> Bool {
        let lang = detectLanguage(String(lines.joined(separator: " ").prefix(1000)))
        return lang != "" && lang != "en"
    }

    // Common characters written differently in the two Chinese scripts, paired by position.
    // Recognizers say "Chinese" for both and Apple has a model per script, so this picks by
    // counting which spelling the text uses. Deliberately only characters that are
    // unambiguous: pairs where the simplified form is also an ordinary traditional character
    // in its own right (后, 里, 几, 么, 干, 系, 并 ...) are left out, or they would pull
    // traditional text toward simplified. A frequency heuristic, not a converter: a
    // misjudged sheet still translates, somewhat less well.
    static let simplified = Array("们这个来时说会对爱让过还没为发边见听话难远梦离开关长风声忆红泪丽样从头动无与东车飞云灯岁记恋断线问间门场请谁该认识读语写买卖钱儿学实气热应经结给终当两吗伤亲轻转运进选连视觉观现谢严权赋")
    static let traditional = Array("們這個來時說會對愛讓過還沒為發邊見聽話難遠夢離開關長風聲憶紅淚麗樣從頭動無與東車飛雲燈歲記戀斷線問間門場請誰該認識讀語寫買賣錢兒學實氣熱應經結給終當兩嗎傷親輕轉運進選連視覺觀現謝嚴權賦")

    /// "zh-Hans" or "zh-Hant". A tie, including no evidence either way, goes to Simplified:
    /// far more lyrics are published in it.
    public static func chineseScript(_ text: String) -> String {
        var s = 0, t = 0
        let simple = Set(simplified), trad = Set(traditional)
        for ch in text {
            if simple.contains(ch) { s += 1 } else if trad.contains(ch) { t += 1 }
        }
        return t > s ? "zh-Hant" : "zh-Hans"
    }

    /// "ru" or "uk" by their distinctive letters, or nil with no evidence either way.
    /// Recognizers mix the two up on short text (a Russian line came back Ukrainian), and the
    /// source language is what Apple translates from, so these settle it.
    public static func cyrillicLanguage(_ text: String) -> String? {
        var uk = 0, ru = 0
        for ch in text {
            if "іїєґІЇЄҐ".contains(ch) { uk += 1 } else if "ыэъёЫЭЪЁ".contains(ch) { ru += 1 }
        }
        return uk > ru ? "uk" : ru > uk ? "ru" : nil
    }

    /// The language a sheet would be translated from, or nil when Apple's framework could not
    /// take it. Whether it can on this Mac is the availability check's call, not this one's.
    public static func languageFor(_ lines: [String]) -> String? {
        let text = String(lines.joined(separator: " ").prefix(1000))
        let lang = detectLanguage(text)
        if lang == "zh" { return chineseScript(text) }
        let key = lang == "ru" || lang == "uk" ? cyrillicLanguage(text) ?? lang : lang
        return appleKeys.contains(key) ? key : nil
    }

    /// The name of a language key, as the install prompt and the settings status line say it.
    public static func displayName(_ key: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: key) ?? key
    }

    // MARK: Engine

    /// What Apple's Translation framework says about one language into English.
    public enum AppleStatus: String, Sendable { case installed, supported, unsupported }

    /// 'apple': translate now. 'needsInstall': Apple could translate this once the language
    /// is installed in macOS. 'none': nothing here can, so there is no button.
    public enum Engine: Equatable, Sendable { case apple, needsInstall, none }

    /// `enabled` is the lyricsTranslationEnabled setting; `status` is nil whenever the
    /// framework has not answered (or this macOS cannot ask).
    public static func pickEngine(enabled: Bool, status: AppleStatus?) -> Engine {
        guard enabled, let status else { return .none }
        switch status {
        case .installed: return .apple
        case .supported: return .needsInstall
        case .unsupported: return .none
        }
    }
}

/// The order a sheet is translated in, so a cold sheet shows the line being sung first
/// instead of all of it at the end (translateLines in renderer.js). Pure bookkeeping: the
/// engine and the cache are the caller's. Identical lines are asked once, since a lyric sheet
/// is mostly chorus; blank lines stay blank.
public struct TranslationPlan: Sendable {
    public let lines: [String]
    /// Trimmed line text to the indexes it appears at, for lines not yet translated.
    private var pending: [String: [Int]] = [:]
    public private(set) var total = 0
    public private(set) var done = 0

    public init(lines: [String]) {
        self.lines = lines
        for (i, line) in lines.enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            pending[text, default: []].append(i)
        }
        total = pending.count
    }

    public var isFinished: Bool { pending.isEmpty }
    /// Every distinct line still waiting.
    public var pendingTexts: [String] { Array(pending.keys) }

    /// Records a translation for `text`; returns the line indexes it fills.
    @discardableResult
    public mutating func land(_ text: String) -> [Int] {
        guard let indexes = pending.removeValue(forKey: text) else { return [] }
        done += 1
        return indexes
    }

    /// The first line still waiting at or after `playhead` (the line being sung), else the
    /// first before it. Asked again after every line, so a seek re-aims it.
    public func next(from playhead: Int) -> String? {
        guard !lines.isEmpty, !pending.isEmpty else { return nil }
        let start = max(0, min(lines.count - 1, playhead))
        for n in 0..<lines.count {
            let text = lines[(start + n) % lines.count].trimmingCharacters(in: .whitespaces)
            if pending[text] != nil { return text }
        }
        return nil
    }
}
