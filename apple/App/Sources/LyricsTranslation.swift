#if os(iOS)
import SwiftUI
import Translation
import CascadeKit

/// Translates the lyrics on screen with Apple's on-device Translation
/// framework, the phone's counterpart of the desktop's translator. Nothing
/// leaves the phone: the framework runs the models itself, and the lyric text
/// is only ever handed to it.
///
/// The framework gives a TranslationSession only to a view's `.translationTask`,
/// so this model holds the configuration that task is attached to (see
/// `lyricsTranslationTask` below) and does the work when the session arrives.
/// The tvOS target has no Translation framework: this whole file is iOS.
@MainActor
@Observable
final class LyricsTranslationModel {
    enum Phase: Equatable { case idle, preparing, translating, failed(String) }

    /// Whether translations show. Off by default, like the desktop's button.
    var isOn = UserDefaults.standard.bool(forKey: "cascade.lyricsTranslate") {
        didSet { UserDefaults.standard.set(isOn, forKey: "cascade.lyricsTranslate") }
    }
    /// The translated line for each line index, as far as they have got.
    private(set) var translations: [Int: String] = [:]
    private(set) var phase: Phase = .idle
    /// True when the lyrics are in another language this device can translate,
    /// so the menu offers a Translate entry at all.
    private(set) var available = false
    /// What the translation task is attached to; setting it starts the task.
    var configuration: TranslationSession.Configuration?

    private var lines: [String] = []
    private var source = ""
    private var target = "en"
    private var currentLine: @MainActor () -> Int? = { nil }
    private var cache: TranslationCache
    private let cacheURL: URL

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheURL = dir.appending(path: "lyric-translations.json")
        cache = TranslationCache.decode(try? Data(contentsOf: cacheURL))
    }

    /// A new song's lyrics: forget the last one's, find out whether these can be
    /// translated, show what the cache already has, and start if it is on.
    /// `currentLine` is asked when a run starts, so it begins where the song is.
    func attach(lines new: [LyricLine]?, currentLine: @escaping @MainActor () -> Int?) async {
        configuration = nil
        translations = [:]
        phase = .idle
        available = false
        lines = (new ?? []).map(\.text)
        self.currentLine = currentLine
        target = Locale.current.language.languageCode?.identifier ?? "en"
        guard let detected = LyricTranslation.detectLanguage(of: lines),
              LyricTranslation.needsTranslation(from: detected, to: target) else { return }
        // "Unsupported" is a pair with no model at all, and gets no menu entry,
        // the way the desktop shows no Translate button for one.
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: detected),
                                                         to: Locale.Language(identifier: target))
        guard status != .unsupported else { return }
        source = detected
        available = true
        fillFromCache()
        if isOn { start() }
    }

    func toggle() {
        isOn.toggle()
        if isOn { start() }
    }

    private func fillFromCache() {
        for (i, text) in lines.enumerated() {
            if let hit = cache.translation(for: LyricTranslation.cacheKey(source: source, target: target, line: text)) {
                translations[i] = hit
            }
        }
    }

    /// Starts a run unless every line is already translated.
    private func start() {
        guard available, translations.count < lines.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count else { return }
        configuration = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                         target: Locale.Language(identifier: target))
    }

    /// The translation task's work. `prepareTranslation` is where the framework
    /// asks to download a language that is not installed, with its own prompt;
    /// declining ends here and turns the feature off.
    func run(_ session: TranslationSession) async {
        phase = .preparing
        do {
            try await session.prepareTranslation()
        } catch {
            phase = .failed("The language was not downloaded.")
            isOn = false
            return
        }
        phase = .translating
        defer { saveCache() }
        for index in LyricTranslation.order(count: lines.count, from: currentLine()) {
            if Task.isCancelled { return }
            let text = lines[index]
            guard translations[index] == nil, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            do {
                let response = try await session.translate(text)
                translations[index] = response.targetText
                cache.set(response.targetText, for: LyricTranslation.cacheKey(source: source, target: target, line: text))
            } catch {
                // One line the framework would not take is not worth stopping for.
                continue
            }
        }
        phase = .idle
    }

    private func saveCache() {
        if let data = cache.encoded() { try? data.write(to: cacheURL, options: .atomic) }
    }
}

extension View {
    /// Attaches the model's translation task to a view that is on screen while
    /// lyrics are.
    func lyricsTranslationTask(_ model: LyricsTranslationModel) -> some View {
        translationTask(model.configuration) { session in
            await model.run(session)
        }
    }
}
#endif
