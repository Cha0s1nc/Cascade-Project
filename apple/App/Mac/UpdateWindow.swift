import SwiftUI
import AppKit
import CryptoKit
import CascadeKit

// The Mac updater: checks GitHub for a newer native build, shows the Update
// Available window, downloads with a checksum, and hands to MacUpdateInstaller.
// The Electron app's checkForUpdates and updater.html, ported. The same service
// runs "Switch back to the Electron build", which downloads Electron's DMG and
// swaps through the same installer.

@MainActor
@Observable
final class UpdateService {
    static let shared = UpdateService()
    static let repo = "Cha0s1nc/Cascade-Project"
    static let changelogUrl = "https://www.chaosinc.xyz/github/projects/cascade/changelog.json"

    enum Kind { case update, switchBack }

    struct Offer {
        var kind: Kind
        var version: String
        var current: String
        var notes: String
        var released: Date?
        var releaseUrl: URL?
        var asset: UpdateRelease.Asset?
    }

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(String)
        case failed(String)
    }

    enum Phase: Equatable {
        case ready
        case downloading(done: Int64, total: Int64, rate: Double)
        case downloaded
        case installing
        /// Installing in place did not work or was not tried: the DMG is open
        /// (or the release page is) for the user to finish by hand.
        case manual
        case failed(String)
    }

    struct LogLine: Identifiable {
        enum Level { case plain, info, ok, error }
        let id = UUID()
        var text: String
        var level: Level
        var time = Date()
    }

    private(set) var status: Status = .idle
    private(set) var offer: Offer?
    private(set) var phase: Phase = .ready
    private(set) var log: [LogLine] = []
    /// Bumped to ask the app to show the window; the opener view watches it.
    private(set) var showRequest = 0
    private var downloaded: URL?

    // MARK: Settings

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Whether beta releases count. Defaults on for a beta build itself, so it
    /// keeps finding newer betas, unless the user chose otherwise; that choice
    /// always wins. Without this a beta user is only ever offered stable
    /// releases, since GitHub's "latest" never includes a prerelease.
    var betaChannel: Bool {
        (UserDefaults.standard.object(forKey: "cascade.betaUpdates") as? Bool)
            ?? (currentVersion.range(of: "-b[0-9]*$", options: .regularExpression) != nil)
    }

    // MARK: Checking

    /// A few seconds after launch, like the Electron app. A debug build never
    /// checks on its own: it would be comparing a development version to real
    /// releases.
    func checkOnLaunch() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "cascade.updatePreview") { preview() }
        #else
        Task {
            try? await Task.sleep(for: .seconds(5))
            await check(manual: false)
        }
        #endif
    }

    private func get(_ url: URL, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("cascade-updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) from \(url.host() ?? "the server")")
        }
        return data
    }

    struct UpdateError: Error, LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The releases to consider, newest first. Stable reads GitHub's "latest";
    /// the beta channel reads the recent releases, drafts out.
    private func candidates() async throws -> [UpdateRelease.Release] {
        let base = "https://api.github.com/repos/\(Self.repo)/releases"
        if betaChannel {
            let data = try await get(URL(string: base + "?per_page=10")!)
            let list = (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
            return list.compactMap { raw in
                (raw as? [String: Any])?["draft"] as? Bool == true ? nil : UpdateRelease.Release(json: raw)
            }
        }
        let data = try await get(URL(string: base + "/latest")!)
        return [UpdateRelease.Release(json: try JSONSerialization.jsonObject(with: data))].compactMap { $0 }
    }

    /// The release's versions.json as text, or nil when it has none or it could
    /// not be read. Its contents are checked by UpdateRelease, not here.
    private func versionsText(_ release: UpdateRelease.Release) async -> String? {
        guard let asset = UpdateRelease.findVersionsAsset(release), let raw = asset.url, let url = URL(string: raw) else { return nil }
        if let size = asset.size, size > UpdateRelease.versionsMaxBytes { return nil }
        guard let data = try? await get(url), data.count <= UpdateRelease.versionsMaxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The first release holding a build of this kind. The beta channel walks on
    /// past a release with none (a beta made for another platform only).
    private func newestBuild(_ kind: UpdateRelease.Kind) async throws -> (UpdateRelease.Release, UpdateRelease.Build)? {
        for release in try await candidates() {
            if let build = UpdateRelease.buildOf(kind, release: release, versionsText: await versionsText(release)) {
                return (release, build)
            }
        }
        return nil
    }

    /// Every changelog section for the Mac after this version up to the one on
    /// offer. The website's changelog.json first, then CHANGELOG.md at the
    /// release's tag, then the release's own notes. Betas are not in the
    /// changelog, so a beta shows its release notes.
    private func notes(for release: UpdateRelease.Release, version: String) async -> String {
        let fallback = release.body
        guard version.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil else { return fallback }
        let tag = release.tag?.wholeMatch(of: /v[0-9]+\.[0-9]+\.[0-9]+/) != nil ? release.tag! : "stable"
        let sources: [(String, () async throws -> [Changelog.Entry]?)] = [
            ("website", { Changelog.fromJSON(try await self.get(URL(string: Self.changelogUrl)!, timeout: 8)) }),
            ("GitHub", {
                let data = try await self.get(URL(string: "https://raw.githubusercontent.com/\(Self.repo)/\(tag)/CHANGELOG.md")!, timeout: 8)
                return try Changelog.parse(String(decoding: data, as: UTF8.self))
            }),
        ]
        for (name, load) in sources {
            do {
                guard let entries = try await load() else { throw UpdateError("malformed") }
                // nil: this copy predates the release (the website lags a
                // publish), so try the next one. Empty: it knows the release
                // but has nothing for the Mac in the range.
                guard let text = Changelog.notesBetween(entries, platform: .mac, current: currentVersion, target: version) else {
                    throw UpdateError("does not list \(version) yet")
                }
                return text.isEmpty ? fallback : text
            } catch {
                print("[updater] Changelog from the \(name) unavailable: \(error.localizedDescription)")
            }
        }
        return fallback
    }

    private static func date(_ iso: String?) -> Date? { iso.flatMap { ISO8601DateFormatter().date(from: $0) } }

    func check(manual: Bool) async {
        guard status != .checking else { return }
        status = .checking
        do {
            guard let (release, build) = try await newestBuild(.mac),
                  UpdateRelease.isNewerVersion(build.version, than: currentVersion) else {
                status = .upToDate
                return
            }
            print("[updater] \(release.tag ?? "?") holds native Mac \(build.version) (from \(build.source.rawValue))")
            offer = Offer(kind: .update, version: build.version, current: currentVersion,
                          notes: await notes(for: release, version: build.version), released: Self.date(release.publishedAt),
                          releaseUrl: release.htmlUrl.flatMap(URL.init(string:)),
                          asset: UpdateRelease.pickNativeInstaller(release, version: build.version))
            status = .available(build.version)
            present()
        } catch {
            print("[updater] Check failed: \(error.localizedDescription)")
            status = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    /// "Switch back to the Electron build": the newest Electron release's Mac
    /// DMG, offered whether or not it is newer than this app's version.
    func prepareSwitchBack() async {
        guard status != .checking else { return }
        status = .checking
        do {
            guard let (release, build) = try await newestBuild(.desktop) else { throw UpdateError("No Electron release was found.") }
            guard let asset = UpdateRelease.pickElectronMacInstaller(release, version: build.version) else {
                throw UpdateError("The latest release has no Electron installer for the Mac.")
            }
            offer = Offer(kind: .switchBack, version: build.version, current: currentVersion, notes: "",
                          released: Self.date(release.publishedAt), releaseUrl: release.htmlUrl.flatMap(URL.init(string:)), asset: asset)
            status = .idle
            present()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    /// A made-up offer with nothing to download, for looking at the window.
    func preview() {
        offer = Offer(kind: .update, version: "99.0.0", current: currentVersion,
                      notes: "## 99.0.0 (2026-10-05)\n\n### Mac\n- Updater window preview.\n  - Nothing is downloaded or installed.\n- **Bold**, *italic*, `code` and a [link](https://github.com/Cha0s1nc/Cascade-Project).",
                      released: Date(), releaseUrl: URL(string: "https://github.com/\(Self.repo)/releases"), asset: nil)
        status = .available("99.0.0")
        present()
    }
    #endif

    private func present() {
        phase = .ready
        log = [LogLine(text: offer.map { $0.kind == .update ? "Update available: v\($0.current) to v\($0.version)" : "Electron build: v\($0.version)" } ?? "",
                       level: .info)]
        downloaded = nil
        showRequest += 1
    }

    func say(_ text: String, _ level: LogLine.Level = .plain) { log.append(LogLine(text: text, level: level)) }

    // MARK: Downloading

    private func safeName(_ name: String) -> String {
        String((name as NSString).lastPathComponent.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
    }

    func download() async {
        guard let offer else { return }
        guard let asset = offer.asset, let raw = asset.url, let url = URL(string: raw), url.scheme == "https" else {
            say("This release has no installer for this computer, so the release page is opening instead.", .error)
            if let page = offer.releaseUrl { NSWorkspace.shared.open(page) }
            phase = .manual
            return
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "cascade-update-\(safeName(asset.name))")
        say("Downloading to \(destination.path)...")
        phase = .downloading(done: 0, total: Int64(asset.size ?? 0), rate: 0)
        do {
            let downloader = FileDownloader { [weak self] done, total, rate in
                Task { @MainActor in
                    guard let self else { return }
                    self.phase = .downloading(done: done, total: total, rate: rate)
                }
            }
            try await downloader.download(url, to: destination)
            if let digest = asset.digest {
                let ok = try await Self.verify(destination, digest: digest)
                guard ok else {
                    try? FileManager.default.removeItem(at: destination)
                    throw UpdateError("Downloaded file failed integrity verification. It may have been corrupted or tampered with in transit.")
                }
            } else {
                say("GitHub published no checksum for this file, so it could not be verified.", .error)
            }
            downloaded = destination
            phase = .downloaded
            say("v\(offer.version) downloaded successfully. Ready to install.", .ok)
        } catch {
            phase = .failed("Download failed: \(error.localizedDescription)")
            say("Error: Download failed: \(error.localizedDescription)", .error)
        }
    }

    /// Whether the file's sha256 matches GitHub's "sha256:<hex>" digest. Read in
    /// chunks off the main thread: the DMG is over a hundred megabytes.
    nonisolated static func verify(_ file: URL, digest: String) async throws -> Bool {
        let parts = digest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return false }
        return try await Task.detached {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined() == parts[1].lowercased()
        }.value
    }

    // MARK: Installing

    /// How long the in-place install may take before falling back to the DMG.
    private static let installTimeout: Duration = .seconds(60)

    private actor Once {
        private var claimed = false
        func claim() -> Bool { defer { claimed = true }; return !claimed }
    }

    func install() async {
        guard let offer, let dmg = downloaded else {
            say("Nothing has been downloaded to install, so the release page is opening instead.", .error)
            if let page = offer?.releaseUrl { NSWorkspace.shared.open(page) }
            phase = .manual
            return
        }
        phase = .installing
        say("Installing...", .info)

        if offer.kind == .switchBack {
            do {
                switch try MacSettingsImport.writeBack() {
                case .written(let url): say("Saved your settings to \(url.lastPathComponent) for the Electron build.")
                case .notAllowed: say("Debug build: settings were not written to the Electron file.")
                }
            } catch {
                // Not fatal to the switch, but said plainly: the Electron app
                // will come up with whatever it had before.
                say("Could not save your settings for the Electron build (\(error.localizedDescription)).", .error)
            }
        }

        #if DEBUG
        // A debug build lives in DerivedData and must never swap itself, or
        // anything else, in place.
        say("Debug build: the in-place install is skipped.", .info)
        phase = .manual
        return
        #else
        let bundle = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            let once = Once()
            Task {
                let result: Result<Void, Error>
                do {
                    _ = try await MacUpdateInstaller.installInPlace(dmgPath: dmg, appBundle: bundle, expectedVersion: offer.version, pid: pid) { line in
                        Task { @MainActor in UpdateService.shared.say(line) }
                    }
                    result = .success(())
                } catch { result = .failure(error) }
                if await once.claim() { continuation.resume(returning: result) }
            }
            Task {
                // A hung hdiutil or ditto should cost a minute, not leave
                // "Installing" on screen for good. If the install does finish
                // after that, its swap script waits up to a minute for this app
                // to quit and then gives up, leaving the installed app as it was.
                try? await Task.sleep(for: Self.installTimeout)
                if await once.claim() { continuation.resume(returning: .failure(UpdateError("it took over a minute"))) }
            }
        }
        switch outcome {
        case .success:
            say("Quitting so the update can be applied.", .info)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            // A quit something blocks would leave the swap script waiting
            // until it gives up, so stop asking after a while.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
        case .failure(let error):
            print("[updater] In-place update failed, opening the installer: \(error.localizedDescription)")
            say("Could not update in place (\(error.localizedDescription)). Opening the installer instead.", .error)
            NSWorkspace.shared.open(dmg)
            say("Opened the installer. Drag Cascade into Applications to finish.", .info)
            phase = .manual
        }
        #endif
    }
}

/// A download to a file with progress, on its own URLSession so the delegate
/// sees it. A connection that goes quiet for a minute fails, rather than the
/// bar just stopping.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (_ done: Int64, _ total: Int64, _ bytesPerSecond: Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var session: URLSession?
    private var lastTime = Date()
    private var lastBytes: Int64 = 0

    init(onProgress: @escaping @Sendable (Int64, Int64, Double) -> Void) { self.onProgress = onProgress }

    func download(_ url: URL, to destination: URL) async throws {
        self.destination = destination
        var request = URLRequest(url: url)
        request.setValue("cascade-updater", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            session.downloadTask(with: request).resume()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Twice a second at most, as the Electron window does, with the speed
        // over that half second. Delegate callbacks come in on one serial queue.
        let now = Date(), elapsed = now.timeIntervalSince(lastTime)
        let total = max(0, totalBytesExpectedToWrite)
        guard elapsed >= 0.5 || (total > 0 && totalBytesWritten >= total) else { return }
        let rate = elapsed > 0 ? Double(totalBytesWritten - lastBytes) / elapsed : 0
        lastTime = now
        lastBytes = totalBytesWritten
        onProgress(totalBytesWritten, total, rate)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200, let destination else {
            return finish(.failure(UpdateService.UpdateError("HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)")))
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - The window

struct UpdateAvailableView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private let service = UpdateService.shared

    var body: some View {
        if let offer = service.offer {
            content(offer)
        } else {
            VStack(spacing: 8) {
                Text("No update").font(.headline)
                Text("Check for updates in Settings > About.").foregroundStyle(.secondary)
            }
            .frame(width: 520, height: 200)
        }
    }

    private func content(_ offer: UpdateService.Offer) -> some View {
        let switching = offer.kind == .switchBack
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(switching ? "Switch to the Electron Build" : "Update Available").font(.title2.bold())
                        if let date = offer.released {
                            Text("Released \(date.formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    versionBlock("Current", "v\(offer.current)", .secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    versionBlock(switching ? "Electron" : "New", "v\(offer.version)", .primary)
                    Spacer()
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 14)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if switching {
                    Text("This replaces the Mac app with the Electron build and carries your settings across. Your library, playlists on the server and sign-in stay as they are. You can switch to the native app again from the Electron build's Settings.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("What's New").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    ScrollView { NotesView(blocks: ReleaseNotes.parse(offer.notes)).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                        .frame(maxHeight: 170)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                progress
                logView
            }
            .padding(24)
            Divider()
            footer(offer)
        }
        .frame(width: 540)
        .frame(minHeight: 560)
    }

    private func versionBlock(_ label: String, _ value: String, _ style: HierarchicalShapeStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).textCase(.uppercase)
            Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(style)
        }
        .padding(.trailing, 10)
    }

    @ViewBuilder private var progress: some View {
        if case .downloading(let done, let total, let rate) = service.phase {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: total > 0 ? Double(done) : nil, total: total > 0 ? Double(total) : 1)
                HStack {
                    Text(total > 0 ? "\(Int(Double(done) / Double(total) * 100))%  (\(bytes(done)) / \(bytes(total)))" : bytes(done))
                    Spacer()
                    Text(String(format: "%.2f MB/s", rate / 1_048_576))
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(service.log) { line in
                        Text("[\(line.time.formatted(date: .omitted, time: .standard))]  \(line.text)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(line.level))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .frame(height: 90)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: service.log.count) { if let last = service.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }

    private func footer(_ offer: UpdateService.Offer) -> some View {
        HStack {
            if let url = offer.releaseUrl { Button("View on GitHub") { openURL(url) }.buttonStyle(.link) }
            Spacer()
            Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
            primaryButton(offer)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    @ViewBuilder private func primaryButton(_ offer: UpdateService.Offer) -> some View {
        switch service.phase {
        case .ready:
            Button(offer.asset == nil ? "Open Release Page" : "Download Update") { Task { await service.download() } }
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Downloading\u{2026}") {}.disabled(true)
        case .downloaded:
            Button(offer.kind == .switchBack ? "Switch and Restart" : "Restart and Install") { Task { await service.install() } }
                .keyboardShortcut(.defaultAction)
        case .installing:
            Button("Installing\u{2026}") {}.disabled(true)
        case .manual:
            Button("Open Release Page") { if let url = offer.releaseUrl { openURL(url) } }
        case .failed:
            Button("Retry Download") { Task { await service.download() } }.keyboardShortcut(.defaultAction)
        }
    }

    private func color(_ level: UpdateService.LogLine.Level) -> Color {
        switch level {
        case .plain: .secondary
        case .info: .purple
        case .ok: .green
        case .error: .red
        }
    }

    private func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

/// Release notes as the SwiftUI blocks ReleaseNotes parses them into.
struct NotesView: View {
    let blocks: [ReleaseNotes.Block]

    var body: some View {
        if blocks.isEmpty {
            Text("No release notes available.").italic().foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) { ForEach(Array(blocks.enumerated()), id: \.offset) { block($0.element) } }
        }
    }

    private func block(_ b: ReleaseNotes.Block) -> AnyView {
        switch b {
        case .heading(let level, let text):
            AnyView(Text(text).font(level <= 2 ? .headline : .subheadline.weight(.semibold)).padding(.top, 4))
        case .paragraph(let text):
            AnyView(Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true))
        case .rule:
            AnyView(Divider())
        case .list(let ordered, let items):
            AnyView(VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "\u{2022}").foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(item.children.enumerated()), id: \.offset) { block($0.element) }
                        }
                    }
                }
            }.padding(.leading, 4))
        }
    }
}

/// Opens the Update Available window when the service asks, and starts the
/// launch check. Attached once, to the main window's content.
private struct UpdatePrompt: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    private let service = UpdateService.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: service.showRequest) { openWindow(id: "update") }
            .task { service.checkOnLaunch() }
    }
}

extension View {
    /// The Mac-only extras the app's main window carries: the update prompt and
    /// the first-run wizard.
    func macAppExtras() -> some View { modifier(UpdatePrompt()).firstRunWizard() }
}
