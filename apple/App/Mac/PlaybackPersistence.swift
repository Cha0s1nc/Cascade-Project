import AppKit
import CascadeKit

/// Keeps what the player is set to across launches, the desktop's way: the
/// queue (every 5 s when it changed, and on quit), volume, repeat and the
/// output device. At launch the queue comes back shown but not loaded, so
/// nothing plays and nothing is reported to the server until play is pressed.
///
/// Mac only. A phone's queue and volume are not carried over, and iOS and tvOS
/// behave as they did before this existed.
///
/// Keys are the desktop's store keys under `cascade.`, with the same value
/// shapes, so the settings import is a straight copy: `lastQueue` is JSON in a
/// string, `volume` a 0-1 number, `repeatMode` none/all/one, `outputDeviceId`
/// a CoreAudio UID or "default".
@MainActor
final class PlaybackPersistence {
    private let player: PlaybackService
    private let client: JellyfinClient
    private let defaults: UserDefaults
    private var saving: Task<Void, Never>?
    private var quitObserver: NSObjectProtocol?
    /// The last queue written, so an unchanged one is not written every 5 s.
    private var lastSaved: String?

    static let volumeKey = "cascade.volume"
    static let repeatKey = "cascade.repeatMode"
    static let outputKey = "cascade.outputDeviceId"

    init(player: PlaybackService, client: JellyfinClient, defaults: UserDefaults = .standard) {
        self.player = player
        self.client = client
        self.defaults = defaults
    }

    func start() {
        // Hooked up before the saved device is applied, so a device that is
        // gone by now is saved as the default it fell back to.
        player.onOutputDeviceChange = { [defaults] id in defaults.set(id ?? AudioOutput.defaultId, forKey: Self.outputKey) }
        player.onSettingsChange = { [weak self] in self?.saveSettings() }
        applySavedSettings()

        Task { await restoreLastQueue() }
        saving = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.saveQueue()
            }
        }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveQueue() }
        }
    }

    /// Signing out clears the saved queue: the next account must not be
    /// handed the last one's.
    func stop(clearingSavedQueue: Bool = false) {
        saving?.cancel()
        saving = nil
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        player.onOutputDeviceChange = nil
        player.onSettingsChange = nil
        if clearingSavedQueue {
            defaults.removeObject(forKey: lastQueueKey)
            lastSaved = nil
        }
    }

    // MARK: - Volume, repeat, output

    private func applySavedSettings() {
        // Stored values are untrusted: the desktop writes the volume as a
        // number or a string, and a hand-edited plist can hold anything.
        let stored = defaults.object(forKey: Self.volumeKey)
        if let volume = (stored as? Double) ?? (stored as? String).flatMap(Double.init), volume.isFinite {
            player.setVolume(Float(volume))
        }
        if let mode = (defaults.string(forKey: Self.repeatKey)).flatMap(RepeatMode.init(rawValue:)) {
            player.setRepeatMode(mode)
        }
        player.outputDeviceId = AudioOutput.deviceId(stored: defaults.object(forKey: Self.outputKey))
    }

    private func saveSettings() {
        defaults.set(Double(player.volume), forKey: Self.volumeKey)
        defaults.set(player.repeatMode.rawValue, forKey: Self.repeatKey)
    }

    // MARK: - The queue

    private func saveQueue() {
        // A Waterfall guest's queue is the host's: neither saved nor restored.
        guard player.transportGate == nil else { return }
        // A station is neither saved nor allowed to erase the music queue
        // before it, and a video is not in this queue at all.
        guard !player.isRadio else { return }
        guard let queue = player.savedQueue() else {
            // Stopped: nothing left to come back to.
            if player.item == nil, lastSaved != nil {
                defaults.removeObject(forKey: lastQueueKey)
                lastSaved = nil
            }
            return
        }
        let json = queue.json
        guard json != lastSaved else { return }
        lastSaved = json
        defaults.set(json, forKey: lastQueueKey)
    }

    private func restoreLastQueue() async {
        guard player.item == nil, player.transportGate == nil,
              let saved = parseSavedQueue(defaults.string(forKey: lastQueueKey)) else { return }
        let ids = savedQueueIds(saved)
        guard !ids.isEmpty, let items = try? await client.restoredItems(ids: ids) else { return }
        // Something started (or a room was joined) while the tracks were fetched.
        guard player.item == nil, player.transportGate == nil,
              let restored = CascadeKit.restoreQueue(saved, items: items) else { return }
        player.adoptRestoredQueue(restored, shuffled: !restored.unshuffled.isEmpty, repeatMode: player.repeatMode)
        // What was just restored is what is saved: writing it back at once
        // would only replay the same bytes.
        lastSaved = player.savedQueue()?.json
    }
}
