import Foundation

/// Moves settings between the Electron app's `config.json` (electron-store)
/// and this app's UserDefaults, in both directions, from one table.
///
/// Electron to native runs once, on first launch ("Phase 6"). Native to
/// Electron runs when the user picks "Switch back to the Electron build", so
/// nothing set in either app is lost by switching. The Electron file is never
/// deleted, and a write back only touches the keys this table knows: every
/// other key in it (and anything a newer Electron added) is kept as it was.
///
/// Every value out of `config.json` is untrusted. electron-store keeps some
/// things as stringified JSON (`libraryIds`, `theme`, `eqMusic`...), one as the
/// text 'true' (`discordRpcEnabled`), and a hand edit can make any of it
/// anything, so each entry has its own validator and a value that fails is
/// skipped, never guessed at.
///
/// The key names on the native side are the Electron names under `cascade.`
/// (docs/mac-native-plan.md), except where an existing native setting already
/// had a name: those are spelled out in the table, which is the one place to
/// change if a name moves.
///
/// Pure: the file path and the defaults are passed in, so tests run on
/// fixtures and nothing here knows where the real config lives.
public enum ElectronSettingsImport {
    /// UserDefaults key set once an import has run (or been made pointless by
    /// an existing session), so it never runs twice.
    public static let doneKey = "cascade.electronImportDone"

    /// Where electron-store keeps the installed app's settings. Only the app's
    /// release build ever reads it by default; see `MacSettingsImport`.
    public static var defaultConfigURL: URL {
        URL.applicationSupportDirectory.appending(path: "Cascade/config.json")
    }

    /// Electron keys that have no native meaning and are deliberately not
    /// carried: Chromium output device ids are not CoreAudio UIDs, the
    /// decode-check list is Chromium's, the window frame is SwiftUI's own,
    /// Bergamot and the Apple-versus-Mozilla choice are gone with Mozilla's
    /// models, and `libraryId` and `password` are long-dead legacy keys.
    public static let dropped: Set<String> = [
        "outputDeviceId", "undecodableAudioCodecs", "windowState", "appleTranslationMozillaChosen",
        "appleTranslationEnabled", "libraryId", "password", "deviceIdMigrated", "macBuild",
    ]

    // MARK: Results

    public struct Imported: Equatable {
        /// UserDefaults keys to values, ready for `defaults.set`.
        public var values: [String: Any] = [:]
        /// The access token, which belongs in the Keychain or its file, not UserDefaults.
        public var token: String?
        /// Electron keys that were present but failed validation.
        public var rejected: [String] = []

        public static func == (a: Imported, b: Imported) -> Bool {
            NSDictionary(dictionary: a.values).isEqual(to: b.values) && a.token == b.token && a.rejected == b.rejected
        }
    }

    // MARK: Validators

    static func strictBool(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let s = v as? String { return s == "true" ? true : s == "false" ? false : nil }
        return nil
    }

    static func int(_ v: Any?, _ range: ClosedRange<Int>) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue == n.doubleValue.rounded() else { return nil }
        let i = n.intValue
        return range.contains(i) ? i : nil
    }

    static func double(_ v: Any?, _ range: ClosedRange<Double>) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              range.contains(n.doubleValue) else { return nil }
        return n.doubleValue
    }

    static func text(_ v: Any?, max: Int, allowing pattern: Regex<Substring>? = nil, empty: Bool = false) -> String? {
        guard let s = v as? String, s.count <= max, empty || !s.isEmpty else { return nil }
        if let pattern, s.wholeMatch(of: pattern) == nil { return nil }
        return s
    }

    /// A JSON value that arrived as a string (electron-store holds these
    /// stringified) or already parsed, as a parsed object or array.
    static func json(_ v: Any?, maxBytes: Int) -> Any? {
        if let s = v as? String {
            guard s.utf8.count <= maxBytes, let data = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        return v is [Any] || v is [String: Any] ? v : nil
    }

    static func jsonObjectString(_ v: Any?, maxBytes: Int) -> String? {
        guard json(v, maxBytes: maxBytes) is [String: Any] else { return nil }
        return (v as? String) ?? stringify(v)
    }

    static func stringify(_ v: Any?) -> String? {
        guard let v, JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A list of ids, as a JSON string or an array, each one short and made of
    /// the characters Jellyfin ids use.
    static func idList(_ v: Any?) -> [String]? {
        guard let list = json(v, maxBytes: 20_000) as? [Any], list.count <= 500 else { return nil }
        var out: [String] = []
        for item in list {
            guard let id = text(item, max: 64, allowing: /[A-Za-z0-9_-]+/) else { return nil }
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    static func httpUrl(_ v: Any?, trimSlash: Bool) -> String? {
        guard var s = text(v, max: 2048), let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host() != nil else { return nil }
        if trimSlash { while s.hasSuffix("/") { s.removeLast() } }
        return s
    }

    static let lyricSources: Set<String> = ["auto", "Kugou", "LRCLIB", "Jellyfin", "cascade-karaoke", "cascade-synced"]
    static let viewPrefs = ["albums", "artists", "playlists", "movies", "shows"]

    // MARK: The table

    /// One row: the Electron keys it owns, how they become native values, and
    /// how native values become Electron ones. `toNative` returns native
    /// UserDefaults keys and values (or nothing, if the Electron side was
    /// absent or invalid); `toElectron` reads native values and returns the
    /// Electron keys to write.
    struct Row {
        var electron: [String]
        /// Validated native values, or nil for "rejected". An empty dictionary is "absent".
        var toNative: ([String: Any]) -> [String: Any]?
        var toElectron: (_ native: (String) -> Any?, _ existing: [String: Any]) -> [String: Any]
    }

    /// One Electron key to one native key with a validator each way. The
    /// reverse validates what UserDefaults holds just as the forward direction
    /// validates the file: a stray value never reaches the Electron file.
    private static func simple(_ electron: String, _ native: String,
                               import imp: @escaping (Any?) -> Any?,
                               export exp: @escaping (Any?) -> Any? = { $0 }) -> Row {
        Row(electron: [electron],
            toNative: { config in
                guard let raw = config[electron] else { return [:] }
                guard let v = imp(raw) else { return nil }
                return [native: v]
            },
            toElectron: { read, _ in
                guard let raw = read(native), let v = exp(raw) else { return [:] }
                return [electron: v]
            })
    }

    private static func bool(_ electron: String, _ native: String) -> Row {
        simple(electron, native, import: { strictBool($0) }, export: { ($0 as? Bool) })
    }

    private static func ids(_ electron: String, _ native: String) -> Row {
        simple(electron, native, import: { idList($0) },
               export: { v in (v as? [String]).flatMap { idList($0) }.flatMap { stringify($0) } })
    }

    /// A JSON object kept as the same string on both sides (the blobs the
    /// native views read and write themselves).
    private static func blob(_ electron: String, _ native: String, maxBytes: Int = 8_192) -> Row {
        simple(electron, native, import: { jsonObjectString($0, maxBytes: maxBytes) },
               export: { v in (v as? String).flatMap { jsonObjectString($0, maxBytes: maxBytes) } })
    }

    private static func enumeration(_ electron: String, _ native: String, _ allowed: Set<String>) -> Row {
        simple(electron, native, import: { ($0 as? String).flatMap { allowed.contains($0) ? $0 : nil } },
               export: { ($0 as? String).flatMap { allowed.contains($0) ? $0 : nil } })
    }

    nonisolated(unsafe) static let table: [Row] = {
        var rows: [Row] = []

        // Identity and session. The token is handled apart (see `token`), since
        // it must not land in UserDefaults.
        rows.append(simple("serverUrl", "cascade.serverUrl", import: { httpUrl($0, trimSlash: true) },
                           export: { httpUrl($0, trimSlash: true) }))
        rows.append(simple("username", "cascade.username", import: { text($0, max: 256) }, export: { text($0, max: 256) }))
        rows.append(simple("userId", "cascade.userId", import: { text($0, max: 64, allowing: /[A-Za-z0-9_-]+/) },
                           export: { text($0, max: 64, allowing: /[A-Za-z0-9_-]+/) }))
        // Kept, so the server does not see a new device: remote control and
        // history stay continuous across the switch.
        rows.append(simple("deviceId", "cascade.deviceId", import: { text($0, max: 128, allowing: /[A-Za-z0-9._-]{4,128}/) },
                           export: { text($0, max: 128, allowing: /[A-Za-z0-9._-]{4,128}/) }))

        // Libraries and browsing.
        rows.append(ids("libraryIds", "cascade.libraryIds"))
        rows.append(ids("movieLibraryIds", "cascade.movieLibraryIds"))
        rows.append(ids("showLibraryIds", "cascade.showLibraryIds"))
        // Kept as the JSON array text, as the desktop keeps it and the native
        // poster groups read it.
        rows.append(simple("collapsedLibs", "cascade.collapsedLibs",
                           import: { idList($0).flatMap { stringify($0) } },
                           export: { v in (v as? String).flatMap { idList($0) }.flatMap { stringify($0) } }))
        rows.append(bool("singleLibraryMode", "cascade.singleLibraryMode"))
        rows.append(enumeration("browseMode", "cascade.browseMode", ["music", "video"]))
        rows.append(bool("radioEnabled", "cascade.radioEnabled"))
        for name in viewPrefs { rows.append(blob("\(name)Prefs", "cascade.\(name)Prefs")) }
        rows.append(enumeration("songsSortField", "cascade.songsSortField", ["name", "artist", "album", "added", "played"]))
        rows.append(enumeration("songsSortDir", "cascade.songsSortDir", ["asc", "desc"]))

        // Onboarding.
        rows.append(simple("wizardSeenRevision", "cascade.wizardSeenRevision", import: { int($0, 0...1000) },
                           export: { int($0, 0...1000) }))
        rows.append(bool("firstRunWizardSeen", "cascade.firstRunWizardSeen"))
        rows.append(bool("videoIntroSeen", "cascade.videoIntroSeen"))
        rows.append(bool("cascadePluginNoticeSeen", "cascade.cascadePluginNoticeSeen"))

        // Playback. Native holds crossfade as one number (0 is off), streaming
        // quality as a StreamingQuality raw value, and normalization as one
        // mode, where Electron keeps a switch beside each setting.
        rows.append(Row(
            electron: ["crossfadeEnabled", "crossfadeSeconds"],
            toNative: { c in
                guard c["crossfadeEnabled"] != nil || c["crossfadeSeconds"] != nil else { return [:] }
                let on = strictBool(c["crossfadeEnabled"]) ?? false
                guard on else { return ["cascade.crossfadeSeconds": 0] }
                // Electron's slider is 1 to 15 and defaults to 6.
                let seconds = int(c["crossfadeSeconds"], 1...15) ?? 6
                return ["cascade.crossfadeSeconds": seconds]
            },
            toElectron: { native, _ in
                guard let s = int(native("cascade.crossfadeSeconds"), 0...15) else { return [:] }
                return s > 0 ? ["crossfadeEnabled": true, "crossfadeSeconds": s] : ["crossfadeEnabled": false]
            }))
        rows.append(simple("maxStreamingBitrate", "cascade.streamingQuality",
                           import: { v in
                               guard let bps = int(v, 1...1_000_000_000) else { return nil }
                               // A value between steps lands on the step below it, so a
                               // cap is never loosened by the mapping (the same rule as
                               // StreamingQuality(electronBitrate:)); anything at or past
                               // the desktop's Original, 140 Mbps, is Original.
                               guard bps < 140_000_000 else { return 0 }
                               let steps = [96_000, 128_000, 192_000, 256_000, 320_000]
                               return steps.last { $0 <= bps } ?? 96_000
                           },
                           export: { v in
                               guard let q = v as? Int else { return nil }
                               if q == 0 { return 140_000_000 }
                               return [96_000, 128_000, 192_000, 256_000, 320_000].contains(q) ? q : nil
                           }))
        rows.append(Row(
            electron: ["normalizationEnabled", "normalizationSource"],
            toNative: { c in
                guard c["normalizationEnabled"] != nil || c["normalizationSource"] != nil else { return [:] }
                guard strictBool(c["normalizationEnabled"]) == true else { return ["cascade.normalization": "off"] }
                return ["cascade.normalization": (c["normalizationSource"] as? String) == "album" ? "album" : "track"]
            },
            toElectron: { native, _ in
                switch native("cascade.normalization") as? String {
                case "off": ["normalizationEnabled": false]
                case "track": ["normalizationEnabled": true, "normalizationSource": "track"]
                case "album": ["normalizationEnabled": true, "normalizationSource": "album"]
                default: [:]
                }
            }))
        rows.append(simple("volume", "cascade.volume", import: { double($0, 0...1) }, export: { double($0, 0...1) }))
        rows.append(bool("shuffle", "cascade.shuffle"))
        rows.append(enumeration("repeatMode", "cascade.repeatMode", ["none", "all", "one"]))
        rows.append(simple("lastQueue", "cascade.lastQueue",
                           import: { v in (v as? String).flatMap { json($0, maxBytes: 400_000) != nil ? $0 : nil } },
                           export: { v in (v as? String).flatMap { json($0, maxBytes: 400_000) != nil ? $0 : nil } }))

        // The equalizer. Electron has a master switch plus one switch per
        // profile and stores gains as `bands`; native has one `enabled` per
        // profile and `gains`. Native on means master and profile both on.
        // Music is `cascade.eq` (its first name), video `cascade.eqVideo`.
        rows.append(Row(
            electron: ["eqEnabled", "eqMusic", "eqVideo"],
            toNative: { c in
                guard c["eqEnabled"] != nil || c["eqMusic"] != nil || c["eqVideo"] != nil else { return [:] }
                let master = strictBool(c["eqEnabled"]) == true
                var out: [String: Any] = [:]
                for (electron, native) in [("eqMusic", "cascade.eq"), ("eqVideo", "cascade.eqVideo")] {
                    guard let raw = c[electron] else { continue }
                    guard let object = json(raw, maxBytes: 4_096) as? [String: Any] else { return nil }
                    let bands = (object["bands"] as? [Any]) ?? []
                    let profile = EQProfile(enabled: master && (object["enabled"] as? Bool ?? true),
                                            preamp: double(object["preamp"], -1000...1000).map(EQProfile.clamp),
                                            gains: EQProfile.bands.indices.map { i in
                                                i < bands.count ? (double(bands[i], -1000...1000).map(EQProfile.clamp) ?? 0) : 0
                                            })
                    guard let data = profile.encoded() else { return nil }
                    out[native] = data
                }
                return out
            },
            toElectron: { native, _ in
                var out: [String: Any] = [:]
                var anyOn = false
                for (electron, key) in [("eqMusic", "cascade.eq"), ("eqVideo", "cascade.eqVideo")] {
                    guard let data = native(key) as? Data else { continue }
                    let p = EQProfile.decode(data)
                    anyOn = anyOn || p.enabled
                    var object: [String: Any] = ["enabled": p.enabled, "bands": p.gains]
                    object["preamp"] = p.preamp ?? NSNull()
                    if let s = stringify(object) { out[electron] = s }
                }
                if !out.isEmpty { out["eqEnabled"] = anyOn }
                return out
            }))

        // Lyrics.
        rows.append(bool("serverOnlyMode", "cascade.serverOnlyLyrics"))
        rows.append(enumeration("lyricsForcedSource", "cascade.lyricsForcedSource", lyricSources))
        rows.append(bool("lyricsTranslationEnabled", "cascade.lyricsTranslationEnabled"))
        rows.append(bool("lyricsTranslateOn", "cascade.lyricsTranslateOn"))
        rows.append(blob("lyricStyle", "cascade.lyricStyle"))
        rows.append(blob("npTuning", "cascade.npTuning"))

        // Look.
        rows.append(blob("theme", "cascade.theme"))
        rows.append(blob("uiFont", "cascade.uiFont"))

        // Integrations. Discord's switch is the text 'true' in Electron.
        rows.append(simple("discordRpcEnabled", "cascade.discordRpcEnabled", import: { strictBool($0) },
                           export: { ($0 as? Bool).map { $0 ? "true" : "false" } }))
        rows.append(simple("discordClientId", "cascade.discordClientId", import: { text($0, max: 32, allowing: /[0-9]{5,32}/) },
                           export: { text($0, max: 32, allowing: /[0-9]{5,32}/) }))
        // The native Waterfall screen already stores these two under its own names.
        rows.append(simple("waterfallRelay", "cascade.wf.relay",
                           import: { v in (v as? String) == "" ? "" : httpUrl(v, trimSlash: true) },
                           export: { v in (v as? String) == "" ? "" : httpUrl(v, trimSlash: true) }))
        rows.append(bool("waterfallAllowGuestControl", "cascade.wf.guestControl"))
        rows.append(simple("miniplayerHeight", "cascade.miniplayerHeight", import: { int($0, 100...900) }, export: { int($0, 100...900) }))

        // Definitions the native side already has types for: go through them,
        // so whatever shape native stores them in, they load, and a bad entry is dropped.
        rows.append(Row(
            electron: ["smartPlaylists"],
            toNative: { c in
                guard let raw = c["smartPlaylists"] else { return [:] }
                guard let list = json(raw, maxBytes: 400_000) as? [Any] else { return nil }
                let playlists = list.compactMap { ElectronSmartPlaylist.native($0) }
                return ["cascade.smartPlaylists": SmartPlaylist.encodeList(playlists)]
            },
            toElectron: { native, _ in
                guard let data = native("cascade.smartPlaylists") as? Data,
                      let text = stringify(SmartPlaylist.decodeList(data).map(ElectronSmartPlaylist.electron)) else { return [:] }
                return ["smartPlaylists": text]
            }))
        rows.append(Row(
            electron: ["spotifyLinks"],
            toNative: { c in
                guard let raw = c["spotifyLinks"] else { return [:] }
                guard let dict = json(raw, maxBytes: 400_000) as? [String: Any] else { return nil }
                var out: [String: String] = [:]
                for (item, link) in dict where item.count <= 64 {
                    if let s = link as? String, let id = Spotify.trackId(s) { out[item] = id }
                }
                return ["cascade.spotifyLinks": out]
            },
            toElectron: { native, _ in
                guard let dict = native("cascade.spotifyLinks") as? [String: String],
                      let text = stringify(dict.filter { Spotify.trackId($0.value) != nil }) else { return [:] }
                return ["spotifyLinks": text]
            }))
        return rows
    }()

    /// Every Electron key some row owns, plus the token.
    public static var knownElectronKeys: Set<String> {
        Set(table.flatMap(\.electron)).union(["token"])
    }

    // MARK: Electron to native

    /// What the file's values become. Pure: applies nothing.
    public static func map(_ config: [String: Any]) -> Imported {
        var result = Imported()
        for row in table {
            guard let native = row.toNative(config) else {
                result.rejected.append(contentsOf: row.electron.filter { config[$0] != nil })
                continue
            }
            for (key, value) in native { result.values[key] = value }
        }
        if let raw = config["token"] {
            if let token = text(raw, max: 4096, allowing: /[^\s\u{0}-\u{1f}]+/) { result.token = token } else { result.rejected.append("token") }
        }
        return result
    }

    /// Writes mapped values into UserDefaults. Nothing is removed.
    public static func apply(_ imported: Imported, to defaults: UserDefaults) {
        for (key, value) in imported.values { defaults.set(value, forKey: key) }
    }

    // MARK: Native to Electron

    /// `config` with this app's current settings written over the keys the
    /// table owns; every other key is kept. `nativeValue` reads a UserDefaults
    /// key (`defaults.object(forKey:)`). Sets `macBuild` to 'electron': a
    /// successful switch to native left it at 'native', and a reinstalled
    /// Electron would otherwise keep offering the native build.
    public static func export(nativeValue: (String) -> Any?, token: String?, into config: [String: Any]) -> [String: Any] {
        var out = config
        for row in table {
            for (key, value) in row.toElectron(nativeValue, config) { out[key] = value }
        }
        if let token, text(token, max: 4096, allowing: /[^\s\u{0}-\u{1f}]+/) != nil {
            out["token"] = token
            // The token is bound to the device id Electron will now use.
            out["deviceIdMigrated"] = true
        }
        out["macBuild"] = "electron"
        return out
    }

    // MARK: Files

    public enum FileError: Error, Equatable, LocalizedError {
        case unreadable, tooLarge, notAnObject
        public var errorDescription: String? {
            switch self {
            case .unreadable: "The settings file could not be read."
            case .tooLarge: "The settings file is too large."
            case .notAnObject: "The settings file is not in the expected format."
            }
        }
    }

    /// Anything near this is not a settings file (a real one is a few KB, a
    /// long saved queue and smart playlists a few hundred).
    static let maxFileBytes = 5_000_000

    public static func read(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { throw FileError.unreadable }
        guard data.count <= maxFileBytes else { throw FileError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FileError.notAnObject }
        return object
    }

    /// The first write beside an existing file keeps what was there under this
    /// name, once, so the very first switch back can always be undone by hand.
    public static let backupSuffix = ".cascade-native-backup"

    /// Writes `config` to `url` through a temporary file and a rename, so a
    /// crash never leaves half a file for Electron to choke on. Never deletes
    /// `url`. Creates the one-time backup when the file already exists.
    public static func write(_ config: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: url.path + backupSuffix)
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: First launch

    public enum Outcome: Equatable {
        case imported(applied: Int, rejected: [String])
        /// Already ran, or this app already holds a session that an import must not overwrite.
        case skipped
        case noFile
        case unreadable
    }

    /// The one-shot import: reads `configURL`, applies it to `defaults`, hands
    /// the token to `saveToken`, and marks it done. Does nothing if it already
    /// ran, and never replaces an existing native session (one that already
    /// has a server and a user), which it marks done instead. A missing file
    /// is not marked done, so installing the Electron app later still works.
    @discardableResult
    public static func runOnce(configURL: URL, defaults: UserDefaults, saveToken: (String) -> Void) -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return .skipped }
        if defaults.string(forKey: "cascade.serverUrl") != nil, defaults.string(forKey: "cascade.userId") != nil {
            defaults.set(true, forKey: doneKey)
            return .skipped
        }
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .noFile }
        guard let config = try? read(configURL) else { return .unreadable }
        let imported = map(config)
        apply(imported, to: defaults)
        if let token = imported.token { saveToken(token) }
        defaults.set(true, forKey: doneKey)
        return .imported(applied: imported.values.count, rejected: imported.rejected)
    }
}

/// Smart playlists between the Electron shape (`{field, op, value}` rules,
/// `match`, `sortDir`) and the native model.
enum ElectronSmartPlaylist {
    static func native(_ raw: Any) -> SmartPlaylist? {
        guard let d = raw as? [String: Any], let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        var rules: [SmartPlaylist.Rule] = []
        for case let r as [String: Any] in (d["rules"] as? [Any] ?? []) {
            switch r["field"] as? String {
            case "genre":
                if let v = r["value"] as? String, let op = r["op"] as? String, op == "is" || op == "isNot" { rules.append(.genre(v, isNot: op == "isNot")) }
            case "artist":
                if let v = r["value"] as? String { rules.append(.artist(v)) }
            case "year":
                if let a = r["min"] as? Int, let b = r["max"] as? Int { rules.append(.year(min: a, max: b)) }
            case "addedWithinDays":
                if let v = r["days"] as? Int { rules.append(.addedWithinDays(v)) }
            case "played":
                if let v = r["value"] as? Bool { rules.append(.played(v)) }
            case "playCount":
                if let v = r["value"] as? Int { rules.append(.playCountAtLeast(v)) }
            case "favorite":
                if let v = r["value"] as? Bool { rules.append(.favorite(v)) }
            default: break
            }
        }
        let sort = (d["sortBy"] as? String).flatMap(SmartPlaylist.SortField.init(rawValue:)) ?? .name
        return SmartPlaylist(id: id, name: name, matchAny: d["match"] as? String == "any", rules: rules, sortBy: sort,
                             descending: d["sortDir"] as? String == "desc", limit: d["limit"] as? Int ?? 100).validated()
    }

    static func electron(_ p: SmartPlaylist) -> [String: Any] {
        let rules: [[String: Any]] = p.rules.map {
            switch $0 {
            case .genre(let v, let isNot): ["field": "genre", "op": isNot ? "isNot" : "is", "value": v]
            case .artist(let v): ["field": "artist", "op": "is", "value": v]
            case .year(let a, let b): ["field": "year", "op": "between", "min": a, "max": b]
            case .addedWithinDays(let d): ["field": "addedWithinDays", "op": "lte", "days": d]
            case .played(let v): ["field": "played", "op": "is", "value": v]
            case .playCountAtLeast(let n): ["field": "playCount", "op": "gte", "value": n]
            case .favorite(let v): ["field": "favorite", "op": "is", "value": v]
            }
        }
        return ["id": p.id, "name": p.name, "match": p.matchAny ? "any" : "all", "rules": rules,
                "sortBy": p.sortBy.rawValue, "sortDir": p.descending ? "desc" : "asc", "limit": p.limit]
    }
}
