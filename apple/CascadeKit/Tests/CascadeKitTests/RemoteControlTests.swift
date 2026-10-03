import Foundation
import Testing
@testable import CascadeKit

// The desktop's remote-control and session-control tests, ported.
struct RemoteControlTests {
    private func json(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    }

    @Test func playWithModeAndStart() {
        #expect(RemoteCommand.parse(json(#"{"MessageType":"Play","Data":{"ItemIds":["a","b"],"StartIndex":1,"PlayCommand":"PlayNext"}}"#))
                == .play(itemIds: ["a", "b"], startIndex: 1, mode: .next))
        // Unknown mode plays now; no ids is nothing to do.
        #expect(RemoteCommand.parse(json(#"{"MessageType":"Play","Data":{"ItemIds":["a"],"PlayCommand":"Shuffle"}}"#))
                == .play(itemIds: ["a"], startIndex: 0, mode: .now))
        #expect(RemoteCommand.parse(json(#"{"MessageType":"Play","Data":{"ItemIds":[]}}"#)) == nil)
    }

    @Test func playstateBothSpellings() {
        #expect(RemoteCommand.parse(json(#"{"MessageType":"Playstate","Data":{"Command":"NextTrack"}}"#)) == .next)
        #expect(RemoteCommand.parse(json(#"{"MessageType":"PlayState","Data":{"Command":"Seek","SeekPositionTicks":300000000}}"#))
                == .seek(ticks: 300_000_000))
    }

    @Test func generalCommandArgumentsArriveAsStrings() {
        #expect(RemoteCommand.parse(json(#"{"MessageType":"GeneralCommand","Data":{"Name":"SetVolume","Arguments":{"Volume":"42"}}}"#))
                == .setVolume(percent: 42))
        #expect(RemoteCommand.parse(json(#"{"MessageType":"GeneralCommand","Data":{"Name":"SetVolume","Arguments":{"Volume":"999"}}}"#))
                == .setVolume(percent: 100))
        #expect(RemoteCommand.parse(json(#"{"MessageType":"GeneralCommand","Data":{"Name":"Mute"}}"#)) == .setMute(true))
        #expect(RemoteCommand.parse(json(#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayContent"}}"#)) == nil)
    }

    @Test func keepAliveAndNoise() {
        #expect(RemoteCommand.parse(json(#"{"MessageType":"ForceKeepAlive","Data":60}"#)) == .forceKeepAlive(seconds: 60))
        #expect(RemoteCommand.parse(json(#"{"MessageType":"KeepAlive"}"#)) == nil)
        #expect(RemoteCommand.parse(json(#"{"MessageType":"UserDataChanged","Data":{}}"#)) == nil)
    }

    @Test func declaresOnlyGeneralCommands() {
        // A Playstate name here gets the whole registration refused (400).
        for playstate in ["Pause", "PlayPause", "Stop", "NextTrack", "PreviousTrack", "Seek"] {
            #expect(!RemoteControl.supportedCommands.contains(playstate))
        }
    }

    @Test func aWaterfallRoomRefusesCastsButNeverVolumeAndKeepAliveAlwaysPasses() {
        let solo = OwnershipState()
        let guest = OwnershipState(waterfallActive: true)
        let host = OwnershipState(waterfallActive: true, waterfallIsHost: true)
        let transport: [RemoteCommand] = [.play(itemIds: ["a"], startIndex: 0, mode: .now), .playPause, .pause,
                                          .unpause, .stop, .next, .previous, .seek(ticks: 5)]
        let volume: [RemoteCommand] = [.setVolume(percent: 50), .volumeUp, .volumeDown, .toggleMute, .setMute(true)]
        for c in transport + volume { #expect(RemoteControl.accepts(c, in: solo)) }
        // Refused for host and guest alike: a room outranks a cast.
        for room in [guest, host] {
            for c in transport { #expect(!RemoteControl.accepts(c, in: room)) }
            // Volume is personal to this device: a room never drives it either.
            for c in volume { #expect(!RemoteControl.accepts(c, in: room)) }
            #expect(RemoteControl.accepts(.forceKeepAlive(seconds: 60), in: room))
        }
    }

    @Test func controllableSessionsExcludeItselfAndTheUncontrollable() {
        func session(_ id: String, _ device: String, _ remote: Bool) -> RemoteSession {
            RemoteSession(id: id, deviceId: device, supportsRemoteControl: remote)
        }
        let list = [session("1", "me", true), session("2", "tv", true), session("3", "web", false)]
        #expect(SessionControl.controllable(list, ownDeviceId: "me").map(\.id) == ["2"])
    }

    @Test func positionMovesOnUnlessPaused() {
        let polled = Date(timeIntervalSince1970: 1000)
        let playing = RemoteSession.PlayState(positionTicks: 100_000_000, isPaused: false)
        #expect(SessionControl.position(playing, polledAt: polled, now: polled.addingTimeInterval(3)) == 13)
        let paused = RemoteSession.PlayState(positionTicks: 100_000_000, isPaused: true)
        #expect(SessionControl.position(paused, polledAt: polled, now: polled.addingTimeInterval(3)) == 10)
        #expect(SessionControl.position(nil, polledAt: polled, now: polled) == 0)
    }
}
