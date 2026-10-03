import Foundation
import Testing
@testable import CascadeKit

struct LyricTranslationTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func detectsTheLanguagesTheDesktopTranslates() {
        #expect(LyricTranslation.detectLanguage(of: ["\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{3001}\u{4E16}\u{754C}", "\u{79C1}\u{306F}\u{97F3}\u{697D}\u{304C}\u{597D}\u{304D}\u{3067}\u{3059}"]) == "ja")
        #expect(LyricTranslation.detectLanguage(of: ["\u{C548}\u{B155}\u{D558}\u{C138}\u{C694} \u{C138}\u{ACC4}", "\u{C800}\u{B294} \u{C74C}\u{C545}\u{C744} \u{C88B}\u{C544}\u{D574}\u{C694}"]) == "ko")
        #expect(LyricTranslation.detectLanguage(of: ["Hola mundo, \u{BF}c\u{F3}mo est\u{E1}s hoy?", "Me gusta mucho la m\u{FA}sica de esta ciudad"]) == "es")
        #expect(LyricTranslation.detectLanguage(of: ["Hello world, how are you doing today?", "I really like the music of this city"]) == "en")
    }

    @Test func doesNotGuessFromAFewLetters() {
        #expect(LyricTranslation.detectLanguage(of: []) == nil)
        #expect(LyricTranslation.detectLanguage(of: ["", "  "]) == nil)
        #expect(LyricTranslation.detectLanguage(of: ["la la la"]) == nil)
    }

    @Test func chineseScriptsAreToldApart() {
        #expect(LyricTranslation.sameLanguage("zh-Hans", "zh-Hans"))
        #expect(!LyricTranslation.sameLanguage("zh-Hans", "zh-Hant"))
        #expect(LyricTranslation.sameLanguage("zh", "zh-Hant"))
        #expect(LyricTranslation.sameLanguage("en", "en-US"))
        #expect(LyricTranslation.sameLanguage("EN_gb", "en"))
        #expect(!LyricTranslation.sameLanguage("es", "en"))
        #expect(!LyricTranslation.sameLanguage("", "en"))
    }

    @Test func offersATranslationOnlyForAKnownOtherLanguage() {
        #expect(LyricTranslation.needsTranslation(from: "ja", to: "en"))
        #expect(!LyricTranslation.needsTranslation(from: "en", to: "en-US"))
        #expect(!LyricTranslation.needsTranslation(from: nil, to: "en"))
    }

    @Test func translatesFromTheCurrentLineOnwardThenBack() {
        #expect(LyricTranslation.order(count: 5, from: 2) == [2, 3, 4, 0, 1])
        #expect(LyricTranslation.order(count: 3, from: nil) == [0, 1, 2])
        #expect(LyricTranslation.order(count: 3, from: 0) == [0, 1, 2])
        #expect(LyricTranslation.order(count: 3, from: 2) == [2, 0, 1])
        #expect(LyricTranslation.order(count: 3, from: 99) == [2, 0, 1])
        #expect(LyricTranslation.order(count: 3, from: -4) == [0, 1, 2])
        #expect(LyricTranslation.order(count: 0, from: 1) == [])
    }

    @Test func anEntryLastsTwentyFiveDaysFromWhenItWasMade() {
        var cache = TranslationCache()
        let key = LyricTranslation.cacheKey(source: "ja", target: "en", line: "a")
        cache.set("A", for: key, now: now.addingTimeInterval(-24 * day))
        #expect(cache.translation(for: key, now: now) == "A")
        #expect(cache.translation(for: key, now: now.addingTimeInterval(day)) == nil, "25 days on, it is gone")
        #expect(!TranslationCache.isLive(now.addingTimeInterval(day), now: now), "from the future: the clock was wrong")
        #expect(TranslationCache.isLive(now.addingTimeInterval(30), now: now), "a few seconds of skew is fine")
    }

    @Test func theKeyKeepsLanguagesApart() {
        var cache = TranslationCache()
        cache.set("hello", for: LyricTranslation.cacheKey(source: "ja", target: "en", line: "x"), now: now)
        #expect(cache.translation(for: LyricTranslation.cacheKey(source: "ja", target: "es", line: "x"), now: now) == nil)
        #expect(cache.translation(for: LyricTranslation.cacheKey(source: "JA", target: "EN", line: "x"), now: now) == "hello")
    }

    @Test func settingAgainReplacesAndTheNewestSurviveTheCap() {
        var cache = TranslationCache()
        cache.set("one", for: "k", now: now)
        cache.set("two", for: "k", now: now)
        #expect(cache.entries.count == 1)
        #expect(cache.translation(for: "k", now: now) == "two")
        for i in 0..<(LyricTranslation.cacheMax + 3) { cache.set("t", for: "key\(i)", now: now) }
        #expect(cache.entries.count == LyricTranslation.cacheMax)
        #expect(cache.translation(for: "key0", now: now) == nil)
        #expect(cache.translation(for: "key\(LyricTranslation.cacheMax + 2)", now: now) == "t")
    }

    @Test func aStoredCacheIsCleanedWhenRead() throws {
        var cache = TranslationCache()
        cache.set("old", for: "old", now: now.addingTimeInterval(-30 * day))
        cache.set("fresh", for: "fresh", now: now.addingTimeInterval(-day))
        let back = TranslationCache.decode(cache.encoded(), now: now)
        #expect(back.entries.map(\.key) == ["fresh"])
        #expect(back.translation(for: "fresh", now: now) == "fresh")
        #expect(TranslationCache.decode(Data("not json".utf8), now: now) == TranslationCache())
        #expect(TranslationCache.decode(nil, now: now) == TranslationCache())
    }

    @Test func emptyAndHugeValuesAreNotKept() {
        var cache = TranslationCache()
        cache.set("x", for: "", now: now)
        cache.set(String(repeating: "x", count: 5000), for: "big", now: now)
        #expect(cache.entries.isEmpty)
    }
}
