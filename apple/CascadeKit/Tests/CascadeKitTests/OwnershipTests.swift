import Testing
@testable import CascadeKit

// The desktop's test/ownership.test.ts, ported case for case.
struct OwnershipTests {
    private func state(active: Bool = false, host: Bool = false, applying: Bool = false,
                       adds: Bool? = nil) -> OwnershipState {
        OwnershipState(waterfallActive: active, waterfallIsHost: host, waterfallApplying: applying, guestAddsAllowed: adds)
    }

    @Test func nobodyInARoomTheLocalUserOwnsPlayback() {
        let s = state()
        #expect(Ownership.owner(s) == .local)
        #expect(!Ownership.blocksLocalPlayback(s))
        #expect(Ownership.acceptsRemoteCommand(s))
    }

    @Test func guestControlsAreInert() {
        let s = state(active: true)
        #expect(Ownership.owner(s) == .waterfall)
        #expect(Ownership.blocksLocalPlayback(s))
    }

    @Test func hostControlsStayLive() {
        #expect(!Ownership.blocksLocalPlayback(state(active: true, host: true)))
    }

    @Test func guestApplyingHostStateIsNotBlocked() {
        #expect(!Ownership.blocksLocalPlayback(state(active: true, applying: true)))
    }

    @Test func castIsRefusedInARoomHostOrGuest() {
        #expect(!Ownership.acceptsRemoteCommand(state(active: true, host: true)))
        #expect(!Ownership.acceptsRemoteCommand(state(active: true)))
    }

    @Test func waterfallOutranksCast() {
        #expect(Ownership.owner(state(active: true)) == .waterfall)
    }

    @Test func remoteVolume() {
        #expect(Ownership.acceptsRemoteVolumeCommand(state()))
        #expect(!Ownership.acceptsRemoteVolumeCommand(state(active: true, host: true)))
        #expect(!Ownership.acceptsRemoteVolumeCommand(state(active: true)))
        // Applying host state is no escape hatch for volume.
        #expect(!Ownership.acceptsRemoteVolumeCommand(state(active: true, applying: true)))
    }

    @Test func queueAdditions() {
        #expect(Ownership.queueAdditionMode(state()) == .local)
        #expect(Ownership.queueAdditionMode(state(active: true, host: true)) == .local)
        // A host is never restricted by its own toggle.
        #expect(Ownership.queueAdditionMode(state(active: true, host: true, adds: false)) == .local)
        #expect(Ownership.queueAdditionMode(state(active: true, adds: true)) == .propose)
        #expect(Ownership.queueAdditionMode(state(active: true, adds: false)) == .blocked)
        // Unheard toggle fails open.
        #expect(Ownership.queueAdditionMode(state(active: true)) == .propose)
    }

    @Test func additionsStayIndependentOfPlaybackBlocking() {
        let s = state(active: true, adds: true)
        #expect(Ownership.blocksLocalPlayback(s))
        #expect(Ownership.queueAdditionMode(s) == .propose)
    }
}
