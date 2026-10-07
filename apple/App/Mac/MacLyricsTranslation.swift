import SwiftUI
import Translation
import CascadeKit

/// Lyric translation into English with Apple's on-device Translation framework, the Mac's
/// only engine (no Mozilla models, no downloads of our own).
///
/// Two switches, as on the desktop and kept apart: LyricsPrefs.translationEnabled says whether
/// translation exists at all (Settings), translateOn whether translations are showing now (the
/// Translate button). Lines stream in starting from the one being sung, so a cold sheet shows
/// the current line in about a second instead of all of it at the end; lines already
/// translated come back from the cache at once.
///
/// macOS 26 and later translate through `TranslationSession(installedSource:target:)`, which
/// needs no view. macOS 15 only hands out a session to a `.translationTask` on a view, so
/// `translationHost()` carries the same loop there. Neither ever prompts to download a
/// language: only an installed one is translated, and a language that is merely supported
/// opens Language & Region from the install prompt instead.
@MainActor
@Observable
final class LyricsTranslator {
    enum Status: Equatable {
        case idle
        case translating(done: Int, total: Int)
        /// The language is supported but not installed in macOS: the install prompt.
        case needsInstall(String)
        case failed
    }

    private(set) var status = Status.idle
    /// One English line for each line of the sheet, empty where there is none yet.
    private(set) var translations: [String] = []
    /// The same lines by index, the shape LyricsView takes (shared with the
    /// iOS translator); an empty slot is a line not translated yet.
    var byIndex: [Int: String] {
        Dictionary(uniqueKeysWithValues: translations.enumerated().filter { !$0.element.isEmpty }.map { ($0.offset, $0.element) })
    }
    /// The language of the sheet on screen, or nil when Apple could not take it.
    private(set) var language: String?
    private(set) var availability: LyricLanguages.AppleStatus?
    /// Shown by the install prompt.
    var promptingInstall: String?

    private var sheet: [LyricLine] = []
    private var sheetId: String?
    private var cache: TranslationCacheFile
    private var cacheDirty = false
    private var saveTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    /// The sheet a translation is complete for, so a second ask is a no-op.
    private var translatedSheetId: String?
    /// macOS 15's way in: set non-nil to make the host view's translationTask run.
    fileprivate var configuration: TranslationSession.Configuration?
    private var player: PlaybackService?

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "xyz.chaosinc.cascade")
            .appendingPathComponent("translation-cache.json")
    }

    init() {
        cache = TranslationCacheFile.load(from: Self.cacheURL)
        cacheDirty = cache.isDirty
    }

    private var prefs: LyricsPrefs { .shared }

    /// Whether the Translate button should show: the feature is on, and something here can
    /// translate this sheet (or could, once its language is installed).
    var offered: Bool {
        prefs.translationEnabled && language != nil
            && LyricLanguages.pickEngine(enabled: true, status: availability) != .none
    }

    /// Whether the sheet's translations are on screen (or on their way).
    var showing: Bool { prefs.translationEnabled && prefs.translateOn }

    /// Called whenever the sheet on screen changes, and with nil when there is none.
    func sheetChanged(lines: [LyricLine]?, id: String?, player: PlaybackService?) {
        self.player = player
        guard id != sheetId || (lines?.count ?? 0) != sheet.count else { return }
        runTask?.cancel()
        sheet = lines ?? []
        sheetId = id
        translations = []
        translatedSheetId = nil
        status = .idle
        language = nil
        availability = nil
        guard !sheet.isEmpty, prefs.translationEnabled else { return }
        language = LyricLanguages.languageFor(sheet.map(\.text))
        Task { await refreshAvailabilityThenTranslate() }
    }

    /// The Translate button: on and off. A sheet waiting on an install asks again instead.
    func toggle() {
        if case .needsInstall(let key) = status, prefs.translateOn { promptingInstall = key; return }
        prefs.translateOn.toggle()
        if prefs.translateOn { ensure(userAsked: true) } else { status = .idle; runTask?.cancel() }
    }

    /// The feature switch in Settings: off strips what is on screen and stops everything.
    func enabledChanged() {
        if !prefs.translationEnabled {
            runTask?.cancel()
            translations = []
            translatedSheetId = nil
            status = .idle
        } else {
            let id = sheetId, lines = sheet
            sheetId = nil
            sheetChanged(lines: lines, id: id, player: player)
        }
    }

    private func refreshAvailabilityThenTranslate() async {
        guard let language else { return }
        let id = sheetId
        let status = await Self.appleStatus(language)
        guard id == sheetId else { return }
        availability = status
        ensure(userAsked: false)
    }

    private static func appleStatus(_ key: String) async -> LyricLanguages.AppleStatus {
        switch await LanguageAvailability().status(from: Locale.Language(identifier: key), to: Locale.Language(identifier: "en")) {
        case .installed: .installed
        case .supported: .supported
        default: .unsupported
        }
    }

    /// Translates the sheet when the switches say to. Safe from every place a sheet appears:
    /// a finished sheet is left alone and a second call joins the run in flight. `userAsked` is
    /// true only for a Translate press, the one moment the install prompt may appear: a song
    /// change must never pop a dialog.
    func ensure(userAsked: Bool) {
        guard prefs.translationEnabled, prefs.translateOn, !sheet.isEmpty, let language,
              translatedSheetId != sheetId, runTask == nil || runTask?.isCancelled == true else { return }
        switch LyricLanguages.pickEngine(enabled: true, status: availability) {
        case .none:
            status = .idle
        case .needsInstall:
            status = .needsInstall(language)
            if userAsked { promptingInstall = language }
        case .apple:
            if #available(macOS 26, *) {
                start(language: language) { text in
                    let session = UncheckedSession(TranslationSession(installedSource: Locale.Language(identifier: language),
                                                                      target: Locale.Language(identifier: "en")))
                    return try await session.translate(text)
                }
            } else {
                // macOS 15: the host view's translationTask picks this up and runs the loop.
                status = .translating(done: 0, total: 0)
                configuration = TranslationSession.Configuration(source: Locale.Language(identifier: language),
                                                                 target: Locale.Language(identifier: "en"))
            }
        }
    }

    /// Opens Language & Region, where the language is installed. Both of the prompt's buttons
    /// leave the song untranslated for now, so Translate goes back to plain Translate: after
    /// installing the language, pressing it again is all that is needed.
    func openLanguageSettings() {
        promptingInstall = nil
        prefs.translateOn = false
        status = .idle
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func dismissInstallPrompt() {
        promptingInstall = nil
        prefs.translateOn = false
        status = .idle
    }

    // MARK: The loop

    /// macOS 15's entry, from the host view: runs the loop with the session it was handed.
    fileprivate func run(session: TranslationSession) async {
        guard let language else { return }
        let session = UncheckedSession(session)
        await translateSheet(language: language) { try await session.translate($0) }
        configuration = nil
    }

    private func start(language: String, translate: @escaping @MainActor (String) async throws -> String) {
        runTask = Task { await translateSheet(language: language, translate: translate) }
    }

    private func translateSheet(language: String, translate: @MainActor (String) async throws -> String) async {
        let id = sheetId
        let lines = sheet.map(\.text)
        var plan = TranslationPlan(lines: lines)
        translations = Array(repeating: "", count: lines.count)
        status = .translating(done: 0, total: plan.total)
        defer { if runTask?.isCancelled != true { runTask = nil } }
        do {
            // Cached lines first, all at once.
            for text in plan.pendingTexts {
                if let hit = cache.lookup(TranslationCacheFile.key(language: language, line: text)) {
                    for i in plan.land(text) { translations[i] = hit }
                }
            }
            while let text = plan.next(from: playheadLine()) {
                try Task.checkCancellation()
                let english = try await translate(text)
                guard id == sheetId else { return }
                cache.store(TranslationCacheFile.key(language: language, line: text), english)
                cacheDirty = true
                for i in plan.land(text) { translations[i] = english }
                status = .translating(done: plan.done, total: plan.total)
            }
            translatedSheetId = id
            status = .idle
            saveCacheSoon()
        } catch is CancellationError {
            // A song change or Show original: nothing to report.
        } catch {
            guard id == sheetId else { return }
            status = .failed
            // The button says Failed for a moment, then goes back to Translate.
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                if status == .failed { status = .idle }
            }
        }
    }

    /// The line being sung, for the order of translation.
    private func playheadLine() -> Int {
        guard let player else { return 0 }
        let ticks = Int((player.livePositionSeconds - StyleTuning.shared.values.lyricsDelay) * Double(Lyrics.ticksPerSecond))
        return Lyrics.activeLineIndex(sheet, at: ticks) ?? 0
    }

    /// Debounced, so quitting within 3 s of a translation loses those lines; they are
    /// translated again next time.
    private func saveCacheSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, cacheDirty else { return }
            do {
                try cache.save(to: Self.cacheURL)
                cacheDirty = false
            } catch {
                debugLog("translation cache not saved: \(error.localizedDescription)")
            }
        }
    }
}

/// A TranslationSession is not Sendable, and its translate is nonisolated: handing it to an
/// await from the main actor would be a data-race error. It is only ever used from one task at
/// a time here, so the wrapper says so.
private struct UncheckedSession: @unchecked Sendable {
    let session: TranslationSession
    init(_ session: TranslationSession) { self.session = session }
    func translate(_ text: String) async throws -> String { try await session.translate(text).targetText }
}

// MARK: - macOS 15's host

private struct TranslationHost: ViewModifier {
    let translator: LyricsTranslator

    func body(content: Content) -> some View {
        content.translationTask(translator.configuration) { session in
            await translator.run(session: session)
        }
    }
}

extension View {
    /// Carries the translation loop on macOS 15, which hands out a session only to a view.
    /// Harmless on macOS 26 and later, where the configuration is never set.
    func translationHost(_ translator: LyricsTranslator) -> some View {
        modifier(TranslationHost(translator: translator))
    }
}
