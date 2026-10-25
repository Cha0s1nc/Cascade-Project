import Foundation

/// The shipped tuning defaults: tuning-defaults.json at the repo root, which the
/// desktop reads too, compiled in as TuningDefaultsData. A value there is either
/// shared or split per platform (`desktop`, `mac`, `ios`, `tvos`, the group
/// `apple`, and `all`); the most specific key a platform has wins. The same rules
/// as the desktop's src/core/tuning.ts. Change the file with `npm run tuning`,
/// which also rewrites the Swift copy.
public struct TuningDefaults: Sendable {
    public enum Platform: String, CaseIterable, Sendable {
        case desktop, mac, ios, tvos

        /// The targets this platform reads, most specific first.
        var chain: [String] {
            self == .desktop ? ["desktop", "all"] : [rawValue, "apple", "all"]
        }

        /// What this build is.
        public static var current: Platform {
            #if os(macOS)
            .mac
            #elseif os(tvOS)
            .tvos
            #else
            .ios
            #endif
        }
    }

    public let platform: Platform
    /// The style knobs this platform has (Style Tuning), by key.
    public let style: [String: Double]
    public let albumColors: AlbumColorsTuning
    /// The latest defaults revision.
    public let revision: Int
    /// Per revision, the style keys whose default moved on this platform.
    public let revisionKeys: [Int: [String]]

    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    /// The compiled-in file, for this build's platform. A broken file is a broken
    /// build (CascadeKit's tests read it), so this stops rather than guessing.
    public static let current: TuningDefaults = {
        do {
            return try TuningDefaults(json: Data(TuningDefaultsData.json.utf8), platform: .current)
        } catch {
            fatalError("tuning-defaults.json: \(error)")
        }
    }()

    public init(json: Data, platform: Platform) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Invalid(description: "not an object")
        }
        self.platform = platform

        func section(_ name: String) -> [String: Any] { root[name] as? [String: Any] ?? [:] }

        var style: [String: Double] = [:]
        for (key, entry) in section("style") {
            if let v = Self.resolve(entry, platform).flatMap(Self.number) { style[key] = v }
        }
        self.style = style

        let colors = section("albumColors").compactMapValues { Self.resolve($0, platform) }
        albumColors = try AlbumColorsTuning(colors)

        var keys: [Int: [String]] = [:]
        for (number, value) in section("revisions") {
            guard let r = Int(number), let rev = value as? [String: Any] else { continue }
            var list: [String] = []
            for target in platform.chain {
                for k in rev[target] as? [String] ?? [] where !list.contains(k) { list.append(k) }
            }
            keys[r] = list
        }
        revisionKeys = keys
        revision = max(1, keys.keys.max() ?? 1)
    }

    /// A JSON number, however Foundation handed it over (NSNumber on Apple
    /// platforms, a Swift number in corelibs). Not checked against Bool: an
    /// NSNumber 0 or 1 casts to Bool too, so the check would refuse real zeros.
    static func number(_ v: Any) -> Double? {
        if let n = v as? Double { return n }
        if let n = v as? Int { return Double(n) }
        return (v as? NSNumber)?.doubleValue
    }

    /// A split entry is an object whose keys are all targets or `note`; anything
    /// else (a number, the slot list) is one shared value.
    static func resolve(_ entry: Any, _ platform: Platform) -> Any? {
        let targets: Set<String> = ["all", "apple", "desktop", "mac", "ios", "tvos", "note"]
        guard let split = entry as? [String: Any], !split.isEmpty, split.keys.allSatisfy(targets.contains) else {
            return entry
        }
        for target in platform.chain { if let v = split[target] { return v } }
        return nil
    }
}

/// The cover-color background's constants (the file's `albumColors`): see
/// AlbumColors, which reads them, and the desktop's album-colors.ts BlobTuning
/// for what each one does.
public struct AlbumColorsTuning: Sendable, Equatable {
    public struct Slot: Sendable, Equatable {
        public var x, y, w, h, alpha: Double
    }

    public var clusters: Int
    public var iterations: Int
    public var minSeparation: Double
    public var minSampleL: Double
    public var maxSampleL: Double
    public var minShare: Double
    public var chromaPower: Double
    public var minL: Double
    public var maxL: Double
    public var minLLight: Double
    public var maxLLight: Double
    public var minChroma: Double
    public var lightAlphaScale: Double
    public var driftScale: Double
    public var slots: [Slot]
    public var frameMs: Double
    public var sampleSide: Int

    init(_ v: [String: Any]) throws {
        func num(_ key: String, in object: [String: Any] = v, name: String? = nil) throws -> Double {
            guard let n = object[key].flatMap(TuningDefaults.number), n.isFinite else {
                throw TuningDefaults.Invalid(description: "albumColors.\(name ?? key) must be a number")
            }
            return n
        }
        clusters = Int(try num("clusters").rounded())
        iterations = Int(try num("iterations").rounded())
        minSeparation = try num("minSeparation")
        minSampleL = try num("minSampleL")
        maxSampleL = try num("maxSampleL")
        minShare = try num("minShare")
        chromaPower = try num("chromaPower")
        minL = try num("minL")
        maxL = try num("maxL")
        minLLight = try num("minLLight")
        maxLLight = try num("maxLLight")
        minChroma = try num("minChroma")
        lightAlphaScale = try num("lightAlphaScale")
        driftScale = try num("driftScale")
        frameMs = try num("frameMs")
        sampleSide = Int(try num("sampleSide").rounded())
        guard let list = v["slots"] as? [[String: Any]], !list.isEmpty else {
            throw TuningDefaults.Invalid(description: "albumColors.slots must be a list")
        }
        slots = try list.enumerated().map { i, s in
            Slot(x: try num("x", in: s, name: "slots[\(i)].x"), y: try num("y", in: s, name: "slots[\(i)].y"),
                 w: try num("w", in: s, name: "slots[\(i)].w"), h: try num("h", in: s, name: "slots[\(i)].h"),
                 alpha: try num("alpha", in: s, name: "slots[\(i)].alpha"))
        }
    }
}
