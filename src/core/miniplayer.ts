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
  /** The whole lyric sheet, cleaned (see miniplayerLyrics), so the lyrics
   *  can be scrolled back through. */
  lyrics: string[]
  /** The line being sung, an index into `lyrics`; -1 when none is. */
  lyricIndex: number
  /** Upcoming tracks, from `queueStart` (their index in the main queue). */
  queue: MiniplayerQueueItem[]
  queueStart: number
  /** Whether the current track is a favorite, for the heart button. */
  isFavorite: boolean
  /** 0-1, the user's volume (not a mid-crossfade deck level). */
  volume: number
  /** SpicyLyrics credit for the lyrics shown, or null for any other source.
   *  Names only: the links stay in the main window, which opens them when
   *  the miniplayer sends a `credit` command. */
  credit: MiniplayerCredit | null
}

export interface MiniplayerCredit { provider: string, uploader: string | null, maker: string | null }

export interface MiniplayerQueueItem { title: string, subtitle: string, artUrl: string | null }

/** Most lyric lines sent. Far past any real song; a cap so a malformed sheet
 *  cannot grow the payload that rides on every progress tick. */
export const MINIPLAYER_LYRIC_MAX = 400

/** Upcoming tracks sent for the miniplayer's Up Next. */
export const MINIPLAYER_QUEUE_MAX = 50

/**
 * The lyric sheet as the miniplayer shows it: text only, capped.
 *
 * Blank lines are kept, not dropped: an instrumental gap is real spacing in a
 * lyric sheet, and dropping them would also shift every index after the gap
 * off the line the clock says is current. Only the trailing run is trimmed,
 * so a song ending in padding does not scroll into emptiness.
 */
export function miniplayerLyrics(lines: { Text?: string | null }[] | null | undefined): string[] {
  if (!Array.isArray(lines) || !lines.length) return []
  const out = lines.slice(0, MINIPLAYER_LYRIC_MAX).map(l => (l?.Text ?? '').trim())
  let end = out.length
  while (end > 0 && out[end - 1] === '') end--
  return out.slice(0, end)
}

/** The only actions the miniplayer window may ask the main window to take.
 *  Deliberately a closed set - anything else is a message this app does not
 *  understand and must be ignored rather than forwarded to `.click()`. */
export type MiniplayerAction = 'playpause' | 'next' | 'prev' | 'like'

const MINIPLAYER_ACTIONS: ReadonlySet<string> = new Set(['playpause', 'next', 'prev', 'like'])

export function isMiniplayerAction(value: unknown): value is MiniplayerAction {
  return typeof value === 'string' && MINIPLAYER_ACTIONS.has(value)
}

/** A validated control message. The two with a value arrive as
 *  `{ type, value }`; everything else is a bare action string. */
export type MiniplayerCommand =
  | { type: MiniplayerAction }
  | { type: 'seek', fraction: number }
  | { type: 'volume', delta: number }
  | { type: 'credit', who: 'uploader' | 'maker' }
  | { type: 'jump', index: number }

/** Largest volume step one message may ask for. A wheel tick sends a few
 *  percent; anything bigger is a bug or a hostile page, not a gesture. */
export const MINIPLAYER_MAX_VOLUME_STEP = 0.2

/**
 * Turns whatever came over IPC into a command, or null to ignore it. The
 * miniplayer is a separate page, so its messages are input like any other:
 * a seek outside 0-1 or a NaN volume step must never reach seekTo() or
 * setVolumeRatio().
 */
export function parseMiniplayerCommand(raw: unknown): MiniplayerCommand | null {
  if (isMiniplayerAction(raw)) return { type: raw }
  if (!raw || typeof raw !== 'object') return null
  const { type, value } = raw as { type?: unknown, value?: unknown }
  if (typeof value !== 'number' || !Number.isFinite(value)) return null
  if (type === 'seek') return { type: 'seek', fraction: Math.max(0, Math.min(1, value)) }
  if (type === 'volume') {
    const m = MINIPLAYER_MAX_VOLUME_STEP
    return { type: 'volume', delta: Math.max(-m, Math.min(m, value)) }
  }
  if (type === 'credit' && (value === 0 || value === 1)) return { type: 'credit', who: value === 0 ? 'uploader' : 'maker' }
  // A queue position; whether it exists is the receiver's call, it owns the queue.
  if (type === 'jump' && Number.isInteger(value) && value >= 0) return { type: 'jump', index: value }
  return null
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
  lyrics: string[] = [],
  extra: {
    isFavorite?: boolean, volume?: number,
    credit?: { provider?: unknown, uploader?: { name?: unknown } | null, maker?: { name?: unknown } | null } | null,
    lyricIndex?: number, queue?: MiniplayerQueueItem[], queueStart?: number,
  } = {},
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
    lyrics: Array.isArray(lyrics) ? lyrics : [],
    lyricIndex: Number.isInteger(extra.lyricIndex) && Array.isArray(lyrics)
      ? Math.max(-1, Math.min(lyrics.length - 1, extra.lyricIndex as number)) : -1,
    queue: Array.isArray(extra.queue) ? extra.queue.slice(0, MINIPLAYER_QUEUE_MAX) : [],
    queueStart: Number.isInteger(extra.queueStart) && (extra.queueStart as number) >= 0 ? extra.queueStart as number : 0,
    isFavorite: !!extra.isFavorite,
    volume: Number.isFinite(extra.volume) ? Math.max(0, Math.min(1, extra.volume as number)) : 1,
    credit: miniplayerCredit(extra.credit),
  }
}

function creditName(v: unknown): string | null {
  return typeof v === 'string' && v.trim() ? v.trim().slice(0, 80) : null
}

/** The credit trimmed to what the miniplayer draws. Null unless there is a
 *  provider name, since the provider is the one part always required. */
export function miniplayerCredit(c: { provider?: unknown, uploader?: { name?: unknown } | null, maker?: { name?: unknown } | null } | null | undefined): MiniplayerCredit | null {
  const provider = creditName(c?.provider)
  if (!provider) return null
  return { provider, uploader: creditName(c?.uploader?.name), maker: creditName(c?.maker?.name) }
}
