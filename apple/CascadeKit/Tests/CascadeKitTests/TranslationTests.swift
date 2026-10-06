import Foundation
import Testing
@testable import CascadeKit

// Ported from test/language.test.ts, test/translation-models.test.ts and
// test/translation-cache.test.ts. The fixtures are Article 1 of the Universal Declaration of
// Human Rights, which the UN publishes in 500+ languages and places in the public domain:
// real song lyrics would be the obvious thing to test with and the wrong thing to commit.
// Detection runs on NaturalLanguage here, where the desktop uses franc.
private let udhr: [String: String] = [
    "en": "All human beings are born free and equal in dignity and rights. They are endowed with reason and conscience and should act towards one another in a spirit of brotherhood.",
    "es": "Todos los seres humanos nacen libres e iguales en dignidad y derechos y, dotados como estan de razon y conciencia, deben comportarse fraternalmente los unos con los otros.",
    "fr": "Tous les etres humains naissent libres et egaux en dignite et en droits. Ils sont doues de raison et de conscience et doivent agir les uns envers les autres dans un esprit de fraternite.",
    "de": "Alle Menschen sind frei und gleich an Wuerde und Rechten geboren. Sie sind mit Vernunft und Gewissen begabt und sollen einander im Geiste der Brueberlichkeit begegnen.",
    "pt": "Todos os seres humanos nascem livres e iguais em dignidade e em direitos. Dotados de razao e de consciencia, devem agir uns para com os outros em espirito de fraternidade.",
    "it": "Tutti gli esseri umani nascono liberi ed eguali in dignita e diritti. Essi sono dotati di ragione e di coscienza e devono agire gli uni verso gli altri in spirito di fratellanza.",
    "ru": "Все люди рождаются свободными и равными в своем достоинстве и правах. Они наделены разумом и совестью и должны поступать в отношении друг друга в духе братства.",
    "uk": "Всі люди народжуються вільними і рівними у своїй гідності та правах. Вони наділені розумом і совістю і повинні діяти у відношенні один до одного в дусі братерства.",
    "ja": "すべての人間は、生まれながらにして自由であり、かつ、尊厳と権利とについて平等である。人間は、理性と良心とを授けられており、互いに同胞の精神をもって行動しなければならない。",
    "ko": "모든 사람은 태어날 때부터 자유로우며 그 존엄과 권리에 있어 동등하다. 사람은 천부적으로 이성과 양심을 부여받았으며 서로 형제애의 정신으로 행동하여야 한다.",
    "zhHans": "人人生而自由，在尊严和权利上一律平等。他们赋有理性和良心，并应以兄弟关系的精神相对待。",
    "zhHant": "人人生而自由，在尊嚴和權利上一律平等。他們賦有理性和良心，並應以兄弟關係的精神相對待。",
    "th": "มนุษย์ทั้งหลายเกิดมามีอิสระและเสมอภาคกันในเกียรติศักดิ์และสิทธิ ต่างมีเหตุผลและมโนธรรม และควรปฏิบัติต่อกันด้วยเจตนารมณ์แห่งภราดรภาพ",
    "hi": "सभी मनुष्यों को गौरव और अधिकारों के मामले में जन्मजात स्वतन्त्रता और समानता प्राप्त है। उन्हें बुद्धि और अन्तरात्मा की देन प्राप्त है और परस्पर उन्हें भाईचारे के भाव से बर्ताव करना चाहिए।",
]

@Suite struct LanguageDetectionTests {
    @Test func detectsTheLanguageOfEachTranslation() {
        for code in ["en", "es", "fr", "de", "pt", "it", "ru", "ja"] {
            #expect(LyricTranslation.detectLanguage(udhr[code]!) == code, "expected \(code)")
        }
        // Either Chinese script is "zh" here; chineseScript settles which.
        #expect(LyricTranslation.detectLanguage(udhr["zhHans"]!) == "zh")
        #expect(LyricTranslation.detectLanguage(udhr["zhHant"]!) == "zh")
    }

    @Test func returnsEmptyRatherThanGuessingOnThinInput() {
        // "" means "no idea", never "English".
        #expect(LyricTranslation.detectLanguage("") == "")
        #expect(LyricTranslation.detectLanguage("Oh") == "")
        #expect(LyricTranslation.detectLanguage("   \n  \t ") == "")
        #expect(LyricTranslation.detectLanguage("La la la") == "")
        // Padding is not signal.
        #expect(LyricTranslation.detectLanguage("a\n\n   \t  b") == "")
    }

    @Test func offersTranslationForNonEnglishLyricsOnly() {
        #expect(LyricTranslation.shouldOffer([udhr["es"]!]))
        #expect(LyricTranslation.shouldOffer([udhr["ja"]!]))
        #expect(!LyricTranslation.shouldOffer([udhr["en"]!]))
    }

    @Test func neverOffersTranslationWithNothingToGoOn() {
        #expect(!LyricTranslation.shouldOffer([]))
        #expect(!LyricTranslation.shouldOffer(["", "", ""]))
        #expect(!LyricTranslation.shouldOffer(["Ooh", "Ahh"]))
    }

    @Test func judgesTheWholeSheetNotTheFirstLine() {
        // A Spanish song whose first line is its English title was once detected as English.
        let lines = ["Bailando"] + udhr["es"]!.components(separatedBy: ". ")
        #expect(LyricTranslation.shouldOffer(lines))
    }
}

@Suite struct TranslationLanguageTests {
    @Test func namesTheLanguageForTheFiveThatHadModelsOnDesktop() {
        #expect(LyricTranslation.languageFor([udhr["ja"]!]) == "ja")
        #expect(LyricTranslation.languageFor([udhr["ko"]!]) == "ko")
        #expect(LyricTranslation.languageFor([udhr["zhHans"]!]) == "zh-Hans")
        #expect(LyricTranslation.languageFor([udhr["zhHant"]!]) == "zh-Hant")
        #expect(LyricTranslation.languageFor([udhr["es"]!]) == "es")
    }

    @Test func namesTheOtherLanguagesAppleTakes() {
        for code in ["fr", "de", "pt", "th", "hi", "ru", "uk"] {
            #expect(LyricTranslation.languageFor([udhr[code]!]) == code, "expected \(code)")
        }
    }

    @Test func offersNothingForEnglishOrTextTooThinToJudge() {
        #expect(LyricTranslation.languageFor([udhr["en"]!]) == nil)
        #expect(LyricTranslation.languageFor([]) == nil)
        #expect(LyricTranslation.languageFor(["Ooh", "Ahh"]) == nil)
    }

    @Test func readsTheWholeSheetNotTheFirstLine() {
        #expect(LyricTranslation.languageFor(["Idol", udhr["ja"]!]) == "ja")
    }

    @Test func cyrillicTellsRussianFromUkrainianByTheirOwnLetters() {
        // A short Russian line that trigram matching called Ukrainian.
        #expect(LyricTranslation.languageFor(["Я люблю гулять под дождём, когда улицы пустые вечером"]) == "ru")
        #expect(LyricTranslation.cyrillicLanguage("Їжак їсть яблука") == "uk")
        #expect(LyricTranslation.cyrillicLanguage("Съешь ещё этих мягких булок") == "ru")
        #expect(LyricTranslation.cyrillicLanguage("Мама мыла раму") == "ru")
        #expect(LyricTranslation.cyrillicLanguage("Мама") == nil)
    }

    @Test func chineseScriptFollowsTheMajoritySpellingTiesToSimplified() {
        #expect(LyricTranslation.chineseScript("我们这个") == "zh-Hans")
        #expect(LyricTranslation.chineseScript("我們這個") == "zh-Hant")
        #expect(LyricTranslation.chineseScript("人人生而自由") == "zh-Hans")
        #expect(LyricTranslation.chineseScript("们們") == "zh-Hans")
    }

    @Test func theScriptTablesStayAlignedPairForPair() {
        let s = LyricTranslation.simplified, t = LyricTranslation.traditional
        #expect(s.count == t.count)
        for (i, c) in s.enumerated() { #expect(c != t[i], "pair \(i) is the same character: \(c)") }
        #expect(Set(s).count == s.count)
        #expect(Set(t).count == t.count)
        // No character in both tables, or it would count for both sides.
        #expect(Set(s).intersection(Set(t)).isEmpty)
    }

    @Test func theEngineIsAppleOrNothing() {
        #expect(LyricTranslation.pickEngine(enabled: true, status: .installed) == .apple)
        #expect(LyricTranslation.pickEngine(enabled: true, status: .supported) == .needsInstall)
        #expect(LyricTranslation.pickEngine(enabled: true, status: .unsupported) == .none)
        #expect(LyricTranslation.pickEngine(enabled: true, status: nil) == .none)
        #expect(LyricTranslation.pickEngine(enabled: false, status: .installed) == .none)
    }

    @Test func everyLanguageThatHadADesktopModelIsOneAppleIsAskedAbout() {
        for key in ["ja", "ko", "zh-Hans", "zh-Hant", "es"] { #expect(LyricTranslation.appleKeys.contains(key)) }
    }
}

@Suite struct TranslationPlanTests {
    @Test func startsAtTheLineBeingSungThenWrapsToTheOnesBefore() {
        var plan = TranslationPlan(lines: ["a", "b", "c", "d"])
        #expect(plan.next(from: 2) == "c")
        plan.land("c")
        #expect(plan.next(from: 2) == "d")
        plan.land("d")
        #expect(plan.next(from: 2) == "a")
        plan.land("a")
        #expect(plan.next(from: 2) == "b")
        plan.land("b")
        #expect(plan.isFinished && plan.next(from: 0) == nil)
    }

    @Test func aSeekReAimsIt() {
        var plan = TranslationPlan(lines: ["a", "b", "c", "d"])
        plan.land("a")
        #expect(plan.next(from: 3) == "d")
        #expect(plan.next(from: 1) == "b")
    }

    @Test func repeatedLinesAreAskedOnceAndFillEveryPlace() {
        var plan = TranslationPlan(lines: ["la", "verse", "la", "  la  ", ""])
        #expect(plan.total == 2)
        #expect(plan.land("la") == [0, 2, 3])
        #expect(plan.land("la") == [])
        #expect(plan.done == 1 && !plan.isFinished)
    }

    @Test func blankLinesAreNeverAsked() {
        let plan = TranslationPlan(lines: ["", "  ", ""])
        #expect(plan.isFinished && plan.total == 0 && plan.next(from: 0) == nil)
    }

    @Test func aPlayheadOutOfRangeIsClamped() {
        let plan = TranslationPlan(lines: ["a", "b"])
        #expect(plan.next(from: 99) == "b")
        #expect(plan.next(from: -5) == "a")
    }
}

@Suite struct TranslationCacheTests {
    private let now = 1_800_000_000_000.0
    private let day = 24.0 * 60 * 60 * 1000

    @Test func anEntryLastsTwentyFiveDaysFromWhenItWasTranslated() {
        #expect(!TranslationCache.expired(at: now - 24 * day, now: now))
        #expect(TranslationCache.expired(at: now - TranslationCache.ttlMs, now: now))
        // From the future: the clock was wrong, do not trust it.
        #expect(TranslationCache.expired(at: now + day, now: now))
    }

    @Test func loadedEntriesDropMalformedAndExpiredOnesKeepingOrder() {
        let raw: [Any] = [
            ["apple|ja|a", "A", now - 30 * day],
            ["apple|ja|b", "B", now - day],
            "junk", ["x"], ["", "empty key", now], ["k", 5, now], ["k", "nan", Double.nan],
            ["apple|ko|c", "C", now],
        ]
        let live = TranslationCache.liveEntries(raw, now: now)
        #expect(live.map(\.key) == ["apple|ja|b", "apple|ko|c"])
        #expect(live.map(\.text) == ["B", "C"])
    }

    @Test func loadedEntriesAreCappedToTheNewestAndNonArraysAreEmpty() {
        let raw: [Any] = [1, 2, 3].map { ["k\($0)", "t\($0)", now] as [Any] }
        #expect(TranslationCache.liveEntries(raw, now: now, max: 2).map(\.key) == ["k2", "k3"])
        for junk in [NSNull(), [String: Any](), "x", 42] as [Any] { #expect(TranslationCache.liveEntries(junk, now: now).isEmpty) }
    }

    @Test func aLookupReturnsWhatWasStoredAndNeverExtendsIt() {
        var cache = TranslationCache()
        cache.store("apple|ja|a", "A", now: now - 24 * day)
        #expect(cache.lookup("apple|ja|a", now: now) == "A")
        // Reading did not refresh the stamp: a day later it is past 25 days.
        #expect(cache.lookup("apple|ja|a", now: now + 2 * day) == nil)
        #expect(cache.count == 0)
        #expect(cache.lookup("never", now: now) == nil)
    }

    @Test func theLeastRecentlyUsedGoesFirstWhenFull() {
        var cache = TranslationCache()
        for i in 1...3 { cache.store("k\(i)", "t\(i)", now: now, max: 3) }
        _ = cache.lookup("k1", now: now)   // k2 is now the oldest
        cache.store("k4", "t4", now: now, max: 3)
        #expect(cache.lookup("k2", now: now) == nil)
        #expect(cache.lookup("k1", now: now) == "t1" && cache.lookup("k4", now: now) == "t4")
    }

    @Test func theFileRoundTripsAndKeepsTheOrder() throws {
        var cache = TranslationCache()
        cache.store("apple|ja|a", "A", now: now - 2 * day)
        cache.store("apple|ja|b", "B", now: now - day)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)/translation-cache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try cache.save(to: url, now: now)
        var back = TranslationCache.load(from: url, now: now)
        #expect(back.count == 2 && !back.isDirty)
        #expect(back.lookup("apple|ja|a", now: now) == "A")
        // The desktop's shape: [[key, text, at]], oldest first.
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[Any]])
        #expect(raw.map { $0[0] as? String } == ["apple|ja|a", "apple|ja|b"])
    }

    @Test func anExpiredLineLeavesTheDiskToo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let raw: [Any] = [["apple|ja|old", "O", now - 30 * day], ["apple|ja|new", "N", now]]
        try JSONSerialization.data(withJSONObject: raw).write(to: url)
        let cache = TranslationCache.load(from: url, now: now)
        #expect(cache.count == 1 && cache.isDirty)
        // A missing or corrupt file is an empty cache, not a crash.
        #expect(TranslationCache.load(from: url.appendingPathExtension("missing")).count == 0)
        try Data("not json".utf8).write(to: url)
        #expect(TranslationCache.load(from: url).count == 0)
    }
}
