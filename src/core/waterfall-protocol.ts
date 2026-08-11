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
}

export interface WfHelloMessage {
  k: 'hello'
  serverId: string | null
}

export interface WfWrongServerMessage {
  k: 'wrong-server'
}

export type WfMessage = WfStateMessage | WfHelloMessage | WfWrongServerMessage

export function buildStateMessage(input: {
  serverId: string | null
  trackId: string
  positionMs: number
  paused: boolean
  now?: number
}): WfStateMessage {
  return {
    k: 'state',
    serverId: input.serverId,
    trackId: input.trackId,
    positionMs: input.positionMs,
    paused: input.paused,
    sentAt: input.now ?? Date.now(),
  }
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
