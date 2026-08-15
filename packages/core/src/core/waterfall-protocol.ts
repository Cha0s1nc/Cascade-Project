// Waterfall wire format and sync maths.
//
// Waterfall keeps a room in sync without any audio crossing the wire: every
// member streams the same track from the same Jellyfin server, and the room only
// carries "track X, position Y, playing/paused".
//
// Only the protocol lives here. The room panel, the modal and the transport
// interception stay in waterfall.js - they are DOM, and a TV client would draw
// them completely differently.

/** Host re-announces its position this often. */
/**
 * The signalling relay every client falls back to.
 *
 * Lives here rather than in each host because both apps have to agree: two
 * clients pointed at different relays cannot see each other's rooms, and the
 * failure looks like "the code does not work" rather than a misconfiguration.
 */
export const WF_DEFAULT_RELAY = 'https://cascade-waterfall-signaling.cha0s-netw0rks.workers.dev'

export const WF_HEARTBEAT_MS = 4000

/** A guest re-seeks once it is at least this far out. */
export const WF_DRIFT_MS = 1500

export interface WfStateMessage {
  k: 'state'
  serverId: string | null
  trackId: string
  positionMs: number
  paused: boolean
  /** Sender's wall clock, used to age the position in transit. */
  sentAt: number
  /**
   * The host's queueIndex, riding the heartbeat.
   *
   * Skipping tracks changes the index but not the queue contents, so without
   * this every skip would have to re-broadcast the whole track list. Optional
   * so a client that predates it still parses; guests fall back to locating
   * `trackId` in the queue, which is only ambiguous when the same track appears
   * twice.
   */
  index?: number
}

export interface WfHelloMessage {
  k: 'hello'
  serverId: string | null
}

export interface WfWrongServerMessage {
  k: 'wrong-server'
}

/**
 * The shared queue, host -> everyone.
 *
 * Sent only when the queue changes, never on the heartbeat: a 500-track queue is
 * ~18KB of ids, and re-broadcasting that every 4 seconds to every member would
 * be pure waste. Position and pause continue to ride on `state`.
 */
export interface WfQueueMessage {
  k: 'queue'
  serverId: string | null
  /** Monotonic, bumped by the host on every queue mutation. See isStaleQueue. */
  rev: number
  trackIds: string[]
  /** Parallel to trackIds. Display name of the guest who added an entry, or null
   *  for the host's own. Names rather than member ids: ids are per-connection
   *  UUIDs that change on reconnect, which would strand the label. */
  addedBy: (string | null)[]
  /** The host's queueIndex. Guests mirror it, so their arrays must stay aligned. */
  index: number
  /** Host's "let guests add to the queue" setting, so guests know whether to
   *  offer the action at all. */
  guestAddsAllowed: boolean
  /** Host's "let guests control playback" setting. Separate permission: adding a
   *  track is additive, but pausing or skipping interrupts everyone. */
  guestControlAllowed: boolean
}

/** What a guest may ask the host to do to the transport. */
export type WfControlAction = 'playpause' | 'next' | 'prev' | 'seek'

/**
 * Guest -> host transport request.
 *
 * The host stays the single owner of playback: it applies the action locally and
 * the resulting `state` broadcast is what actually moves everyone. Guests never
 * drive their own element directly, so the room cannot fork.
 */
export interface WfControlMessage {
  k: 'control'
  action: WfControlAction
  /** Only for `seek`. */
  positionMs?: number
}

/** Guest -> host. Append-only: guests cannot reorder, remove, or jump the line. */
export interface WfEnqueueMessage {
  k: 'enqueue'
  serverId: string | null
  trackIds: string[]
}

/** Host -> the requesting guest. Sent instead of dropping a request silently. */
export interface WfEnqueueRejectedMessage {
  k: 'enqueue-rejected'
  reason: string
}

export type WfMessage =
  | WfStateMessage
  | WfHelloMessage
  | WfWrongServerMessage
  | WfQueueMessage
  | WfEnqueueMessage
  | WfEnqueueRejectedMessage
  | WfControlMessage

export function buildStateMessage(input: {
  serverId: string | null
  trackId: string
  positionMs: number
  paused: boolean
  index?: number
  now?: number
}): WfStateMessage {
  return {
    k: 'state',
    serverId: input.serverId,
    trackId: input.trackId,
    positionMs: input.positionMs,
    paused: input.paused,
    ...(input.index === undefined ? {} : { index: input.index }),
    sentAt: input.now ?? Date.now(),
  }
}

export function buildQueueMessage(input: {
  serverId: string | null
  rev: number
  trackIds: string[]
  addedBy?: (string | null)[]
  index: number
  guestAddsAllowed: boolean
  guestControlAllowed: boolean
}): WfQueueMessage {
  const trackIds = [...input.trackIds]
  return {
    k: 'queue',
    serverId: input.serverId,
    rev: input.rev,
    trackIds,
    // Normalised to the same length here so a caller whose parallel array has
    // drifted cannot ship a misaligned attribution list.
    addedBy: alignAddedBy(input.addedBy, trackIds.length),
    index: input.index,
    guestAddsAllowed: input.guestAddsAllowed,
    guestControlAllowed: input.guestControlAllowed,
  }
}

const CONTROL_ACTIONS: readonly WfControlAction[] = ['playpause', 'next', 'prev', 'seek']

export function buildControlMessage(action: WfControlAction, positionMs?: number): WfControlMessage {
  return {
    k: 'control',
    action,
    ...(action === 'seek' && Number.isFinite(positionMs) ? { positionMs: Math.max(0, Math.round(positionMs!)) } : {}),
  }
}

/** Reject anything that is not a known action before acting on it - this arrives
 *  from another client, so it is a trust boundary. */
export function isControlAction(value: unknown): value is WfControlAction {
  return typeof value === 'string' && (CONTROL_ACTIONS as readonly string[]).includes(value)
}

export function buildEnqueueMessage(input: {
  serverId: string | null
  trackIds: string[]
}): WfEnqueueMessage {
  return { k: 'enqueue', serverId: input.serverId, trackIds: [...input.trackIds] }
}

export function buildEnqueueRejected(reason: string): WfEnqueueRejectedMessage {
  return { k: 'enqueue-rejected', reason }
}

/** Pad or trim an attribution list to match its track list. */
function alignAddedBy(addedBy: (string | null)[] | undefined, length: number): (string | null)[] {
  const out = (addedBy || []).slice(0, length)
  while (out.length < length) out.push(null)
  return out
}

/**
 * Whether an arriving queue message is older than what we already applied.
 *
 * `state` and `queue` travel independently over the relay, so a delayed queue
 * broadcast can arrive after a newer one. Without this guard it would clobber
 * the newer queue and the guest would show a stale list until the next change.
 */
export function isStaleQueue(incomingRev: number, lastAppliedRev: number): boolean {
  return incomingRev <= lastAppliedRev
}

/**
 * Which of the host's track ids this member has no metadata for yet.
 *
 * Guests resolve these in one batched lookup rather than per track.
 */
export function missingTrackIds(trackIds: string[], knownIds: Iterable<string>): string[] {
  const known = new Set(knownIds)
  const out: string[] = []
  for (const id of trackIds) {
    if (known.has(id) || out.includes(id)) continue
    out.push(id)
  }
  return out
}

/**
 * Where the host should be *now*, accounting for time spent in transit.
 *
 * ponytail: one-way latency is approximated as the full elapsed time since
 * `sentAt` and never re-estimated. Good to a few hundred ms, which is fine for
 * people in different rooms. Swap in a clock-offset handshake if it matters.
 */
export function expectedPositionMs(state: WfStateMessage, now: number = Date.now()): number {
  const latency = Math.max(0, now - (state.sentAt || now))
  return (state.positionMs || 0) + (state.paused ? 0 : latency)
}

/**
 * Whether a guest is far enough out to be worth re-seeking.
 *
 * Threshold rather than continuous correction on purpose: nudging every tick
 * would be audible, and being a few hundred ms out is not.
 */
export function shouldReseek(
  currentMs: number,
  expectedMs: number,
  driftMs: number = WF_DRIFT_MS,
): boolean {
  return Math.abs(currentMs - expectedMs) > driftMs
}

/**
 * Whether a peer belongs in this room.
 *
 * Members on a different Jellyfin server cannot stream the host's tracks, so the
 * room refuses rather than half-working. Unknown ids pass: an older client that
 * never sends one should not be locked out.
 */
export function isForeignServer(
  peerServerId: string | null | undefined,
  ownServerId: string | null | undefined,
): boolean {
  if (!peerServerId || !ownServerId) return false
  return peerServerId !== ownServerId
}

/** Relay base (http) to room socket URL (ws), with the display name attached. */
export function roomSocketUrl(relayBase: string, code: string, name: string): string {
  const base = relayBase.replace(/\/+$/, '').replace(/^http/, 'ws')
  return `${base}/room/${code}?name=${encodeURIComponent(name)}`
}
