import Foundation

/// What the Mac updater takes from a GitHub release: which version of each
/// Mac build it holds, and which of its files installs that version. The
/// desktop's src/core/update-release.ts, plus the native build's half.
///
/// A release is no longer one version of one app. A release named for the
/// newest version of ANY platform carries the other platforms' files over
/// from the release before, still named for their own versions, plus a
/// `versions.json` asset saying which version each platform is at:
///
///     { "desktop": "2.4.0", "mac": "2.4.0", "apple": "2.3.1", "android": "2.3.2" }
///
/// `desktop` is the Electron build (all three OSes), `mac` the native Mac
/// build. Reading the tag alone would make a release that merely carried a
/// DMG over look like an update forever, so the versions come from that file.
///
/// Two Mac builds ship in every release (docs/mac-native-plan.md), told apart
/// by name: Electron's is `Cascade-<desktop>-arm64.dmg` (every updater already
/// in the wild picks the first .dmg with "arm64" in it), the native one is
/// `Cascade-Native-<mac>.dmg`, with no "arm64", so an old Electron updater can
/// never be handed the native app by accident.
public enum UpdateRelease {
    /// The parts of a GitHub release asset this module reads.
    public struct Asset: Equatable, Sendable {
        public var name: String
        public var url: String?
        public var size: Int?
        /// "sha256:<hex>", as GitHub publishes it.
        public var digest: String?

        public init(name: String, url: String? = nil, size: Int? = nil, digest: String? = nil) {
            self.name = name
            self.url = url
            self.size = size
            self.digest = digest
        }
    }

    /// The parts of a GitHub release this module reads.
    public struct Release: Equatable, Sendable {
        public var tag: String?
        public var assets: [Asset]
        public var body: String
        public var htmlUrl: String?
        public var publishedAt: String?

        public init(tag: String?, assets: [Asset] = [], body: String = "", htmlUrl: String? = nil, publishedAt: String? = nil) {
            self.tag = tag
            self.assets = assets
            self.body = body
            self.htmlUrl = htmlUrl
            self.publishedAt = publishedAt
        }

        /// From one release object of GitHub's API. Untrusted: every field is
        /// checked, an asset not shaped like one is dropped.
        public init?(json: Any) {
            guard let dict = json as? [String: Any] else { return nil }
            let assets = (dict["assets"] as? [Any] ?? []).compactMap { raw -> Asset? in
                guard let a = raw as? [String: Any], let name = a["name"] as? String else { return nil }
                return Asset(name: name, url: a["browser_download_url"] as? String,
                             size: a["size"] as? Int, digest: a["digest"] as? String)
            }
            self.init(tag: dict["tag_name"] as? String, assets: assets, body: dict["body"] as? String ?? "",
                      htmlUrl: dict["html_url"] as? String, publishedAt: dict["published_at"] as? String)
        }
    }

    public static let versionsAssetName = "versions.json"

    /// The real file is well under 100 bytes. Anything near this is not that
    /// file, and there is no reason to read a large download to find out.
    public static let versionsMaxBytes = 4096

    // MARK: Versions

    /// x.y.z, or a x.y.z-bN beta, each number at most 4 digits. Deliberately
    /// strict: the value decides whether an update is offered and ends up in
    /// the installer's version check, so "2.3", "v2.3.1", "2.3.1 " and "999"
    /// are all refused rather than guessed at.
    public static func isReleaseVersion(_ v: Any?) -> Bool {
        guard let s = v as? String else { return false }
        return s.wholeMatch(of: /(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})(-b[1-9][0-9]{0,3})?/) != nil
    }

    /// [major, minor, patch, beta]. A release sorts above every `-bN` beta of
    /// the same version (beta is Int.max for a release). Any other suffix is
    /// stripped, so it compares equal to the release.
    public static func parseAppVersion(_ raw: String) -> [Int] {
        var s = raw
        if s.hasPrefix("v") { s.removeFirst() }
        var beta = Int.max
        if let m = s.firstMatch(of: /(?i)-b([0-9]+)$/) { beta = Int(m.1) ?? Int.max }
        // Everything from the first - or + goes, as the desktop's regexp does.
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).prefix(3).map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        return [parts.count > 0 ? parts[0] : 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0, beta]
    }

    public static func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let l = parseAppVersion(latest), c = parseAppVersion(current)
        for i in 0..<4 where l[i] != c[i] { return l[i] > c[i] }
        return false
    }

    // MARK: versions.json

    public struct VersionsFile: Equatable, Sendable {
        /// Nil: a well-formed file with no such entry, so the release holds
        /// no build of that kind (a beta for another platform, say).
        public var desktop: String?
        public var mac: String?
    }

    /// Reads the text of a versions.json. Untrusted: it is a file anyone with
    /// write access to the repo can upload. Nil for anything wrong with it,
    /// including a `desktop` or `mac` entry that is present but not a plain
    /// version. Other platforms' entries are not this app's business.
    public static func parseVersionsFile(_ text: String?) -> VersionsFile? {
        guard let text, text.utf8.count <= versionsMaxBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let dict = object as? [String: Any] else { return nil }
        func entry(_ key: String) -> String?? {
            guard let value = dict[key] else { return .some(nil) }
            return isReleaseVersion(value) ? .some(value as? String) : nil
        }
        guard let desktop = entry("desktop"), let mac = entry("mac") else { return nil }
        return VersionsFile(desktop: desktop, mac: mac)
    }

    public static func findVersionsAsset(_ release: Release) -> Asset? {
        release.assets.first { $0.name == versionsAssetName }
    }

    // MARK: Asset names

    static let installerExtensions = ["exe", "dmg", "appimage", "deb", "rpm"]

    /// A desktop installer, as opposed to versions.json, an .ipa, an .apk, a blockmap.
    public static func isDesktopInstaller(_ name: String) -> Bool {
        installerExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether a file name carries exactly this version, as the build names
    /// them: `Cascade-2.3.1-arm64.dmg`, `Cascade.Setup.2.3.1.exe`,
    /// `Cascade-Native-2.4.0.dmg`. A whole version only: 2.3.1 is not in
    /// 12.3.1, 2.3.10, 1.2.3.1 or 2.3.1-b2. Written by hand because Swift's
    /// regex has no lookbehind, which the TypeScript version leans on.
    public static func nameCarriesVersion(_ name: String, _ version: String) -> Bool {
        guard !version.isEmpty else { return false }
        let chars = Array(name.unicodeScalars)
        let want = Array(version.unicodeScalars)
        guard chars.count >= want.count else { return false }
        func digit(_ i: Int) -> Bool { i >= 0 && i < chars.count && ("0"..."9").contains(chars[i]) }
        for start in 0...(chars.count - want.count) where Array(chars[start..<start + want.count]) == want {
            let end = start + want.count
            // Not the tail of a longer number, or of a longer dotted version.
            if digit(start - 1) { continue }
            if start >= 2, chars[start - 1] == ".", digit(start - 2) { continue }
            // Not the head of a longer number, a longer dotted version, or a beta.
            if digit(end) { continue }
            if end + 1 < chars.count, chars[end] == ".", digit(end + 1) { continue }
            if end + 1 < chars.count, chars[end] == "-", chars[end + 1] == "b" { continue }
            return true
        }
        return false
    }

    // MARK: Which version a release holds

    public enum Kind: Sendable {
        /// The Electron build, which installs on Windows, Linux and Mac.
        case desktop
        /// The native Mac build.
        case mac
    }

    public struct Build: Equatable, Sendable {
        public var version: String
        /// Where the version came from, for the log.
        public var source: Source
        public enum Source: String, Sendable { case versionsFile = "versions.json", tag }
    }

    static func isNativeInstaller(_ name: String) -> Bool {
        name.range(of: "^Cascade-Native-.*\\.dmg$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The version of one build a release holds, or nil if it holds none.
    ///
    /// `versionsText` is the downloaded versions.json, or nil when the release
    /// has none or it could not be read. For `.desktop`, without a usable file
    /// the tag is used, which is what every release before 2.3 needs. The
    /// native build has no such history, so it needs the file: no tag guess.
    ///
    /// Either way, at least one installer of that build in the release must
    /// carry the version in its name. That is what stops a bad file from
    /// causing an update offer on its own: a file claiming 9.9.9 offers
    /// nothing unless the release really contains that build.
    public static func buildOf(_ kind: Kind, release: Release, versionsText: String?) -> Build? {
        var pick: Build?
        let file = versionsText.flatMap { parseVersionsFile($0) }
        if let file {
            guard let version = kind == .desktop ? file.desktop : file.mac else { return nil }
            pick = Build(version: version, source: .versionsFile)
        } else if kind == .desktop, let tag = release.tag {
            // Looser than isReleaseVersion on purpose (old betas were tagged
            // v1.1.1-b), but still only letters, digits, dots and dashes: the
            // version ends up in a file name.
            let bare = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if bare.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]*)?/) != nil {
                pick = Build(version: bare, source: .tag)
            }
        }
        guard let pick else { return nil }
        let built = release.assets.contains { a in
            switch kind {
            case .desktop: isDesktopInstaller(a.name) && nameCarriesVersion(a.name, pick.version)
            case .mac: isNativeInstaller(a.name) && nameCarriesVersion(a.name, pick.version)
            }
        }
        return built ? pick : nil
    }

    /// The Electron build's version, as `desktopBuildOf` in the TypeScript.
    public static func desktopBuildOf(_ release: Release, versionsText: String?) -> Build? {
        buildOf(.desktop, release: release, versionsText: versionsText)
    }

    /// The native Mac build's version.
    public static func macBuildOf(_ release: Release, versionsText: String?) -> Build? {
        buildOf(.mac, release: release, versionsText: versionsText)
    }

    // MARK: Which file installs it

    /// The native DMG carrying `version`, or nil. No "close enough" fallback:
    /// an installer of another version is one the installer refuses anyway.
    public static func pickNativeInstaller(_ release: Release, version: String) -> Asset? {
        release.assets.first { isNativeInstaller($0.name) && nameCarriesVersion($0.name, version) }
    }

    /// The Electron Mac DMG carrying `version`, for "Switch back to the
    /// Electron build": the first .dmg with "arm64" in its name, which is the
    /// rule every Electron updater already uses, minus the native one.
    public static func pickElectronMacInstaller(_ release: Release, version: String) -> Asset? {
        release.assets.first {
            nameCarriesVersion($0.name, version) && $0.name.lowercased().hasSuffix(".dmg")
                && $0.name.lowercased().contains("arm64") && !isNativeInstaller($0.name)
        }
    }
}
