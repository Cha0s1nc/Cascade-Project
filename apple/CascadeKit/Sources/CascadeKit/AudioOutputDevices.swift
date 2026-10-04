import Foundation

// The output device picker's side of CoreAudio, and the rule for a device that
// has gone away. macOS only: iOS and tvOS route audio through the system.

/// One place sound can come out of: a CoreAudio device the Mac knows about.
public struct AudioOutputDevice: Identifiable, Sendable, Equatable {
    /// The device's UID, which is what AVPlayer.audioOutputDeviceUniqueID takes
    /// and what is saved. Stable across reconnects, unlike CoreAudio's own
    /// numeric ids.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum AudioOutput {
    /// What the desktop stores for "whatever the system default is". The Mac
    /// keeps it so the setting round-trips, and a lookup never goes near it.
    public static let defaultId = "default"

    /// A stored value, which can be anything: the default, a device UID, or
    /// junk. Nil is the system default.
    public static func deviceId(stored: Any?) -> String? {
        guard let id = (stored as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, id != defaultId else { return nil }
        return id
    }

    /// What to play to, given what is wanted and what exists right now. A
    /// device that has gone is dropped to the system default, and `vanished`
    /// says so for the notice: playing on in the speakers after the headphones
    /// were pulled is right, but silently so is not.
    public static func resolve(wanted: String?, available: [String]) -> (id: String?, vanished: Bool) {
        guard let wanted else { return (nil, false) }
        return available.contains(wanted) ? (wanted, false) : (nil, true)
    }
}

#if os(macOS)
import CoreAudio

public extension AudioOutput {
    /// Every device that can play sound, in the system's order. Hidden ones
    /// (the system's own plumbing) and devices with no output channels are
    /// left out.
    static func devices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannelCount(id) > 0, !isHidden(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioOutputDevice(id: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    /// Calls `changed` on the main queue whenever a device appears or goes.
    /// Built here, outside any actor, for the same reason as the lock screen
    /// art: CoreAudio owns the queue the block is registered on, and a closure
    /// written inside a @MainActor type would carry an isolation check.
    /// Keep the result alive for as long as the listening should last.
    static func watchDevices(_ changed: @escaping @Sendable () -> Void) -> DeviceWatcher {
        DeviceWatcher(changed)
    }

    /// Stops listening when it goes away.
    final class DeviceWatcher: @unchecked Sendable {
        private let block: AudioObjectPropertyListenerBlock
        private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)

        fileprivate init(_ changed: @escaping @Sendable () -> Void) {
            block = { _, _ in changed() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }
}
#endif
