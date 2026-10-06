import SwiftUI
import AVFoundation
import CascadeKit

/// The lyrics editor's state: the document, the selection, Stamp mode, and its own AVPlayer
/// (the main player keeps its queue; the desktop editor had its own audio element too).
@MainActor
@Observable
final class LyricsEditorModel {
    enum Selection: Hashable { case line(Int), word(Int, Int) }

    private(set) var item: JfItem?
    var lines: [LRCLine] = []
    /// What the server had at open, for Re-import.
    private(set) var original: [LRCLine] = []
    var selection: Selection?
    private(set) var loaded = false
    private(set) var loadError: String?
    var dirty = false
    private(set) var saving = false
    var status: (text: String, ok: Bool)?

    // Stamp mode
    private(set) var stamping = false
    private(set) var stampSeq: [LRCDocument.StampTarget] = []
    private(set) var stampIdx = 0
    var stampTarget: LRCDocument.StampTarget? { stamping && stampSeq.indices.contains(stampIdx) ? stampSeq[stampIdx] : nil }

    // Playback
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    private(set) var speed = 1.0
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?

    // MARK: Loading

    func load(state: AppState, itemId: String) async {
        guard let client = state.client else { loadError = "Not signed in"; return }
        do {
            let item = try await client.item(id: itemId)
            self.item = item
            duration = Double(item.runTimeTicks ?? 0) / Double(Lyrics.ticksPerSecond)
            let config = await client.currentConfig
            if let url = universalStreamUrl(config: config, itemId: itemId) { startPlayer(url: url, volume: state.player?.volume ?? 1) }
        } catch { loadError = error.localizedDescription; return }

        // The plugin's own lyrics, never SpicyLyrics: saving writes a permanent .slrc, and its
        // terms forbid keeping that data. Not asking for `syllable` is what keeps it out.
        guard let api = state.cascadePluginApi else { loaded = true; return }
        do {
            let reply: PluginLyrics = try await client.get(CascadePlugin.lyricsPath(api, itemId: itemId))
            lines = LRCDocument.parse(reply.lrc ?? "")
        } catch let e as JellyfinError where e.status == 404 {
            lines = []   // none yet: a blank page to start from
        } catch { loadError = "Could not load lyrics: \(error.localizedDescription)" }
        original = lines
        loaded = true
    }

    func save(state: AppState) async {
        guard let item, let client = state.client, let api = state.cascadePluginApi, !lines.isEmpty else { return }
        saving = true
        status = nil
        defer { saving = false }
        do {
            try await client.saveLyrics(itemId: item.id, api: api, lrc: LRCDocument.export(lines))
            // The main window's lyrics are keyed on this, so they reload with the new copy.
            state.lyricsRevision += 1
            dirty = false
            status = ("Saved", true)
        } catch {
            status = ("Failed: \(error.localizedDescription)", false)
        }
    }

    func replace(with new: [LRCLine]) {
        exitStamp()
        lines = new
        selection = nil
        dirty = true
    }

    // MARK: Editing

    private func edit(_ change: () -> Void) { change(); dirty = true }

    private func refreshText(_ li: Int) {
        guard let words = lines[li].words, !words.isEmpty else { return }
        lines[li].text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }

    func setStart(_ li: Int, _ t: Double?) { guard lines.indices.contains(li) else { return }; edit { lines[li].start = t } }
    func setText(_ li: Int, _ text: String) { guard lines.indices.contains(li) else { return }; edit { lines[li].text = text } }

    func setWord(_ li: Int, _ wi: Int, start: Double?? = nil, end: Double?? = nil, text: String? = nil) {
        guard lines.indices.contains(li), lines[li].words?.indices.contains(wi) == true else { return }
        edit {
            if let start { lines[li].words![wi].start = start }
            if let end { lines[li].words![wi].end = end }
            if let text { lines[li].words![wi].text = text; refreshText(li) }
        }
    }

    func appendLine() {
        exitStamp()
        edit { lines.append(LRCLine(start: lines.last?.start, text: "")) }
        selection = .line(lines.count - 1)
    }

    func removeLine(_ li: Int) {
        guard lines.indices.contains(li) else { return }
        exitStamp()
        edit { lines.remove(at: li) }
        selection = nil
    }

    func moveLine(_ li: Int, _ dir: Int) {
        let to = li + dir
        guard lines.indices.contains(li), lines.indices.contains(to) else { return }
        exitStamp()
        edit { lines.swapAt(li, to) }
        selection = .line(to)
    }

    func splitLine(_ li: Int) {
        guard lines.indices.contains(li), let split = LRCDocument.split(lines[li]) else { return }
        exitStamp()
        edit { lines[li] = split }
    }

    func addWord(_ li: Int) {
        guard lines.indices.contains(li) else { return }
        exitStamp()
        edit {
            lines[li].words = (lines[li].words ?? []) + [LRCWord(text: "word")]
            refreshText(li)
        }
        selection = .word(li, lines[li].words!.count - 1)
    }

    func removeWord(_ li: Int, _ wi: Int) {
        guard lines.indices.contains(li), lines[li].words?.indices.contains(wi) == true else { return }
        exitStamp()
        edit {
            lines[li].words!.remove(at: wi)
            if lines[li].words!.isEmpty { lines[li].words = nil } else { refreshText(li) }
        }
        selection = nil
    }

    func moveWord(_ li: Int, _ wi: Int, _ dir: Int) {
        guard let words = lines[li].words, words.indices.contains(wi), words.indices.contains(wi + dir) else { return }
        exitStamp()
        edit { lines[li].words!.swapAt(wi, wi + dir); refreshText(li) }
        selection = .word(li, wi + dir)
    }

    /// Drops a word in front of another, which may be on another line.
    func moveWord(from: (line: Int, word: Int), before to: (line: Int, word: Int)) {
        guard lines.indices.contains(from.line), lines.indices.contains(to.line),
              lines[from.line].words?.indices.contains(from.word) == true,
              lines[to.line].words?.indices.contains(to.word) == true, from != to else { return }
        exitStamp()
        edit {
            let word = lines[from.line].words!.remove(at: from.word)
            // Taking one out of the target's own line, ahead of it, shifts the target down one.
            let at = from.line == to.line && from.word < to.word ? to.word - 1 : to.word
            lines[to.line].words!.insert(word, at: at)
            for li in Set([from.line, to.line]) {
                if lines[li].words?.isEmpty == true { lines[li].words = nil } else { refreshText(li) }
            }
        }
        selection = .word(to.line, from.line == to.line && from.word < to.word ? to.word - 1 : to.word)
    }

    // MARK: Stamp mode

    func toggleStamp() { stamping ? exitStamp() : enterStamp() }

    func enterStamp() {
        guard !lines.isEmpty else { return }
        stampSeq = LRCDocument.stampSequence(lines)
        stampIdx = 0
        stamping = true
    }

    func exitStamp() { stamping = false; stampSeq = []; stampIdx = 0 }

    /// Stamps the next word (or plain line) with the playhead; the word before it takes the
    /// same time as its end.
    func stampNext() {
        guard stamping, stampIdx < stampSeq.count else { return }
        LRCDocument.stamp(&lines, sequence: stampSeq, index: stampIdx, at: currentTime)
        dirty = true
        stampIdx += 1
        if stampIdx >= stampSeq.count { exitStamp() }
    }

    /// Stamps the selection with the playhead (the inspector's Stamp buttons).
    func stampSelection(end: Bool = false) {
        let now = currentTime
        switch selection {
        case .line(let li): setStart(li, now)
        case .word(let li, let wi): end ? setWord(li, wi, end: .some(now)) : setWord(li, wi, start: .some(now))
        case nil: break
        }
    }

    // MARK: Playback

    private var currentTime: Double { player.map { $0.currentTime().seconds }.flatMap { $0.isFinite ? $0 : nil } ?? position }

    private func startPlayer(url: URL, volume: Float) {
        let avItem = AVPlayerItem(url: url)
        avItem.audioTimePitchAlgorithm = .spectral   // slowing down keeps the pitch
        let p = AVPlayer(playerItem: avItem)
        // Inherits the main window's level: a fresh player defaults to full volume.
        p.volume = volume
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = t.seconds
                self.isPlaying = self.player?.timeControlStatus != .paused
            }
        }
        player = p
    }

    func stop() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    func togglePlay(mainPlayer: PlaybackService?) {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            // Two songs at once is never wanted.
            mainPlayer?.pause()
            player.defaultRate = Float(speed)
            player.playImmediately(atRate: Float(speed))
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), duration > 0 ? duration : seconds)
        position = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ by: Double) { seek(to: currentTime + by) }

    func setSpeed(_ rate: Double) {
        speed = min(2, max(0.25, rate))
        player?.defaultRate = Float(speed)
        if player?.timeControlStatus != .paused { player?.rate = Float(speed) }
    }
}
