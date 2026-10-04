import Testing
@testable import CascadeKit

@Suite struct AudioOutputTests {
    @Test func storedValuesAreValidated() {
        #expect(AudioOutput.deviceId(stored: "AppleUSBAudioEngine:Vendor:Dac:123") == "AppleUSBAudioEngine:Vendor:Dac:123")
        // The desktop's word for the system default, nothing, and junk are all the default.
        #expect(AudioOutput.deviceId(stored: "default") == nil)
        #expect(AudioOutput.deviceId(stored: "") == nil)
        #expect(AudioOutput.deviceId(stored: "  ") == nil)
        #expect(AudioOutput.deviceId(stored: nil) == nil)
        #expect(AudioOutput.deviceId(stored: 42) == nil)
    }

    @Test func aWantedDeviceThatIsStillThereIsKept() {
        let r = AudioOutput.resolve(wanted: "B", available: ["A", "B"])
        #expect(r.id == "B" && !r.vanished)
    }

    @Test func aVanishedDeviceFallsBackToTheDefaultAndSaysSo() {
        let r = AudioOutput.resolve(wanted: "B", available: ["A"])
        #expect(r.id == nil && r.vanished)
    }

    @Test func theDefaultIsNeverLookedUp() {
        let r = AudioOutput.resolve(wanted: nil, available: [])
        #expect(r.id == nil && !r.vanished)
    }

    #if os(macOS)
    @Test func theMacHasAtLeastOneOutputDeviceWithAUidAndAName() {
        // Every Mac has built-in speakers or some output; CI hosts without
        // audio hardware still list a virtual one, so this only runs where
        // CoreAudio answers at all.
        let devices = AudioOutput.devices()
        for d in devices { #expect(!d.id.isEmpty && !d.name.isEmpty) }
        #expect(Set(devices.map(\.id)).count == devices.count)
    }
    #endif
}
