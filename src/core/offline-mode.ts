// Offline Mode's one state (docs/offline-mode-plan.md, section 4), pure so the
// rules are tested here; the renderer holds the value and acts on changes.
//
// - 'online': the server answers.
// - 'manual': the Settings switch is on. Nothing is sent to the server at all
//   (main also blocks its origin), and it stays on until the person turns it
//   off, whatever the network does.
// - 'unreachable': the server stopped answering. Probed again on a backoff and
//   on a network change; left by itself when it answers.
//
// The Apple app's OfflineMode.swift is the same rules.

export type OfflineState = 'online' | 'manual' | 'unreachable'

export type OfflineEvent =
  | { type: 'switch', on: boolean }
  /** A request or probe found no server. */
  | { type: 'unreachable' }
  /** A request or probe was answered. */
  | { type: 'reachable' }

/** The state after an event. A manual switch outranks what the network says;
 *  turning it off goes back online, and the next request finds out whether
 *  the server is really there. */
export function nextOfflineState(state: OfflineState, event: OfflineEvent): OfflineState {
  switch (event.type) {
    case 'switch': return event.on ? 'manual' : state === 'manual' ? 'online' : state
    case 'unreachable': return state === 'online' ? 'unreachable' : state
    case 'reachable': return state === 'unreachable' ? 'online' : state
  }
}

export const isOffline = (state: OfflineState): boolean => state !== 'online'

/** First probe 30 s after the drop, doubling to five minutes. `attempt`
 *  counts from 0. */
export function probeDelayMs(attempt: number): number {
  const n = Number.isInteger(attempt) && attempt > 0 ? Math.min(attempt, 10) : 0
  return Math.min(30_000 * 2 ** n, 300_000)
}

/** What a failed request says about the server. 'unreachable' is no answer,
 *  or a reverse proxy saying the server behind it is down (502, 503, 504);
 *  'auth' is a session that expired (401, 403), which asks to sign in again
 *  and is never Offline Mode; 'error' is the server answering with a failure,
 *  which is the request's problem, not the connection's. */
export function failureKind(status: number | null | undefined): 'unreachable' | 'auth' | 'error' {
  if (status === null || status === undefined || status === 0) return 'unreachable'
  if (status === 401 || status === 403) return 'auth'
  if (status === 502 || status === 503 || status === 504) return 'unreachable'
  return 'error'
}

/** Whether main should cancel every request to the server's origin. Only the
 *  manual switch: in the unreachable state the probe has to get through. */
export const blocksServer = (state: OfflineState): boolean => state === 'manual'

/** Update checks wait while offline, and one runs as soon as the app is back
 *  online (plan, section 4). */
export const checksUpdates = (state: OfflineState): boolean => state === 'online'
export const updateCheckDue = (before: OfflineState, after: OfflineState): boolean =>
  before !== 'online' && after === 'online'
