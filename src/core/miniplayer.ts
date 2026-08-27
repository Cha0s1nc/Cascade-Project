// The miniplayer is a remote control view, not a second player - see
// CODEMAP.md. Audio keeps playing from the two <video> decks in the main
// window; only a state snapshot crosses IPC to the small always-on-top
// window, and only a handful of control actions cross back.
//
// The one piece of that worth pulling out as pure logic is the arithmetic:
// position/duration reach here from a media element and a Jellyfin item,
// neither of which this module or its window can be trusted to have handed
// over clean (a mid-seek NaN, a duration of 0 before metadata loads). Store
// values are untrusted elsewhere in this codebase for the same reason - a
// corrupted read must never reach the UI as NaN or a percentage outside 0-100.

/** What the miniplayer window renders. Built in the main window, sent
 *  over IPC, never mutated in place - a stale snapshot must never be
 *  patched into a valid one. */
export interface MiniplayerState {
  itemId: string | null
  title: string
  subtitle: string
  artUrl: string | null
  isPlaying: boolean
  positionSec: number
  durationSec: number
  /** 0-100, always in range even when duration is unknown. */
  progressPct: number
}

/** The only actions the miniplayer window may ask the main window to take.
 *  Deliberately a closed set - anything else is a message this app does not
 *  understand and must be ignored rather than forwarded to `.click()`. */
export type MiniplayerAction = 'playpause' | 'next' | 'prev'

const MINIPLAYER_ACTIONS: ReadonlySet<string> = new Set(['playpause', 'next', 'prev'])

export function isMiniplayerAction(value: unknown): value is MiniplayerAction {
  return typeof value === 'string' && MINIPLAYER_ACTIONS.has(value)
}

/** Safe 0-100 progress. Guards both a not-yet-known duration (0, or not a
 *  finite number) and a position past it (a stale timeupdate racing a track
 *  change), either of which would otherwise reach the UI as NaN or a bar
 *  wider than its track. */
export function miniplayerProgressPct(positionSec: number, durationSec: number): number {
  if (!Number.isFinite(positionSec) || !Number.isFinite(durationSec) || durationSec <= 0) return 0
  return Math.max(0, Math.min(100, (positionSec / durationSec) * 100))
}

/**
 * Assemble the state snapshot sent to the miniplayer window.
 *
 * Takes already-resolved display strings and an art URL rather than a raw
 * Jellyfin item - picking Name vs AlbumArtist vs Artists[0] is exactly what
 * secondaryLine() in renderer.js already does for the status bar and the
 * overlay, and this is not a second place to get that fallback chain wrong.
 */
export function buildMiniplayerState(
  track: { itemId: string | null, title: string, subtitle: string, artUrl: string | null },
  isPlaying: boolean,
  positionSec: number,
  durationSec: number,
): MiniplayerState {
  const safePos = Number.isFinite(positionSec) && positionSec > 0 ? positionSec : 0
  const safeDur = Number.isFinite(durationSec) && durationSec > 0 ? durationSec : 0
  return {
    itemId: track.itemId,
    title: track.title,
    subtitle: track.subtitle,
    artUrl: track.artUrl,
    isPlaying: !!isPlaying,
    positionSec: safePos,
    durationSec: safeDur,
    progressPct: miniplayerProgressPct(safePos, safeDur),
  }
}
