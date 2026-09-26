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
  /** Identifies the lyric sheet the main window is showing. Sent every tick;
   *  the sheet itself only when it changes (below), since a timed sheet is
   *  tens of KB. A miniplayer holding another id asks for it again (the
   *  `sheet` command), which covers a window that opened after it was sent. */
  sheetId: number
  /** The timed sheet, present only on the tick it changed or was asked for. */
  sheet?: MiniplayerSheet
  /** Date.now() when this state was built, so the miniplayer can run its own
   *  clock between ticks: position + time since, while playing. */
  sentAt: number
  /** Upcoming tracks, from `queueStart` (their index in the main queue). */
  queue: MiniplayerQueueItem[]
  queueStart: number
  /** The Up Next toggles: shuffle, and auto-mix (keep playing similar tracks
   *  once the queue runs out). */
  shuffle: boolean
  autoMix: boolean
  /** Repeat: off, the whole queue, or the current track. */
  repeat: 'none' | 'all' | 'one'
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

export interface MiniplayerWord { Start: number, End: number | null, Text: string }
export interface MiniplayerLine { Start: number | null, End: number | null, Text: string, Words: MiniplayerWord[] | null, Background: MiniplayerWord[] | null, Opposite?: boolean }
/** A lyric sheet as the miniplayer draws it: the same shape the main window
 *  keeps (ticks), and whether held notes may swell (SpicyLyrics only). */
export interface MiniplayerSheet { lines: MiniplayerLine[], emphasis: boolean }

/** Most lyric lines sent. Far past any real song; a cap so a malformed sheet
 *  cannot grow the payload that rides on every progress tick. */
export const MINIPLAYER_LYRIC_MAX = 400

/** Upcoming tracks sent for the miniplayer's Up Next. */
export const MINIPLAYER_QUEUE_MAX = 50

/** Most words kept per line, a bound for the same reason. */
export const MINIPLAYER_WORD_MAX = 300

const tick = (v: unknown): number | null => typeof v === 'number' && Number.isFinite(v) ? v : null
const words = (list: unknown): MiniplayerWord[] | null => {
  if (!Array.isArray(list) || !list.length) return null
  const out: MiniplayerWord[] = []
  for (const w of list.slice(0, MINIPLAYER_WORD_MAX)) {
    const start = tick(w?.Start)
    if (start == null || typeof w?.Text !== 'string') continue
    out.push({ Start: start, End: tick(w.End), Text: w.Text })
  }
  return out.length ? out : null
}

/**
 * The lyric sheet as the miniplayer draws it: the main window's lines with
 * their word and background timings (for the karaoke fill), capped, and
 * stripped to the fields the drawing code reads.
 *
 * Blank lines are kept: an instrumental gap is real spacing, and dropping it
 * would also shift every later line's index. Only the trailing run is
 * trimmed, so a song ending in padding does not scroll into emptiness.
 */
export function miniplayerSheet(lines: unknown, emphasis: boolean): MiniplayerSheet {
  const src = Array.isArray(lines) ? lines.slice(0, MINIPLAYER_LYRIC_MAX) : []
  const out: MiniplayerLine[] = src.map(l => ({
    Start: tick(l?.Start),
    End: tick(l?.End),
    Text: typeof l?.Text === 'string' ? l.Text.trim() : '',
    Words: words(l?.Words),
    Background: words(l?.Background),
    ...(l?.Opposite === true ? { Opposite: true } : {}),
  }))
  let end = out.length
  while (end > 0 && !out[end - 1].Text && !out[end - 1].Words) end--
  return { lines: out.slice(0, end), emphasis: !!emphasis }
}

/** The only actions the miniplayer window may ask the main window to take.
 *  Deliberately a closed set - anything else is a message this app does not
 *  understand and must be ignored rather than forwarded to `.click()`. */
export type MiniplayerAction = 'playpause' | 'next' | 'prev' | 'like' | 'shuffle' | 'automix' | 'repeat'

const MINIPLAYER_ACTIONS: ReadonlySet<string> = new Set(['playpause', 'next', 'prev', 'like', 'shuffle', 'automix', 'repeat'])

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
  | { type: 'sheet' }

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
  // "Send the lyric sheet again": the miniplayer holds a sheetId it has no sheet for.
  if (type === 'sheet' && value === 0) return { type: 'sheet' }
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
  sheetId = 0,
  extra: {
    isFavorite?: boolean, volume?: number,
    credit?: { provider?: unknown, uploader?: { name?: unknown } | null, maker?: { name?: unknown } | null } | null,
    sheet?: MiniplayerSheet | null, queue?: MiniplayerQueueItem[], queueStart?: number, now?: number,
    shuffle?: boolean, autoMix?: boolean, repeat?: unknown,
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
    sheetId: Number.isInteger(sheetId) ? sheetId : 0,
    ...(extra.sheet ? { sheet: extra.sheet } : {}),
    sentAt: Number.isFinite(extra.now) ? extra.now as number : Date.now(),
    shuffle: !!extra.shuffle,
    autoMix: !!extra.autoMix,
    repeat: extra.repeat === 'all' || extra.repeat === 'one' ? extra.repeat : 'none',
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
