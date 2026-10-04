import Foundation
import CascadeKit

/// Where the app meets the Electron settings file: finds it, runs the one-shot
/// import at launch, and writes settings back for "Switch back to the Electron
/// build". The mapping itself is CascadeKit's ElectronSettingsImport.
///
/// The installed app's real config.json holds a real token for a real server,
/// so a DEBUG build never goes near it by default: it only reads or writes a
/// file it is explicitly pointed at, with `CASCADE_ELECTRON_CONFIG` in the
/// environment or `-cascade.electronConfig <path>` on the command line. A
/// release build uses the real path unless pointed elsewhere.
@MainActor
enum MacSettingsImport {
    /// The file to read and write, or nil when this build must not touch any.
    static var configURL: URL? {
        if let path = ProcessInfo.processInfo.environment["CASCADE_ELECTRON_CONFIG"]
            ?? UserDefaults.standard.string(forKey: "cascade.electronConfig"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #if DEBUG
        return nil
        #else
        return ElectronSettingsImport.defaultConfigURL
        #endif
    }

    /// First launch: bring the Electron app's settings in, once. Runs before
    /// AppState restores its session, so the imported token, server and device
    /// id are what it finds.
    static func runOnce() {
        guard let url = configURL else { return }
        let outcome = ElectronSettingsImport.runOnce(configURL: url, defaults: .standard) { Keychain.set($0, for: "token") }
        if case .imported(let applied, let rejected) = outcome {
            print("[import] \(applied) settings from \(url.lastPathComponent)" + (rejected.isEmpty ? "" : ", skipped \(rejected.joined(separator: ", "))"))
        }
    }

    enum WriteBack: Equatable {
        case written(URL)
        /// A debug build with no explicit file: nothing was written, on purpose.
        case notAllowed
    }

    /// Writes this app's settings over the Electron file's, keeping every key
    /// the table does not own. Reads the file first (or starts one) so keys
    /// from a newer Electron survive. Throws on a file that exists but cannot
    /// be read, rather than replacing something it does not understand.
    static func writeBack() throws -> WriteBack {
        guard let url = configURL else { return .notAllowed }
        let existing: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) { existing = try ElectronSettingsImport.read(url) } else { existing = [:] }
        let merged = ElectronSettingsImport.export(nativeValue: { UserDefaults.standard.object(forKey: $0) },
                                                   token: Keychain.get("token"), into: existing)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ElectronSettingsImport.write(merged, to: url)
        return .written(url)
    }
}
