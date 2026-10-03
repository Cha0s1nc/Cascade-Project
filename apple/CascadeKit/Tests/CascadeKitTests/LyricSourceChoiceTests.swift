import Foundation
import Testing
@testable import CascadeKit

// The source pill's forced-source choice (renderer.js lyricsForcedSource,
// VALID_LYRICS_SOURCES and _applyServerOnlyMode).
@Suite struct LyricSourceChoiceTests {
    @Test func aStoredValueThatIsNotAChoiceReadsAsAuto() {
        #expect(LyricsSourceChoice(stored: "Kugou") == .kugou)
        #expect(LyricsSourceChoice(stored: "cascade-karaoke") == .cascadeKaraoke)
        #expect(LyricsSourceChoice(stored: "cascade-synced") == .cascadeSynced)
        for junk in [nil, "", "kugou", "Spicy", "stale-id"] { #expect(LyricsSourceChoice(stored: junk) == .auto, "\(junk ?? "nil")") }
    }

    @Test func eachModeListsItsOwnChoices() {
        #expect(LyricsSourceChoice.choices(serverOnly: false) == [.auto, .kugou, .lrclib, .jellyfin])
        #expect(LyricsSourceChoice.choices(serverOnly: true) == [.auto, .cascadeKaraoke, .cascadeSynced])
        #expect(LyricsSourceChoice.kugou.isValid(serverOnly: false) && !LyricsSourceChoice.kugou.isValid(serverOnly: true))
        #expect(LyricsSourceChoice.cascadeSynced.isValid(serverOnly: true) && !LyricsSourceChoice.cascadeSynced.isValid(serverOnly: false))
        #expect(LyricsSourceChoice.auto.isValid(serverOnly: true) && LyricsSourceChoice.auto.isValid(serverOnly: false))
    }

    @Test func theLabelsMatchThePillAndTheMenu() {
        #expect(LyricsSourceChoice.auto.label == "Auto")
        #expect(LyricsSourceChoice.cascadeKaraoke.label == "Karaoke" && LyricsSourceChoice.cascadeKaraoke.menuLabel == "Karaoke Only")
        #expect(LyricsSourceChoice.cascadeSynced.label == "Synced" && LyricsSourceChoice.cascadeSynced.menuLabel == "Synced Only")
        #expect(LyricsSourceChoice.lrclib.label == "LRCLIB" && LyricsSourceChoice.lrclib.menuLabel == "LRCLIB")
    }

    @Test func statusBadgesAreKeyedBySourceAndServerChoicesShareOne() {
        #expect(LyricsSourceChoice.auto.statusKey == nil)
        #expect(LyricsSourceChoice.jellyfin.statusKey == "Jellyfin")
        #expect(LyricsSourceChoice.cascadeKaraoke.statusKey == "Cascade" && LyricsSourceChoice.cascadeSynced.statusKey == "Cascade")
    }

    @Test func theForcedChoiceNamesThePluginTypeItMustAnswerWith() {
        #expect(LyricsSourceChoice.cascadeKaraoke.pluginType == "karaoke")
        #expect(LyricsSourceChoice.cascadeSynced.pluginType == "synced")
        #expect(LyricsSourceChoice.auto.pluginType == nil && LyricsSourceChoice.kugou.pluginType == nil)
    }

    @Test func theAutoHintFollowsTheMode() {
        #expect(LyricsSourceChoice.autoHint(serverOnly: true).contains("karaoke"))
        #expect(LyricsSourceChoice.autoHint(serverOnly: false).contains("Kugou"))
    }
}
