import Foundation
import Observation
import CascadeKit

/// The lyric settings the desktop keeps in its store, under the desktop's key names so the
/// settings import is a straight copy: the source pill's forced choice, the two translation
/// switches (whether translation exists at all, and whether translations are showing now,
/// kept apart as on the desktop) and whether the one-time plugin notice was accepted.
/// Shared and long-lived, like StyleTuning: the lyrics views, the Settings pane and the pill
/// all read the one copy.
@MainActor
@Observable
final class LyricsPrefs {
    static let shared = LyricsPrefs()

    /// 'auto' unless the user picked a source in the pill. A stale or unknown value reads as Auto.
    var forcedSource: LyricsSourceChoice {
        didSet { UserDefaults.standard.set(forcedSource.rawValue, forKey: "cascade.lyricsForcedSource") }
    }

    /// Whether translation exists at all (Settings, the first-run wizard). On unless turned off.
    var translationEnabled: Bool {
        didSet { UserDefaults.standard.set(translationEnabled, forKey: "cascade.lyricsTranslationEnabled") }
    }

    /// Whether translations are showing right now. Off until the Translate button is pressed.
    var translateOn: Bool {
        didSet { UserDefaults.standard.set(translateOn, forKey: "cascade.lyricsTranslateOn") }
    }

    /// The one-time "this needs the Cascade Server plugin" notice was accepted.
    var pluginNoticeSeen: Bool {
        didSet { UserDefaults.standard.set(pluginNoticeSeen, forKey: "cascade.cascadePluginNoticeSeen") }
    }

    private init() {
        let d = UserDefaults.standard
        forcedSource = LyricsSourceChoice(stored: d.string(forKey: "cascade.lyricsForcedSource"))
        translationEnabled = d.object(forKey: "cascade.lyricsTranslationEnabled") as? Bool ?? true
        translateOn = d.bool(forKey: "cascade.lyricsTranslateOn")
        pluginNoticeSeen = d.bool(forKey: "cascade.cascadePluginNoticeSeen")
    }
}
