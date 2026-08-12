// Who is allowed to drive playback right now.
//
// Three things can issue playback commands once remote control exists: the
// person at the keyboard, a Jellyfin controller casting to us, and a Waterfall
// host. Without one place deciding, they fight - and those bugs are miserable,
// because each mechanism looks correct in isolation.
//
// This generalises what wfBlocksLocalPlayback() already did for Waterfall alone,
// rather than adding a second parallel mechanism next to it.
//
// Pure and state-injected: the actual state lives in waterfall.js and
// renderer.js, which pass a snapshot in.

export type PlaybackOwner = 'local' | 'cast' | 'waterfall'

export interface OwnershipState {
  /** In a Waterfall room (host or guest). */
  waterfallActive: boolean
  waterfallIsHost: boolean
  /** Mid-apply of host state: the resulting playback calls are the host's, not
   *  the local user's, so they must not be blocked. */
  waterfallApplying: boolean
  /** Host's "let guests add to the queue" setting, as last broadcast. Only
   *  meaningful for a guest; the host is never restricted by its own toggle. */
  guestAddsAllowed?: boolean
}

/**
 * What happens when the local user adds a track to the queue.
 *
 * - `local`   - mutate the queue directly (solo, or the host, who then broadcasts)
 * - `propose` - send an enqueue request to the host and do NOT mutate locally;
 *               a guest's local mutation would be wiped by the next broadcast
 * - `blocked` - the host has guest additions turned off
 */
export type QueueAdditionMode = 'local' | 'propose' | 'blocked'

/**
 * Precedence: **Waterfall > cast > local**.
 *
 * A Waterfall room is an explicit, shared, opt-in session. Letting a cast
 * command retarget one member's playback would desync the room for everybody,
 * so the room wins while it is running.
 */
export function playbackOwner(s: OwnershipState): PlaybackOwner {
  if (s.waterfallActive) return 'waterfall'
  return 'local'
}

/**
 * True when local transport controls should do nothing.
 *
 * Only guests are blocked: the host drives the room, so their own controls stay
 * live. `waterfallApplying` is the escape hatch for playback the guest performs
 * *because* the host said so.
 */
export function blocksLocalPlayback(s: OwnershipState): boolean {
  return s.waterfallActive && !s.waterfallIsHost && !s.waterfallApplying
}

/**
 * True when an incoming remote-control command should be acted on.
 *
 * Refused outright in a Waterfall room rather than queued: a command that
 * silently applies later, after the room ends, is worse than one that visibly
 * does nothing now.
 */
export function acceptsRemoteCommand(s: OwnershipState): boolean {
  return playbackOwner(s) === 'local'
}

/**
 * Adding to the queue is deliberately separate from `blocksLocalPlayback`.
 *
 * A guest may never *start* playback - that stays blocked - but appending to the
 * shared queue is a request the host can honour. Collapsing the two is what
 * makes a guest's "Add to queue" look like it worked and then vanish on the next
 * host broadcast.
 */
export function queueAdditionMode(s: OwnershipState): QueueAdditionMode {
  if (!s.waterfallActive) return 'local'
  if (s.waterfallIsHost) return 'local'
  return s.guestAddsAllowed === false ? 'blocked' : 'propose'
}
