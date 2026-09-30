import Foundation
import Testing
@testable import CascadeKit

// Ported from the desktop's test/waterfall-protocol.test.ts, plus the wire
// shape both apps must agree on.
struct WaterfallProtocolTests {
    private func playing(_ positionMs: Double, paused: Bool = false) -> WfMessage {
        Waterfall.state(serverId: "S1", trackId: "T1", positionMs: positionMs, paused: paused, now: 1_000_000)
    }

    @Test func stateStampsTheSendTime() throws {
        let m = playing(5000)
        #expect(m.k == "state" && m.sentAt == 1_000_000 && m.trackId == "T1" && m.index == nil)
        // The desktop reads these exact keys; an unset index is left out.
        let json = try #require(String(data: JSONEncoder().encode(m), encoding: .utf8))
        #expect(json.contains(#""positionMs":5000"#) && !json.contains("index"))
    }

    @Test func aPlayingPositionAgesInTransitAndAPausedOneDoesNot() {
        #expect(Waterfall.expectedPositionMs(playing(10_000), now: 1_000_300) == 10_300)
        #expect(Waterfall.expectedPositionMs(playing(10_000, paused: true), now: 1_005_000) == 10_000)
        // A clock running backwards would rewind the guest; clamped instead.
        #expect(Waterfall.expectedPositionMs(playing(10_000), now: 999_000) == 10_000)
    }

    @Test func theClockOffsetCancelsASkewedClock() {
        let skew = 3000.0
        let samples = [120.0, 40, 200, 75].map { skew + $0 }
        let offset = Waterfall.clockOffsetMs(samples)
        #expect(offset == skew + 40)
        let now = 1_000_000 + skew + 100
        #expect(Waterfall.expectedPositionMs(playing(10_000), now: now) == 13_100)
        #expect(Waterfall.expectedPositionMs(playing(10_000), now: now, offsetMs: offset) == 10_060)
        #expect(Waterfall.clockOffsetMs([]) == 0)
    }

    @Test func aSeekLeadsAPlayingHostByTheLastSeekTime() {
        #expect(Waterfall.seekTargetMs(expectedMs: 60_000, lastSeekMs: 1800, paused: false) == 61_800)
        #expect(!Waterfall.shouldReseek(currentMs: 61_800, expectedMs: 60_000 + 1800))
        #expect(Waterfall.seekTargetMs(expectedMs: 60_000, lastSeekMs: 1800, paused: true) == 60_000)
        #expect(Waterfall.seekTargetMs(expectedMs: 60_000, lastSeekMs: 60_000, paused: false) == 60_000 + Waterfall.maxSeekLeadMs)
        #expect(Waterfall.seekTargetMs(expectedMs: 60_000, lastSeekMs: -50, paused: false) == 60_000)
    }

    @Test func reseekOnlyPastTheDriftThresholdEitherWay() {
        #expect(!Waterfall.shouldReseek(currentMs: 10_000, expectedMs: 10_000 + Waterfall.driftMs - 1))
        #expect(Waterfall.shouldReseek(currentMs: 10_000, expectedMs: 10_000 + Waterfall.driftMs + 1))
        #expect(Waterfall.shouldReseek(currentMs: 10_000, expectedMs: 10_000 - Waterfall.driftMs - 1))
    }

    @Test func aForeignServerIsRefusedButAnUnknownOnePasses() {
        #expect(Waterfall.isForeignServer("A", "B"))
        #expect(!Waterfall.isForeignServer("A", "A"))
        #expect(!Waterfall.isForeignServer(nil, "A"))
        #expect(!Waterfall.isForeignServer("A", nil))
        #expect(!Waterfall.isForeignServer(nil, nil))
    }

    @Test func theSocketUrlUpgradesTheSchemeAndEncodesTheName() {
        #expect(Waterfall.roomSocketUrl(relayBase: "https://relay.test", code: "ABC123", name: "Jon")?.absoluteString
                == "wss://relay.test/room/ABC123?name=Jon")
        #expect(Waterfall.roomSocketUrl(relayBase: "http://relay.test", code: "ABC123", name: "a b&c")?.absoluteString
                == "ws://relay.test/room/ABC123?name=a%20b%26c")
        #expect(Waterfall.roomSocketUrl(relayBase: "https://relay.test//", code: "ABC123", name: "x")?.absoluteString
                == "wss://relay.test/room/ABC123?name=x")
    }

    @Test func queueAttributionIsPaddedOrTrimmedToTheTracks() {
        let padded = Waterfall.queue(serverId: "S", rev: 1, trackIds: ["a", "b", "c"], addedBy: ["Ann"], index: 0,
                                     guestAddsAllowed: true, guestControlAllowed: false)
        #expect(padded.addedBy == ["Ann", nil, nil])
        let trimmed = Waterfall.queue(serverId: "S", rev: 1, trackIds: ["a"], addedBy: ["Ann", "Bo"], index: 0,
                                      guestAddsAllowed: false, guestControlAllowed: true)
        #expect(trimmed.addedBy == ["Ann"])
        #expect(trimmed.guestAddsAllowed == false && trimmed.guestControlAllowed == true)
    }

    @Test func staleQueuesAndKnownTracksAreSkipped() {
        #expect(Waterfall.isStaleQueue(3, lastApplied: 5))
        #expect(Waterfall.isStaleQueue(5, lastApplied: 5))
        #expect(!Waterfall.isStaleQueue(6, lastApplied: 5))
        #expect(Waterfall.missingTrackIds(["a", "b", "a", "c"], known: ["b"]) == ["a", "c"])
        #expect(Waterfall.missingTrackIds(["a", "b"], known: []) == ["a", "b"])
    }

    @Test func controlCarriesAPositionOnlyForSeek() {
        #expect(Waterfall.control(.next, positionMs: 500).positionMs == nil)
        #expect(Waterfall.control(.seek, positionMs: 1234.6).positionMs == 1235)
        #expect(Waterfall.control(.seek, positionMs: -5).positionMs == 0)
        #expect(Waterfall.control(.seek, positionMs: .nan).positionMs == nil)
        #expect(Waterfall.controlAction("next") == .next)
        for bad in [nil, "", "delete", "NEXT"] { #expect(Waterfall.controlAction(bad) == nil) }
    }

    @Test func enqueueAndRejectionShapes() {
        let e = Waterfall.enqueue(serverId: "S", trackIds: ["a"])
        #expect(e.k == "enqueue" && e.trackIds == ["a"])
        #expect(Waterfall.enqueueRejected("no").reason == "no")
    }

    @Test func aDesktopStateDecodes() throws {
        let raw = #"{"k":"state","serverId":"S1","trackId":"T1","positionMs":5123,"paused":false,"sentAt":1790000000123,"index":2}"#
        let m = try JSONDecoder().decode(WfMessage.self, from: Data(raw.utf8))
        #expect(m.positionMs == 5123 && m.index == 2 && m.sentAt == 1_790_000_000_123)
        let q = #"{"k":"queue","serverId":null,"rev":4,"trackIds":["a","b"],"addedBy":[null,"Ann"],"index":1,"guestAddsAllowed":true,"guestControlAllowed":false}"#
        let queue = try JSONDecoder().decode(WfMessage.self, from: Data(q.utf8))
        #expect(queue.addedBy == [nil, "Ann"] && queue.serverId == nil)
    }

    @Test func roomCodesAreSixPlainCharacters() {
        #expect(Waterfall.normalizedCode(" abc234 ") == "ABC234")
        for bad in ["", "ABC23", "ABC2345", "AB C23", "ÄBC234"] { #expect(Waterfall.normalizedCode(bad) == nil, "\(bad)") }
    }
}
