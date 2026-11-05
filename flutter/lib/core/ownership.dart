// Who is allowed to drive playback right now: the person at the keyboard, a
// cast controller, or a Waterfall host. One place decides so they do not fight.
// Pure and state-injected. Ported from desktop/src/core/ownership.ts.

/// A snapshot of the Waterfall state the rules read.
class OwnershipState {
  /// In a Waterfall room (host or guest).
  final bool waterfallActive;
  final bool waterfallIsHost;

  /// Mid-apply of host state: the resulting playback calls are the host's, not the local user's.
  final bool waterfallApplying;

  /// The host's "let guests add to the queue" setting as last broadcast. Null means not heard yet.
  final bool? guestAddsAllowed;
  const OwnershipState({this.waterfallActive = false, this.waterfallIsHost = false, this.waterfallApplying = false, this.guestAddsAllowed});
}

/// Precedence is Waterfall over cast over local: 'waterfall' or 'local'.
String playbackOwner(OwnershipState s) => s.waterfallActive ? 'waterfall' : 'local';

/// True when local transport controls should do nothing: only guests, and not while applying the host's state.
bool blocksLocalPlayback(OwnershipState s) => s.waterfallActive && !s.waterfallIsHost && !s.waterfallApplying;

/// True when an incoming remote-control command should be acted on. Refused outright in a Waterfall room, not queued.
bool acceptsRemoteCommand(OwnershipState s) => playbackOwner(s) == 'local';

/// True when an incoming remote volume or mute command should be applied. Volume is personal, so it is refused for host and guest alike in a room. Kept apart from [acceptsRemoteCommand] on purpose.
bool acceptsRemoteVolumeCommand(OwnershipState s) => !s.waterfallActive;

/// What adding to the queue does: 'local' (mutate directly), 'propose' (ask the host) or 'blocked' (host turned guest additions off). Separate from [blocksLocalPlayback].
String queueAdditionMode(OwnershipState s) {
  if (!s.waterfallActive || s.waterfallIsHost) return 'local';
  return s.guestAddsAllowed == false ? 'blocked' : 'propose';
}
