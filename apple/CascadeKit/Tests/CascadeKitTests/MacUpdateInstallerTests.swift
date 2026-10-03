#if os(macOS)
import Foundation
import Testing
@testable import CascadeKit

/// The installer against throwaway app bundles in a scratch directory. Nothing
/// here touches /Applications or any real install: the "installed app" is a
/// fake bundle in a temp folder, the update a DMG built on the spot, and the
/// relaunch command is /usr/bin/true.
@Suite(.serialized) struct MacUpdateInstallerTests {
    private let fm = FileManager.default

    private func scratch() throws -> URL {
        let dir = fm.temporaryDirectory.appending(path: "cascade-installer-test-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A minimal bundle: an Info.plist and a copy of a tiny system executable,
    /// ad-hoc signed like the real app (or not, to see the check refuse it).
    private func makeApp(in dir: URL, name: String = "Fake", id: String = "xyz.test.fake", version: String,
                         sign: Bool = true) async throws -> URL {
        let app = dir.appending(path: "\(name).app")
        try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                                    "CFBundleExecutable": "Fake", "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appending(path: "Contents/MacOS/Fake"))
        if sign { try await MacUpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
        return app
    }

    private func makeDMG(containing apps: [URL], in dir: URL) async throws -> URL {
        let folder = dir.appending(path: "dmg-src-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for app in apps { try await MacUpdateInstaller.run("/usr/bin/ditto", [app.path, folder.appending(path: app.lastPathComponent).path]) }
        let dmg = dir.appending(path: "update-\(UUID().uuidString.prefix(6)).dmg")
        try await MacUpdateInstaller.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", folder.path, "-format", "UDRO", "-volname", "Update", dmg.path])
        return dmg
    }

    private func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    /// A process id that is certainly gone, so the swap script does not wait.
    private func deadPid() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    private func hiddenLeftovers(in dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".") && $0.hasSuffix(".app") }
    }

    /// One test for everything that needs a real DMG, because building and
    /// mounting one costs seconds each: three DMGs serve every scenario.
    @Test func checksTheUpdateThenSwapsItInPlace() async throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let installedDir = dir.appending(path: "apps")
        let old = try await makeApp(in: installedDir, version: "1.0.0")
        let good = try await makeDMG(containing: [try await makeApp(in: dir.appending(path: "good"), version: "2.0.0")], in: dir)
        let unsigned = try await makeDMG(containing: [try await makeApp(in: dir.appending(path: "unsigned"), version: "2.0.0", sign: false)], in: dir)
        let two = try await makeDMG(containing: [try await makeApp(in: dir.appending(path: "a"), name: "A", version: "2.0.0"),
                                                 try await makeApp(in: dir.appending(path: "b"), name: "B", version: "2.0.0")], in: dir)

        func install(_ dmg: URL, into app: URL, version: String, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> (process: Process, logPath: URL) {
            try await MacUpdateInstaller.installInPlace(dmgPath: dmg, appBundle: app, expectedVersion: version,
                                                        pid: try deadPid(), tempDirectory: dir, openCommand: "/usr/bin/true", log: log)
        }
        func refusal(_ dmg: URL, into app: URL, version: String) async -> String? {
            do { _ = try await install(dmg, into: app, version: version); return nil }
            catch let failure as MacUpdateInstaller.Failure { return failure.message }
            catch { return "\(error)" }
        }

        // Each refusal leaves the installed app as it was, with no staged copy beside it.
        #expect(await refusal(good, into: old, version: "2.1.0")?.contains("version") == true)
        #expect(await refusal(unsigned, into: old, version: "2.0.0") != nil)
        #expect(await refusal(two, into: old, version: "2.0.0")?.contains("expected one app") == true)
        let stranger = try await makeApp(in: dir.appending(path: "stranger"), name: "Stranger", id: "xyz.someone.else", version: "1.0.0")
        #expect(await refusal(good, into: stranger, version: "2.0.0")?.contains("bundle id") == true)
        #expect(version(of: old) == "1.0.0")
        #expect(hiddenLeftovers(in: installedDir).isEmpty)

        // And the good one installs.
        let lines = LockedLines()
        let result = try await install(good, into: old, version: "2.0.0") { lines.add($0) }
        result.process.waitUntilExit()
        #expect(result.process.terminationStatus == 0)
        #expect(version(of: old) == "2.0.0")
        // The swap leaves no staged copy or backup next to the app.
        #expect(hiddenLeftovers(in: installedDir).isEmpty)
        let log = try String(contentsOf: result.logPath, encoding: .utf8)
        #expect(log.contains("installed"))
        #expect(result.logPath.lastPathComponent == "fake-update.log")
        #expect(lines.all.contains { $0.hasPrefix("Checking") })
        // The mount point is gone too.
        #expect(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains("update-mount") }.isEmpty)
    }

    @Test func refusesAnAppThatCannotBeSwappedInPlace() async throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let dmg = dir.appending(path: "never-opened.dmg")
        func message(for bundle: URL) async -> String? {
            do {
                try await MacUpdateInstaller.installInPlace(dmgPath: dmg, appBundle: bundle, expectedVersion: "2.0.0", pid: 1, tempDirectory: dir)
                return nil
            } catch let failure as MacUpdateInstaller.Failure { return failure.message } catch { return "\(error)" }
        }
        #expect(await message(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Cascade.app"))?.contains("temporary copy") == true)
        #expect(await message(for: URL(fileURLWithPath: "/Volumes/Cascade/Cascade.app"))?.contains("disk image") == true)
        #expect(await message(for: URL(fileURLWithPath: "/Applications/Cascade"))?.contains("not running from an app bundle") == true)

        // A folder this account cannot write to.
        let locked = dir.appending(path: "locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let app = try await makeApp(in: locked, version: "1.0.0")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(await message(for: app)?.contains("cannot write") == true)
    }

    @Test func theSwapScriptPutsTheOldAppBackWhenTheNewOneCannotMoveIn() throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let target = dir.appending(path: "Target.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appending(path: "marker"))
        let staged = dir.appending(path: ".Target-update.app")   // never created: the move into place fails
        let backup = dir.appending(path: ".Target-previous.app")
        let log = dir.appending(path: "swap.log")
        let p = try MacUpdateInstaller.startSwap(pid: deadPid(), target: target, staged: staged, backup: backup,
                                                 scriptPath: dir.appending(path: "swap.sh"), logPath: log, openCommand: "/usr/bin/true")
        p.waitUntilExit()
        #expect(try String(contentsOf: target.appending(path: "marker"), encoding: .utf8) == "old")
        #expect(!fm.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: log, encoding: .utf8).contains("restoring the old one"))
    }

    @Test func theSwapScriptWaitsForTheRunningAppToQuit() async throws {
        let dir = try scratch()
        defer { try? fm.removeItem(at: dir) }
        let target = dir.appending(path: "Target.app")
        let staged = dir.appending(path: ".Target-update.app")
        for (url, text) in [(target, "old"), (staged, "new")] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url.appending(path: "marker"))
        }
        // A stand-in for the running app: a process that exits after a moment.
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["1"]
        try app.run()
        let p = try MacUpdateInstaller.startSwap(pid: app.processIdentifier, target: target, staged: staged,
                                                 backup: dir.appending(path: ".Target-previous.app"),
                                                 scriptPath: dir.appending(path: "swap.sh"), logPath: dir.appending(path: "swap.log"),
                                                 openCommand: "/usr/bin/true")
        try await Task.sleep(for: .milliseconds(300))
        // Still waiting: nothing has moved while the app runs.
        #expect(try String(contentsOf: target.appending(path: "marker"), encoding: .utf8) == "old")
        app.waitUntilExit()
        p.waitUntilExit()
        #expect(try String(contentsOf: target.appending(path: "marker"), encoding: .utf8) == "new")
    }
}

/// Collects the installer's progress lines from its @Sendable callback.
private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
#endif
