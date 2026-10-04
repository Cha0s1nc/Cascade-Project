import Foundation
import Testing
@testable import CascadeKit

/// Fixture files only. Nothing here reads or writes the installed app's real
/// config.json: every path is in a scratch directory.
@Suite struct ElectronSettingsImportTests {
    typealias I = ElectronSettingsImport

    /// Shaped like electron-store's file as renderer.js writes it: some values
    /// native, some stringified JSON, Discord's switch the text 'true'. The
    /// token and ids are invented.
    static let fixture = #"""
    {
      "betaUpdates": true,
      "browseMode": "video",
      "cascadePluginNoticeSeen": true,
      "collapsedLibs": "[\"lib-movies\"]",
      "crossfadeEnabled": true,
      "crossfadeSeconds": 8,
      "deviceId": "6f1c2d3e-aaaa-bbbb-cccc-0123456789ab",
      "deviceIdMigrated": true,
      "discordClientId": "1512373702522835004",
      "discordRpcEnabled": "true",
      "eqEnabled": true,
      "eqMusic": "{\"enabled\":true,\"preamp\":null,\"bands\":[7,4,0,-1,-1]}",
      "eqVideo": "{\"enabled\":false,\"preamp\":-3,\"bands\":[0,0,4,3,20]}",
      "firstRunWizardSeen": true,
      "lastQueue": "{\"ids\":[\"a\",\"b\"],\"index\":1,\"positionSec\":42}",
      "libraryId": "legacy-single",
      "libraryIds": "[\"lib-music\",\"lib-more\"]",
      "lyricStyle": "{\"currentLinePosition\":0.4}",
      "lyricsForcedSource": "LRCLIB",
      "lyricsTranslateOn": true,
      "miniplayerHeight": 320,
      "movieLibraryIds": "[\"lib-movies\"]",
      "normalizationEnabled": true,
      "normalizationSource": "album",
      "npTuning": "{\"lyricScale\":1.1,\"bgDim\":0.4,\"bgBlend\":true}",
      "outputDeviceId": "a3f9chromiumhash",
      "albumsPrefs": "{\"sort\":\"added\",\"dir\":\"desc\"}",
      "maxStreamingBitrate": 192000,
      "serverOnlyMode": true,
      "serverUrl": "https://jellyfin.example.com/",
      "showLibraryIds": "[]",
      "singleLibraryMode": false,
      "smartPlaylists": "[{\"id\":\"user:1\",\"name\":\"Fresh\",\"match\":\"all\",\"rules\":[{\"field\":\"genre\",\"op\":\"isNot\",\"value\":\"Pop\"},{\"field\":\"year\",\"op\":\"between\",\"min\":1990,\"max\":2000},{\"field\":\"favorite\",\"op\":\"is\",\"value\":true}],\"sortBy\":\"dateAdded\",\"sortDir\":\"desc\",\"limit\":50}]",
      "songsSortDir": "desc",
      "songsSortField": "played",
      "spotifyLinks": "{\"item1\":\"https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=x\"}",
      "theme": "{\"mode\":\"light\",\"gradStart\":\"#112233\",\"gradEnd\":\"#445566\",\"albumArt\":true}",
      "token": "0123456789abcdef0123456789abcdef",
      "uiFont": "{\"preset\":\"serif\",\"custom\":\"\"}",
      "undecodableAudioCodecs": "[\"dts\"]",
      "userId": "user-1",
      "username": "chaos",
      "videoFullMode": true,
      "videoIntroSeen": true,
      "volume": 0.65,
      "waterfallAllowGuestControl": true,
      "waterfallRelay": "https://relay.example.com/",
      "windowState": {"x": 10, "y": 20, "width": 1100, "height": 700, "maximized": false},
      "wizardSeenRevision": 3,
      "appleTranslationMozillaChosen": ["ja"],
      "appleTranslationEnabled": true,
      "uiScaleFromTheFuture": "kept"
    }
    """#

    static func config(_ json: String = fixture) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cascade-import-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Electron to native

    @Test func mapsTheFixtureOntoNativeKeys() throws {
        let r = I.map(try Self.config())
        let v = r.values
        #expect(r.token == "0123456789abcdef0123456789abcdef")
        #expect(r.rejected.isEmpty, "\(r.rejected)")
        #expect(v["cascade.serverUrl"] as? String == "https://jellyfin.example.com")
        #expect(v["cascade.username"] as? String == "chaos")
        #expect(v["cascade.userId"] as? String == "user-1")
        // Kept, so the server sees the same device.
        #expect(v["cascade.deviceId"] as? String == "6f1c2d3e-aaaa-bbbb-cccc-0123456789ab")
        #expect(v["cascade.libraryIds"] as? [String] == ["lib-music", "lib-more"])
        #expect(v["cascade.movieLibraryIds"] as? [String] == ["lib-movies"])
        #expect(v["cascade.showLibraryIds"] as? [String] == [])
        #expect(v["cascade.collapsedLibs"] as? [String] == ["lib-movies"])
        #expect(v["cascade.singleLibraryMode"] as? Bool == false)
        #expect(v["cascade.browseMode"] as? String == "video")
        #expect(v["cascade.albumsPrefs"] as? String == #"{"sort":"added","dir":"desc"}"#)
        #expect(v["cascade.songs.sort"] as? String == "played")
        #expect(v["cascade.songs.order"] as? String == "descending")
        #expect(v["cascade.wizardSeenRevision"] as? Int == 3)
        #expect(v["cascade.firstRunWizardSeen"] as? Bool == true)
        #expect(v["cascade.videoIntroSeen"] as? Bool == true)
        #expect(v["cascade.cascadePluginNoticeSeen"] as? Bool == true)
        #expect(v["cascade.crossfadeSeconds"] as? Int == 8)
        #expect(v["cascade.streamingQuality"] as? Int == 192_000)
        #expect(v["cascade.normalization"] as? String == "album")
        #expect(v["cascade.volume"] as? Double == 0.65)
        #expect(v["cascade.serverOnlyLyrics"] as? Bool == true)
        #expect(v["cascade.lyricsForcedSource"] as? String == "LRCLIB")
        #expect(v["cascade.lyricsTranslateOn"] as? Bool == true)
        #expect(v["cascade.discordRpcEnabled"] as? Bool == true)
        #expect(v["cascade.discordClientId"] as? String == "1512373702522835004")
        #expect(v["cascade.wf.relay"] as? String == "https://relay.example.com")
        #expect(v["cascade.wf.guestControl"] as? Bool == true)
        #expect(v["cascade.miniplayerHeight"] as? Int == 320)
        #expect(v["cascade.theme"] as? String != nil)
        #expect(v["cascade.uiFont"] as? String != nil)
        #expect(v["cascade.npTuning"] as? String != nil)
        #expect(v["cascade.lyricStyle"] as? String != nil)
        #expect(v["cascade.lastQueue"] as? String != nil)
    }

    @Test func dropsWhatHasNoNativeMeaningAndNeverMapsTheToken() throws {
        let r = I.map(try Self.config())
        let all = Set(r.values.keys)
        for dropped in ["outputDeviceId", "undecodableAudioCodecs", "windowState", "appleTranslationMozillaChosen",
                        "appleTranslationEnabled", "libraryId", "password", "deviceIdMigrated", "macBuild", "betaUpdates",
                        "videoFullMode", "uiScaleFromTheFuture", "token"] {
            #expect(!all.contains("cascade.\(dropped)"), "\(dropped)")
        }
        // The token goes through `token` only, never into the defaults dictionary.
        #expect(!r.values.values.contains { ($0 as? String) == "0123456789abcdef0123456789abcdef" })
    }

    @Test func theEqualizerBecomesTwoNativeProfiles() throws {
        let v = I.map(try Self.config()).values
        let music = EQProfile.decode(v["cascade.eq"] as? Data)
        #expect(music.enabled)
        #expect(music.gains == [7, 4, 0, -1, -1])
        #expect(music.preamp == nil)
        let video = EQProfile.decode(v["cascade.eqVideo"] as? Data)
        // The profile's own switch was off in Electron.
        #expect(!video.enabled)
        // 20 dB is clamped to the 12 dB limit.
        #expect(video.gains == [0, 0, 4, 3, 12])
        #expect(video.preamp == -3)
    }

    @Test func aMasterSwitchOffMeansBothProfilesOff() throws {
        var c = try Self.config()
        c["eqEnabled"] = false
        let v = I.map(c).values
        #expect(!EQProfile.decode(v["cascade.eq"] as? Data).enabled)
    }

    @Test func crossfadeStreamingQualityAndNormalizationFoldIntoNativeShape() {
        func v(_ c: [String: Any]) -> [String: Any] { I.map(c).values }
        #expect(v(["crossfadeEnabled": false, "crossfadeSeconds": 8])["cascade.crossfadeSeconds"] as? Int == 0)
        #expect(v(["crossfadeEnabled": true])["cascade.crossfadeSeconds"] as? Int == 6)
        #expect(v(["crossfadeEnabled": true, "crossfadeSeconds": 99])["cascade.crossfadeSeconds"] as? Int == 6)
        #expect(v(["maxStreamingBitrate": 140_000_000])["cascade.streamingQuality"] as? Int == 0)
        #expect(v(["maxStreamingBitrate": 320_000])["cascade.streamingQuality"] as? Int == 320_000)
        #expect(v(["maxStreamingBitrate": 100_000])["cascade.streamingQuality"] as? Int == 128_000)
        #expect(v(["normalizationEnabled": false, "normalizationSource": "album"])["cascade.normalization"] as? String == "off")
        #expect(v(["normalizationEnabled": true])["cascade.normalization"] as? String == "track")
        // Every value the native side stores must be one it reads back.
        #expect(StreamingQuality(stored: v(["maxStreamingBitrate": 100_000])["cascade.streamingQuality"]) == .kbps128)
        #expect(Normalization.Mode(rawValue: v(["normalizationEnabled": true, "normalizationSource": "album"])["cascade.normalization"] as? String ?? "") == .album)
    }

    @Test func smartPlaylistsLoadThroughTheNativeModel() throws {
        let data = try #require(I.map(try Self.config()).values["cascade.smartPlaylists"] as? Data)
        let lists = SmartPlaylist.decodeList(data)
        #expect(lists.count == 1)
        #expect(lists[0].name == "Fresh")
        #expect(lists[0].rules == [.genre("Pop", isNot: true), .year(min: 1990, max: 2000), .favorite(true)])
        #expect(lists[0].sortBy == .dateAdded && lists[0].descending && lists[0].limit == 50)
    }

    @Test func spotifyLinksKeepOnlyRealTrackIds() throws {
        let v = I.map(try Self.config()).values
        #expect(v["cascade.spotifyLinks"] as? [String: String] == ["item1": "4uLU6hMCjMI75M1A2tKUQC"])
        let r = I.map(["spotifyLinks": #"{"a":"nonsense","b":"4uLU6hMCjMI75M1A2tKUQC"}"#]).values
        #expect(r["cascade.spotifyLinks"] as? [String: String] == ["b": "4uLU6hMCjMI75M1A2tKUQC"])
    }

    @Test func hostileAndMalformedValuesAreRejectedNotGuessed() {
        let bad: [String: Any] = [
            "serverUrl": "javascript:alert(1)", "username": String(repeating: "x", count: 300), "userId": "a b/c",
            "deviceId": "x", "libraryIds": "not json", "movieLibraryIds": ["ok", 5], "collapsedLibs": #"{"a":1}"#,
            "singleLibraryMode": "yes", "browseMode": "podcasts", "albumsPrefs": "[1,2]",
            "songsSortField": "random", "songsSortDir": "sideways", "wizardSeenRevision": -4, "volume": 3,
            "repeatMode": "twice", "lyricsForcedSource": "../etc", "discordClientId": "abc", "waterfallRelay": "ftp://x",
            "miniplayerHeight": 5, "token": "has space", "theme": "{", "eqMusic": "[]", "smartPlaylists": "{}",
            "spotifyLinks": "[]", "maxStreamingBitrate": -1, "lastQueue": "{",
        ]
        let r = I.map(bad)
        #expect(r.values.isEmpty, "\(r.values)")
        #expect(r.token == nil)
        #expect(Set(r.rejected) == Set(bad.keys))
    }

    @Test func discordSwitchReadsTheTextOrARealBool() {
        #expect(I.map(["discordRpcEnabled": "true"]).values["cascade.discordRpcEnabled"] as? Bool == true)
        #expect(I.map(["discordRpcEnabled": "false"]).values["cascade.discordRpcEnabled"] as? Bool == false)
        #expect(I.map(["discordRpcEnabled": true]).values["cascade.discordRpcEnabled"] as? Bool == true)
        // 1 is not a bool.
        #expect(I.map(["singleLibraryMode": 1]).values.isEmpty)
    }

    @Test func absentKeysChangeNothing() {
        let r = I.map([:])
        #expect(r.values.isEmpty && r.token == nil && r.rejected.isEmpty)
    }

    // MARK: Native to Electron

    /// What UserDefaults would hold after the import, as a lookup.
    private func nativeLookup(_ v: [String: Any]) -> (String) -> Any? { { v[$0] } }

    @Test func goingBackWritesEveryTableKeyBackTheWayElectronReadsIt() throws {
        let original = try Self.config()
        let imported = I.map(original)
        let back = I.export(nativeValue: nativeLookup(imported.values), token: imported.token, into: original)

        // Keys the table owns come back as Electron stores them.
        #expect(back["libraryIds"] as? String == #"["lib-music","lib-more"]"#)
        #expect(back["discordRpcEnabled"] as? String == "true")
        #expect(back["crossfadeEnabled"] as? Bool == true)
        #expect(back["crossfadeSeconds"] as? Int == 8)
        #expect(back["maxStreamingBitrate"] as? Int == 192_000)
        #expect(back["normalizationEnabled"] as? Bool == true)
        #expect(back["normalizationSource"] as? String == "album")
        #expect(back["songsSortDir"] as? String == "desc")
        #expect(back["serverUrl"] as? String == "https://jellyfin.example.com")
        #expect(back["waterfallRelay"] as? String == "https://relay.example.com")
        #expect(back["token"] as? String == "0123456789abcdef0123456789abcdef")
        #expect(back["deviceId"] as? String == "6f1c2d3e-aaaa-bbbb-cccc-0123456789ab")

        // Electron's equalizer shape, with `bands` and a per-profile switch.
        let music = try #require(try JSONSerialization.jsonObject(with: Data((back["eqMusic"] as? String ?? "").utf8)) as? [String: Any])
        #expect(music["enabled"] as? Bool == true)
        #expect((music["bands"] as? [Double]) == [7, 4, 0, -1, -1])
        #expect(music["preamp"] is NSNull)
        #expect(back["eqEnabled"] as? Bool == true)

        // Everything Electron-only, or from a newer Electron, is kept.
        #expect(back["windowState"] != nil)
        #expect(back["outputDeviceId"] as? String == "a3f9chromiumhash")
        #expect(back["uiScaleFromTheFuture"] as? String == "kept")
        #expect(back["betaUpdates"] as? Bool == true)
        #expect(back["undecodableAudioCodecs"] != nil)
        // A reinstalled Electron must stop offering the native build.
        #expect(back["macBuild"] as? String == "electron")
    }

    @Test func importThenExportThenImportIsStable() throws {
        let first = I.map(try Self.config())
        let back = I.export(nativeValue: nativeLookup(first.values), token: first.token, into: try Self.config())
        let second = I.map(back)
        #expect(second.token == first.token)
        #expect(second.rejected.isEmpty, "\(second.rejected)")
        for (key, value) in first.values {
            // JSONEncoder's key order varies between runs, so compare what the Data holds.
            if key.hasPrefix("cascade.eq") {
                #expect(EQProfile.decode(second.values[key] as? Data) == EQProfile.decode(value as? Data), "\(key)")
                continue
            }
            if key == "cascade.smartPlaylists" {
                #expect(SmartPlaylist.decodeList(second.values[key] as? Data) == SmartPlaylist.decodeList(value as? Data))
                continue
            }
            #expect((second.values[key] as? NSObject) == (value as? NSObject), "\(key): \(String(describing: second.values[key])) vs \(value)")
        }
        #expect(Set(second.values.keys) == Set(first.values.keys))
    }

    @Test func settingsChangedInNativeReachElectron() throws {
        var native = I.map(try Self.config()).values
        native["cascade.crossfadeSeconds"] = 0
        native["cascade.normalization"] = "off"
        native["cascade.streamingQuality"] = 0
        native["cascade.libraryIds"] = ["only-one"]
        native["cascade.eqVideo"] = EQProfile(enabled: true, preamp: nil, gains: [1, 2, 3, 4, 5]).encoded()
        native["cascade.discordRpcEnabled"] = false
        let back = I.export(nativeValue: nativeLookup(native), token: nil, into: try Self.config())
        #expect(back["crossfadeEnabled"] as? Bool == false)
        #expect(back["crossfadeSeconds"] as? Int == 8, "the length is left as it was while off")
        #expect(back["normalizationEnabled"] as? Bool == false)
        #expect(back["maxStreamingBitrate"] as? Int == 140_000_000)
        #expect(back["libraryIds"] as? String == #"["only-one"]"#)
        #expect(back["discordRpcEnabled"] as? String == "false")
        let video = try #require(try JSONSerialization.jsonObject(with: Data((back["eqVideo"] as? String ?? "").utf8)) as? [String: Any])
        #expect((video["bands"] as? [Double]) == [1, 2, 3, 4, 5])
        #expect(video["enabled"] as? Bool == true)
        #expect(back["eqEnabled"] as? Bool == true)
    }

    @Test func garbageInDefaultsNeverReachesTheElectronFile() throws {
        let native: [String: Any] = [
            "cascade.serverUrl": "file:///etc/passwd", "cascade.libraryIds": ["fine", "not fine!"], "cascade.crossfadeSeconds": 400,
            "cascade.streamingQuality": 12345, "cascade.normalization": "loud", "cascade.eq": Data("junk".utf8),
            "cascade.browseMode": "x", "cascade.volume": 9.0, "cascade.songs.order": "up",
        ]
        let original = try Self.config()
        let back = I.export(nativeValue: nativeLookup(native), token: nil, into: original)
        for key in ["serverUrl", "libraryIds", "crossfadeSeconds", "maxStreamingBitrate", "normalizationEnabled", "browseMode", "volume", "songsSortDir"] {
            #expect(NSDictionary(dictionary: back).value(forKey: key) as? NSObject == NSDictionary(dictionary: original).value(forKey: key) as? NSObject, "\(key) changed")
        }
    }

    @Test func aTokenWithJunkIsNotWritten() throws {
        let back = I.export(nativeValue: { _ in nil }, token: "bad token\n", into: ["token": "keep"])
        #expect(back["token"] as? String == "keep")
    }

    // MARK: Files

    @Test func readsAFixtureAndRefusesWhatIsNotASettingsFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data(Self.fixture.utf8).write(to: file)
        #expect(try I.read(file)["username"] as? String == "chaos")
        try Data("[1,2]".utf8).write(to: file)
        #expect(throws: I.FileError.notAnObject) { try I.read(file) }
        try Data("{ broken".utf8).write(to: file)
        #expect(throws: I.FileError.notAnObject) { try I.read(file) }
        #expect(throws: I.FileError.unreadable) { try I.read(dir.appending(path: "missing.json")) }
        try Data(repeating: 0x20, count: I.maxFileBytes + 1).write(to: file)
        #expect(throws: I.FileError.tooLarge) { try I.read(file) }
    }

    @Test func writeBackKeepsAOneTimeBackupAndNeverDeletes() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data(Self.fixture.utf8).write(to: file)
        var config = try I.read(file)
        config["username"] = "changed"
        try I.write(config, to: file)
        #expect(try I.read(file)["username"] as? String == "changed")
        let backup = URL(fileURLWithPath: file.path + I.backupSuffix)
        #expect(try I.read(backup)["username"] as? String == "chaos")
        // A second write does not overwrite the first backup.
        config["username"] = "again"
        try I.write(config, to: file)
        #expect(try I.read(backup)["username"] as? String == "chaos")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: First launch

    private func suite() -> (UserDefaults, () -> Void) {
        let name = "cascade-import-test-\(UUID().uuidString.prefix(8))"
        let d = UserDefaults(suiteName: name)!
        return (d, { d.removePersistentDomain(forName: name) })
    }

    @Test func runsOnceAndNeverAgain() throws {
        let dir = try scratch()
        let (defaults, cleanup) = suite()
        defer { try? FileManager.default.removeItem(at: dir); cleanup() }
        let file = dir.appending(path: "config.json")

        // No file yet: nothing done, and not marked done either.
        #expect(I.runOnce(configURL: file, defaults: defaults, saveToken: { _ in }) == .noFile)
        #expect(!defaults.bool(forKey: I.doneKey))

        try Data(Self.fixture.utf8).write(to: file)
        var saved: String?
        let outcome = I.runOnce(configURL: file, defaults: defaults, saveToken: { saved = $0 })
        guard case .imported(let applied, let rejected) = outcome else { Issue.record("\(outcome)"); return }
        #expect(applied > 20 && rejected.isEmpty)
        #expect(saved == "0123456789abcdef0123456789abcdef")
        #expect(defaults.string(forKey: "cascade.serverUrl") == "https://jellyfin.example.com")
        #expect(defaults.stringArray(forKey: "cascade.libraryIds") == ["lib-music", "lib-more"])
        #expect(defaults.string(forKey: "cascade.deviceId") == "6f1c2d3e-aaaa-bbbb-cccc-0123456789ab")
        #expect(defaults.bool(forKey: I.doneKey))

        // Changed natively afterwards: a second launch must not bring the old value back.
        defaults.set("https://elsewhere.example.com", forKey: "cascade.serverUrl")
        #expect(I.runOnce(configURL: file, defaults: defaults, saveToken: { _ in Issue.record("token saved twice") }) == .skipped)
        #expect(defaults.string(forKey: "cascade.serverUrl") == "https://elsewhere.example.com")
        // And the Electron file is untouched.
        #expect(try I.read(file)["username"] as? String == "chaos")
    }

    @Test func neverReplacesAnExistingNativeSession() throws {
        let dir = try scratch()
        let (defaults, cleanup) = suite()
        defer { try? FileManager.default.removeItem(at: dir); cleanup() }
        let file = dir.appending(path: "config.json")
        try Data(Self.fixture.utf8).write(to: file)
        defaults.set("https://mine.example.com", forKey: "cascade.serverUrl")
        defaults.set("me", forKey: "cascade.userId")
        #expect(I.runOnce(configURL: file, defaults: defaults, saveToken: { _ in Issue.record("token saved") }) == .skipped)
        #expect(defaults.string(forKey: "cascade.serverUrl") == "https://mine.example.com")
        #expect(defaults.bool(forKey: I.doneKey))
    }

    @Test func anUnreadableFileIsReportedAndRetriedLater() throws {
        let dir = try scratch()
        let (defaults, cleanup) = suite()
        defer { try? FileManager.default.removeItem(at: dir); cleanup() }
        let file = dir.appending(path: "config.json")
        try Data("{ broken".utf8).write(to: file)
        #expect(I.runOnce(configURL: file, defaults: defaults, saveToken: { _ in }) == .unreadable)
        #expect(!defaults.bool(forKey: I.doneKey))
    }

    @Test func theRealConfigPathIsNeverUsedHere() {
        // The default path is a value only the app's release build ever passes
        // in; tests hand in their own. This pins where it points.
        #expect(I.defaultConfigURL.path.hasSuffix("Application Support/Cascade/config.json"))
    }
}
