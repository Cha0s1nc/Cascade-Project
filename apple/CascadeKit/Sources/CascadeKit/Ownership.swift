import Foundation

// Who may drive playback right now: the desktop's src/core/ownership.ts.
//
// Three things can issue playback commands: the person at the keyboard, a
// Jellyfin controller casting to us (RemoteControl), and a Waterfall host.
// Without one place deciding, they fight, and each mechanism looks correct
// on its own. Pure and state-injected: the caller hands in a snapshot.

public enum PlaybackOwner: String, Sendable {
    case local, cast, waterfall
}

public struct OwnershipState: Sendable, Equatable {
    /// In a Waterfall room, host or guest.
    public var waterfallActive = false
    public var waterfallIsHost = false
    /// Mid-apply of host state: those playback calls are the host's, not the
    /// local user's, so they must not be blocked.
    public var waterfallApplying = false
    /// The host's "let guests add to the queue", as last heard. Nil before a
    /// guest has heard it. The host is never restricted by its own toggle.
    public var guestAddsAllowed: Bool?

    public init(waterfallActive: Bool = false, waterfallIsHost: Bool = false,
                waterfallApplying: Bool = false, guestAddsAllowed: Bool? = nil) {
        self.waterfallActive = waterfallActive
        self.waterfallIsHost = waterfallIsHost
        self.waterfallApplying = waterfallApplying
        self.guestAddsAllowed = guestAddsAllowed
    }
}

/// What the local user adding to the queue does: mutate it, ask the host,
/// or nothing because the host turned guest additions off.
public enum QueueAdditionMode: String, Sendable {
    case local, propose, blocked
}

public enum Ownership {
    /// Waterfall outranks cast outranks local. A room is an explicit, shared
    /// session; letting a cast retarget one member would desync everyone.
    public static func owner(_ s: OwnershipState) -> PlaybackOwner {
        s.waterfallActive ? .waterfall : .local
    }

    /// Only a guest is blocked, and not while it applies the host's state.
    public static func blocksLocalPlayback(_ s: OwnershipState) -> Bool {
        s.waterfallActive && !s.waterfallIsHost && !s.waterfallApplying
    }

    /// Refused outright in a room rather than queued: a command that applies
    /// silently after the room ends is worse than one that does nothing now.
    public static func acceptsRemoteCommand(_ s: OwnershipState) -> Bool {
        owner(s) == .local
    }

    /// Volume is personal, so a room blocks it for host and guest alike. Its
    /// own rule rather than acceptsRemoteCommand: loosening transport for a
    /// host later must not reopen this.
    public static func acceptsRemoteVolumeCommand(_ s: OwnershipState) -> Bool {
        !s.waterfallActive
    }

    /// Separate from blocksLocalPlayback: a guest may not start playback but
    /// may ask the host to queue something. An unheard toggle fails open.
    public static func queueAdditionMode(_ s: OwnershipState) -> QueueAdditionMode {
        guard s.waterfallActive, !s.waterfallIsHost else { return .local }
        return s.guestAddsAllowed == false ? .blocked : .propose
    }
}
