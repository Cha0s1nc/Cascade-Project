#if os(macOS)
import Foundation

/// Installs a downloaded macOS update in place: the new .app replaces the
/// running one and relaunches, instead of leaving a DMG open to drag. A port
/// of the desktop's mac-update.js, which both Cascade and Cha0s Stream share.
///
/// Apple's own updater (Sparkle, Squirrel.Mac) wants a Developer ID signature,
/// and both apps are ad-hoc signed on purpose, so this does the same job by
/// hand:
///
///  1. Mount the DMG out of sight and copy the new .app into a staging bundle
///     beside the installed one. Same directory, so the final swap is a
///     rename on one volume, not a copy that a quit could interrupt halfway.
///  2. Check the staged copy before touching anything: its signature
///     verifies, its bundle id is the app's own, and its version is the one
///     being installed.
///  3. Hand off to a small shell script and quit. The script waits for this
///     process to exit, moves the old app aside, moves the new one into place,
///     deletes the old one and relaunches. If moving the new one in fails, it
///     puts the old app back, so a failed update never leaves no app at all.
///
/// Anything that makes an in-place swap unsafe throws before step 3 and the
/// caller falls back to opening the DMG: running from the DMG itself or from
/// macOS's read-only App Translocation copy, a folder this account cannot
/// write to, or a staged copy that fails its checks.
///
/// What this does not do is re-run Gatekeeper. Files the app downloads itself
/// are not quarantined, so macOS does not re-assess the new version; trust
/// rests on the HTTPS download and the release digest checked before this
/// runs. That catches corruption, not a malicious release uploaded to the repo.
///
/// The same installer moves a user in either direction between the Electron
/// and native builds: both carry the bundle id xyz.chaosinc.cascade, which is
/// the only identity check here.
public enum MacUpdateInstaller {
    public struct Failure: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    /// The script that performs the swap once the app has quit. POSIX sh and
    /// stock macOS tools. It gives up after a minute if the app never exits,
    /// leaving the installed app untouched. $6 is the relaunch command, `open`
    /// outside tests. Ignores a hangup so closing whatever started it cannot
    /// stop a swap halfway.
    static let swapScript = """
    #!/bin/sh
    trap '' HUP
    PID="$1"; TARGET="$2"; STAGED="$3"; BACKUP="$4"; LOG="$5"; OPEN="${6:-/usr/bin/open}"
    exec >>"$LOG" 2>&1
    echo "$(date) waiting for pid $PID to quit"
    tries=0
    while kill -0 "$PID" 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -gt 300 ]; then
        echo "gave up waiting; update not applied"
        rm -rf "$STAGED"
        exit 1
      fi
      sleep 0.2
    done
    rm -rf "$BACKUP"
    if mv "$TARGET" "$BACKUP"; then
      if mv "$STAGED" "$TARGET"; then
        rm -rf "$BACKUP"
        echo "installed $TARGET"
      else
        echo "could not move the new app into place; restoring the old one"
        mv "$BACKUP" "$TARGET"
        rm -rf "$STAGED"
      fi
    else
      echo "could not move the old app aside; update not applied"
      rm -rf "$STAGED"
    fi
    "$OPEN" "$TARGET"
    """

    /// Runs a tool and returns its trimmed stdout, or throws with its stderr.
    @discardableResult
    static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = args
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    continuation.resume(throwing: Failure("\((tool as NSString).lastPathComponent) failed: \(error.localizedDescription)"))
                    return
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let why = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure("\((tool as NSString).lastPathComponent) failed: \(why.isEmpty ? "status \(process.terminationStatus)" : why)"))
                }
            }
        }
    }

    private static func plistString(_ bundle: URL, _ key: String) throws -> String {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let value = (object as? [String: Any])?[key] as? String else {
            throw Failure("could not read \(key) from \(plist.path)")
        }
        return value
    }

    /// Checks that apply before anything is copied: a bundle that can be
    /// swapped in place at all.
    static func checkInstallable(_ appBundle: URL) throws {
        let path = appBundle.path
        guard appBundle.pathExtension == "app" else { throw Failure("not running from an app bundle (\(path))") }
        let name = appBundle.deletingPathExtension().lastPathComponent
        if path.contains("/AppTranslocation/") {
            throw Failure("\(name) is running from a temporary copy macOS made; move it to Applications first")
        }
        if path.hasPrefix("/Volumes/") { throw Failure("\(name) is running from a mounted disk image") }
        let parent = appBundle.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent) { throw Failure("this account cannot write to \(parent)") }
    }

    /// Starts the swap script. Returns the process so a caller that wants to
    /// can wait on it; the app itself just quits, and the script outlives it.
    @discardableResult
    static func startSwap(pid: Int32, target: URL, staged: URL, backup: URL, scriptPath: URL, logPath: URL,
                          openCommand: String) throws -> Process {
        try Data(swapScript.utf8).write(to: scriptPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath.path, String(pid), target.path, staged.path, backup.path, logPath.path, openCommand]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Stages, checks and hands off. Throws before the hand-off on anything
    /// unsafe, leaving the installed app untouched, and the caller opens the
    /// DMG instead.
    ///
    /// - Parameters:
    ///   - dmgPath: the downloaded, digest-verified DMG.
    ///   - appBundle: the running app, e.g. /Applications/Cascade.app.
    ///   - expectedVersion: the version the DMG must contain, e.g. "2.4.0".
    ///   - pid: the process the swap waits on.
    ///   - tempDirectory: where the mount point, script and log go ($TMPDIR).
    ///   - openCommand: what relaunches the app; a test replaces it.
    /// - Returns: the swap script's process and its log's path, once it is running.
    @discardableResult
    public static func installInPlace(dmgPath: URL, appBundle: URL, expectedVersion: String, pid: Int32,
                                      tempDirectory: URL = FileManager.default.temporaryDirectory,
                                      openCommand: String = "/usr/bin/open",
                                      log: @Sendable (String) -> Void = { _ in }) async throws -> (process: Process, logPath: URL) {
        try checkInstallable(appBundle)
        let name = appBundle.deletingPathExtension().lastPathComponent
        // For temp file names only: "Cha0s Stream" -> "cha0s-stream".
        let slug = name.lowercased().replacing(/[^a-z0-9]+/, with: "-")
        let parent = appBundle.deletingLastPathComponent()

        // The update must carry the running app's own bundle id, read from the
        // app itself rather than assumed.
        let bundleId = try plistString(appBundle, "CFBundleIdentifier")

        let staged = parent.appending(path: ".\(name)-update-\(expectedVersion).app")
        let backup = parent.appending(path: ".\(name)-previous.app")
        let mount = tempDirectory.appending(path: "\(slug)-update-mount-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        try? fm.removeItem(at: staged)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)

        do {
            log("Opening the downloaded update\u{2026}")
            try await run("/usr/bin/hdiutil", ["attach", dmgPath.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            do {
                let found = ((try? fm.contentsOfDirectory(atPath: mount.path)) ?? []).filter { $0.hasSuffix(".app") }
                guard found.count == 1 else { throw Failure("expected one app in the update, found \(found.count)") }
                log("Copying the new version\u{2026}")
                // ditto keeps permissions, symlinks and extended attributes,
                // all of which a signed bundle depends on.
                try await run("/usr/bin/ditto", [mount.appending(path: found[0]).path, staged.path])
            } catch {
                _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
                try? fm.removeItem(at: mount)
                throw error
            }
            _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)

            log("Checking the new version\u{2026}")
            try await run("/usr/bin/codesign", ["--verify", "--strict", staged.path])
            let gotId = try plistString(staged, "CFBundleIdentifier")
            let gotVersion = try plistString(staged, "CFBundleShortVersionString")
            if gotId != bundleId { throw Failure("update has bundle id \(gotId), expected \(bundleId)") }
            if gotVersion != expectedVersion { throw Failure("update contains version \(gotVersion), expected \(expectedVersion)") }
        } catch {
            try? fm.removeItem(at: staged)
            try? fm.removeItem(at: mount)
            throw error
        }

        let scriptPath = tempDirectory.appending(path: "\(slug)-update-\(pid).sh")
        let logPath = tempDirectory.appending(path: "\(slug)-update.log")
        let process = try startSwap(pid: pid, target: appBundle, staged: staged, backup: backup,
                                    scriptPath: scriptPath, logPath: logPath, openCommand: openCommand)
        log("Installing v\(expectedVersion) and restarting\u{2026}")
        return (process, logPath)
    }
}
#endif
