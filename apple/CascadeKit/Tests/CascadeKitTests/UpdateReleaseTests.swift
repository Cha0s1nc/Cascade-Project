import Foundation
import Testing
@testable import CascadeKit

// Ports test/update-release.test.ts, plus the native build's half.
@Suite struct UpdateReleaseTests {
    typealias R = UpdateRelease

    /// The asset names electron-builder and GitHub actually produced for v2.2.0.
    private func installers(_ v: String) -> [String] {
        ["Cascade-\(v)-arm64.dmg", "Cascade-\(v).AppImage", "cascade-\(v).x86_64.rpm", "Cascade.Setup.\(v).exe", "cascade_\(v)_amd64.deb"]
    }

    private func release(_ tag: String, _ names: [String]) -> R.Release {
        R.Release(tag: tag, assets: names.map { R.Asset(name: $0, url: "https://example.invalid/\($0)") })
    }

    @Test func newerKeepsTheOldOrderingBetasBelowTheirRelease() {
        #expect(R.isNewerVersion("2.3.0", than: "2.2.0"))
        #expect(!R.isNewerVersion("2.2.0", than: "2.2.0"))
        #expect(!R.isNewerVersion("2.2.0", than: "2.3.0"))
        #expect(R.isNewerVersion("2.3.0-b2", than: "2.3.0-b1"))
        #expect(R.isNewerVersion("2.3.0", than: "2.3.0-b4"))
        #expect(!R.isNewerVersion("2.3.0-b4", than: "2.3.0"))
        #expect(R.isNewerVersion("2.3.0-b1", than: "2.2.9"))
        #expect(R.isNewerVersion("v2.10.0", than: "2.9.0"))
        // Any other suffix is stripped, so it compares equal to the release.
        #expect(!R.isNewerVersion("2.3.0-rc1", than: "2.3.0"))
    }

    @Test func releaseVersionTakesOnlyPlainAndBeta() {
        for ok in ["2.3.1", "0.0.1", "10.20.30", "2.3.1-b1", "2.3.1-b12"] { #expect(R.isReleaseVersion(ok), "\(ok)") }
        let bad: [Any?] = ["v2.3.1", "2.3", "999", "2.3.1 ", " 2.3.1", "2.3.1-b", "2.3.1-b0", "2.3.1-rc1", "02.3.1",
                           "2.3.1.4", "99999.0.0", "2.3.1\n", "", 2.3, nil, ["2.3.1"]]
        for b in bad { #expect(!R.isReleaseVersion(b), "\(String(describing: b))") }
    }

    @Test func versionsFileReadsDesktopAndMac() {
        #expect(R.parseVersionsFile(#"{ "desktop": "2.3.1", "mac": "2.4.0", "apple": "2.3.1", "android": "2.3.2" }"#)
                == .init(desktop: "2.3.1", mac: "2.4.0"))
        #expect(R.parseVersionsFile(#"{"desktop":"2.4.0-b3"}"#) == .init(desktop: "2.4.0-b3", mac: nil))
        // Other platforms are not checked: a bad android entry is not ours.
        #expect(R.parseVersionsFile(#"{"desktop":"2.3.1","android":42}"#) == .init(desktop: "2.3.1", mac: nil))
        // A well-formed file with no entry says the release holds no such build.
        #expect(R.parseVersionsFile(#"{"android":"2.3.2-b1"}"#) == .init(desktop: nil, mac: nil))
        #expect(R.parseVersionsFile("{}") == .init(desktop: nil, mac: nil))
    }

    @Test func versionsFileRefusesAnythingMalformed() {
        let padded = String(repeating: "x", count: R.versionsMaxBytes)
        let bad = ["", "not json", #"{"desktop":"2.3.1""#, "[]", #"["2.3.1"]"#, "null", #""2.3.1""#, "231",
                   #"{"desktop":null}"#, #"{"desktop":231}"#, #"{"desktop":"999"}"#, #"{"desktop":"v2.3.1"}"#,
                   #"{"desktop":"2.3"}"#, #"{"desktop":{"version":"2.3.1"}}"#, #"{"desktop":"<script>"}"#,
                   #"{"desktop":"2.3.1","mac":"2.3"}"#, #"{"mac":9}"#,
                   #"{"desktop":"2.3.1","pad":"\#(padded)"}"#]
        for text in bad { #expect(R.parseVersionsFile(text) == nil, "\(text.prefix(60))") }
        #expect(R.parseVersionsFile(nil) == nil)
    }

    @Test func versionsFileIsNotFooledByAnInheritedKey() {
        #expect(R.parseVersionsFile(#"{"__proto__":{"desktop":"9.9.9"}}"#) == .init(desktop: nil, mac: nil))
    }

    @Test func findsTheVersionsAssetByExactName() {
        #expect(R.findVersionsAsset(release("v2.3.2", ["versions.json.bak", "Versions.json"])) == nil)
        #expect(R.findVersionsAsset(release("v2.3.2", ["a.dmg", "versions.json"]))?.name == "versions.json")
    }

    @Test func nameCarriesTheWholeVersionInEveryRealNamingStyle() {
        for name in installers("2.3.1") { #expect(R.nameCarriesVersion(name, "2.3.1"), "\(name)") }
        for name in installers("2.3.1-b2") { #expect(R.nameCarriesVersion(name, "2.3.1-b2"), "\(name)") }
        #expect(R.nameCarriesVersion("Cascade-1.1.1-b-arm64.dmg", "1.1.1-b"))
        #expect(R.nameCarriesVersion("Cascade-Native-2.4.0.dmg", "2.4.0"))
    }

    @Test func nameRefusesAVersionThatIsOnlyPartOfAnother() {
        #expect(!R.nameCarriesVersion("Cascade-12.3.1-arm64.dmg", "2.3.1"))
        #expect(!R.nameCarriesVersion("Cascade-2.3.10-arm64.dmg", "2.3.1"))
        #expect(!R.nameCarriesVersion("Cascade-1.2.3.1.AppImage", "2.3.1"))
        #expect(!R.nameCarriesVersion("Cascade.Setup.2.3.1-b2.exe", "2.3.1"))
        #expect(!R.nameCarriesVersion("Cascade-2.3.1-b12.AppImage", "2.3.1-b1"))
        #expect(!R.nameCarriesVersion("Cascade-2x3x1.AppImage", "2.3.1"))
        #expect(!R.nameCarriesVersion("Cascade-2.3.1.AppImage", ""))
        #expect(!R.nameCarriesVersion("Cascade-Native-12.4.0.dmg", "2.4.0"))
    }

    @Test func desktopBuildFallsBackToTheTagBeforeVersionsJson() {
        #expect(R.desktopBuildOf(release("v2.2.0", installers("2.2.0")), versionsText: nil) == .init(version: "2.2.0", source: .tag))
        #expect(R.desktopBuildOf(release("v2.3.0-b1", installers("2.3.0-b1")), versionsText: nil) == .init(version: "2.3.0-b1", source: .tag))
    }

    @Test func desktopBuildUsesVersionsJsonWhenCarriedOver() {
        let carried = release("v2.3.2", installers("2.3.1") + ["Cascade-2.3.2.apk", "versions.json"])
        #expect(R.desktopBuildOf(carried, versionsText: #"{"desktop":"2.3.1","apple":"2.3.1","android":"2.3.2"}"#)
                == .init(version: "2.3.1", source: .versionsFile))
    }

    @Test func carryOverWithoutAReadableFileOffersNothing() {
        // v2.3.2 holding desktop 2.3.1 must never read as desktop 2.3.2.
        let carried = release("v2.3.2", installers("2.3.1") + ["versions.json"])
        for text in [nil, "", "garbage", #"{"desktop":"2.3"}"#, #"{"desktop":"9.9.9"}"#] as [String?] {
            #expect(R.desktopBuildOf(carried, versionsText: text) == nil, "\(String(describing: text))")
        }
    }

    @Test func noDesktopBuildInAReleaseForAnotherPlatform() {
        #expect(R.desktopBuildOf(release("v2.3.2-b1", ["Cascade-2.3.2-b1.apk", "versions.json"]), versionsText: #"{"android":"2.3.2-b1"}"#) == nil)
        #expect(R.desktopBuildOf(release("v2.3.2", installers("2.3.2")), versionsText: #"{"apple":"2.3.2"}"#) == nil)
    }

    @Test func aBadFileFallsBackToTheTagOnlyForDesktop() {
        let r = release("v2.3.2", installers("2.3.2") + ["versions.json"])
        #expect(R.desktopBuildOf(r, versionsText: #"{"desktop":"#) == .init(version: "2.3.2", source: .tag))
    }

    @Test func aTagThatIsNotAVersionIsIgnored() {
        #expect(R.desktopBuildOf(release("models-2026", ["Cascade-models-2026.dmg"]), versionsText: nil) == nil)
        #expect(R.desktopBuildOf(R.Release(tag: nil, assets: installers("2.2.0").map { R.Asset(name: $0) }), versionsText: nil) == nil)
        #expect(R.desktopBuildOf(release("v2.2.0/../../x", ["Cascade-2.2.0/../../x.dmg"]), versionsText: nil) == nil)
    }

    // MARK: The native Mac build

    @Test func macBuildNeedsTheFileAndAMatchingNativeDmg() {
        let r = release("v2.4.0", installers("2.4.0") + ["Cascade-Native-2.4.0.dmg", "versions.json"])
        #expect(R.macBuildOf(r, versionsText: #"{"desktop":"2.4.0","mac":"2.4.0"}"#) == .init(version: "2.4.0", source: .versionsFile))
        // No tag guess: there never was a native build before versions.json had a mac key.
        #expect(R.macBuildOf(r, versionsText: nil) == nil)
        #expect(R.macBuildOf(r, versionsText: #"{"desktop":"2.4.0"}"#) == nil)
        // A file claiming a version the release does not contain.
        #expect(R.macBuildOf(r, versionsText: #"{"mac":"9.9.9"}"#) == nil)
        // The Electron DMG is not a native one, whatever the version.
        let electronOnly = release("v2.4.0", installers("2.4.0") + ["versions.json"])
        #expect(R.macBuildOf(electronOnly, versionsText: #"{"mac":"2.4.0"}"#) == nil)
    }

    @Test func macAndDesktopVersionsCanDiffer() {
        let r = release("v2.4.1", installers("2.4.0") + ["Cascade-Native-2.4.1.dmg", "versions.json"])
        let text = #"{"desktop":"2.4.0","mac":"2.4.1"}"#
        #expect(R.macBuildOf(r, versionsText: text)?.version == "2.4.1")
        #expect(R.desktopBuildOf(r, versionsText: text)?.version == "2.4.0")
    }

    @Test func nativeInstallerIsPickedByNameAndVersion() {
        let r = release("v2.4.1", installers("2.4.0") + ["Cascade-Native-2.4.1.dmg", "Cascade-Native-2.4.0.dmg"])
        #expect(R.pickNativeInstaller(r, version: "2.4.1")?.name == "Cascade-Native-2.4.1.dmg")
        #expect(R.pickNativeInstaller(r, version: "2.4.2") == nil)
        // The Electron DMG never matches, even though it carries the version.
        #expect(R.pickNativeInstaller(release("v2.4.0", installers("2.4.0")), version: "2.4.0") == nil)
    }

    @Test func electronMacInstallerIsTheArm64DmgAndNeverTheNativeOne() {
        // The old updaters' rule: the first .dmg with arm64 in its name. The native
        // DMG has none, which is the whole point of its name.
        let r = release("v2.4.0", ["Cascade-Native-2.4.0.dmg", "Cascade-2.4.0.dmg", "Cascade-2.4.0-arm64.dmg"])
        #expect(R.pickElectronMacInstaller(r, version: "2.4.0")?.name == "Cascade-2.4.0-arm64.dmg")
        #expect(R.pickElectronMacInstaller(release("v2.4.0", ["Cascade-Native-2.4.0.dmg"]), version: "2.4.0") == nil)
        #expect(R.pickElectronMacInstaller(r, version: "2.3.0") == nil)
        // 2.0.x shipped an unsuffixed x64 dmg too; Apple Silicon must get arm64.
        let old = release("v2.0.1", installers("2.0.1") + ["Cascade-2.0.1.dmg"])
        #expect(R.pickElectronMacInstaller(old, version: "2.0.1")?.name == "Cascade-2.0.1-arm64.dmg")
    }

    @Test func releaseReadsGitHubJSONAndDropsMalformedAssets() throws {
        let json = #"""
        {"tag_name":"v2.4.0","body":"notes","html_url":"https://github.com/x/y/releases/v2.4.0","published_at":"2026-10-05T00:00:00Z",
         "assets":[{"name":"Cascade-Native-2.4.0.dmg","browser_download_url":"https://x/y.dmg","size":123,"digest":"sha256:abc"},
                   null, 7, {"name":3}, {"name":"versions.json"}]}
        """#
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let release = try #require(R.Release(json: object))
        #expect(release.tag == "v2.4.0")
        #expect(release.assets.map(\.name) == ["Cascade-Native-2.4.0.dmg", "versions.json"])
        #expect(release.assets[0].digest == "sha256:abc")
        #expect(release.assets[0].size == 123)
        #expect(R.Release(json: [1, 2]) == nil)
    }
}
