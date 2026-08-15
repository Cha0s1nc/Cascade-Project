// Where lyrics come from, and which answer wins.
//
// Lifted out of apps/desktop/renderer.js's fetchLyricsWaterfall (~4830). The
// parsing already lived in core (lyrics.ts); this is the fetching and the
// priority rules around it, which the React Native app needs to behave the same
// way rather than approximately.
//
// Sources are raced, not tried in turn: they are independent services with
// independent latency, and asking them one after another would make the slow
// path the sum of all of them. Priority is applied to the results, not the
// requests.

import { parseLRC, parseKrc } from './lyrics.ts'
import type { LyricLine } from './lyrics.ts'
import type { JfItem } from './types.ts'

/** How long any one source gets before it is treated as a failure. */
export const LYRICS_TIMEOUT_MS = 8000

/** Named so a UI can show which source answered, and which were tried. */
export type LyricsSourceName = 'Kugou' | 'LRCLIB' | 'Jellyfin' | 'Cascade'

/** What the caller may pin the search to. 'auto' races everything. */
export type ForcedSource = 'auto' | 'Kugou' | 'LRCLIB' | 'Jellyfin' | 'cascade-karaoke' | 'cascade-synced'

export interface LyricsResult {
  lines: LyricLine[]
  /** Display label, e.g. "LRCLIB (plain)" or "Karaoke". */
  source: string
  /** Per-source outcome, for a "why did I get this" UI. */
  tried: Partial<Record<string, 'ok' | 'fail'>>
}

/** Some tracks genuinely have no words, which is not the same as a failure. */
export interface Instrumental {
  instrumental: true
}

export type LyricsLookup = LyricsResult | Instrumental | null

export function isInstrumental(r: LyricsLookup): r is Instrumental {
  return !!r && 'instrumental' in r
}

/** What a host has to supply. Only Kugou differs between the two. */
export interface LyricsDeps {
  serverUrl: string
  token: string
  /**
   * Kugou's KRC, already decrypted, or null.
   *
   * Injected rather than implemented here because the decryption needs a zlib
   * inflate, and the two hosts have entirely different ones - Electron reaches
   * node's zlib through IPC, React Native uses pako in-process. `decodeKrc`
   * below does the shared half.
   */
  getKugouKrc?: (q: { title: string; artist: string; durationMs: number }) => Promise<string | null>
}

export interface LyricsOptions {
  /** Pin to one source; 'auto' or omitted races them. */
  forced?: ForcedSource
  /** Fetch exclusively from the Cascade Jellyfin plugin. */
  serverOnly?: boolean
}

/**
 * Lines that are credits or a repeated title, not lyrics.
 *
 * Built per item because it matches the track's own name as a prefix. The
 * CJK alternatives are the same credit words - lyricist, composer, arranger -
 * which Kugou in particular embeds at the top of nearly every result.
 */
export function metaPattern(itemName: string): RegExp {
  const escaped = itemName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(
    [
      `^${escaped}\\s*-\\s*`,
      '^(composed|written|produced|arranged|performed|lyrics|music|words|publisher|作词|作曲|编曲|编词|制作人)\\s*(by)?\\s*[:：]',
    ].join('|'),
    'i',
  )
}

// ---------------------------------------------------------------------------
// KRC
// ---------------------------------------------------------------------------

/** Kugou's fixed XOR key. Not a secret - it ships in every client. */
const KRC_KEY = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

/**
 * base64 -> bytes, without atob or Buffer.
 *
 * Written out because neither global is dependable: Hermes has no Buffer, and
 * relying on atob would be one more thing that works in a test under Node and
 * throws on a device.
 */
export function base64ToBytes(b64: string): Uint8Array {
  const clean = b64.replace(/[^A-Za-z0-9+/]/g, '')
  const out = new Uint8Array((clean.length * 3) >> 2)
  let acc = 0
  let bits = 0
  let o = 0
  for (let i = 0; i < clean.length; i++) {
    const v = B64.indexOf(clean[i] as string)
    if (v < 0) continue
    acc = (acc << 6) | v
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out[o++] = (acc >> bits) & 0xff
    }
  }
  return out.subarray(0, o)
}

/**
 * Kugou's encrypted KRC payload -> plain KRC text.
 *
 * Skip the 4-byte 'krc1' magic, XOR against the fixed key, inflate. `inflate`
 * is injected and must return a string: pako can decode UTF-8 itself with
 * `{ to: 'string' }`, and node's zlib pairs with `.toString('utf8')` - which is
 * the whole reason it is not done here, since Hermes has no TextDecoder to do
 * it with.
 */
export function decodeKrc(contentBase64: string, inflate: (bytes: Uint8Array) => string): string {
  const encrypted = base64ToBytes(contentBase64)
  const raw = encrypted.subarray(4)
  const decrypted = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) {
    decrypted[i] = (raw[i] as number) ^ (KRC_KEY[i % 16] as number)
  }
  return inflate(decrypted)
}

// ---------------------------------------------------------------------------
// The waterfall
// ---------------------------------------------------------------------------

const CACHE_LIMIT = 50
const cache = new Map<string, LyricsLookup>()

function cachePut(id: string, result: LyricsLookup): void {
  if (cache.size >= CACHE_LIMIT) {
    const oldest = cache.keys().next().value
    if (oldest !== undefined) cache.delete(oldest)
  }
  cache.set(id, result)
}

/** Drop one item, or everything. Called when a user edits or re-picks a source. */
export function clearLyricsCache(itemId?: string): void {
  if (itemId) cache.delete(itemId)
  else cache.clear()
}

const isAbort = (e: unknown): boolean => {
  const name = (e as { name?: string })?.name
  return name === 'AbortError' || name === 'TimeoutError'
}

/**
 * An abort signal that fires after `ms`.
 *
 * Built from AbortController rather than AbortSignal.timeout, which is a recent
 * static that Chromium has and Hermes does not - it would have typechecked fine
 * and thrown on the first fetch from a device.
 */
export function timeoutSignal(ms: number = LYRICS_TIMEOUT_MS): AbortSignal {
  const controller = new AbortController()
  setTimeout(() => controller.abort(), ms)
  return controller.signal
}

function timeout(): RequestInit {
  return { signal: timeoutSignal() }
}

function artistOf(item: JfItem): string {
  return item.AlbumArtist || item.Artists?.[0] || ''
}

/**
 * Find lyrics for a track.
 *
 * Returns null when nothing was found, an Instrumental marker when a source
 * says the track has no words, and otherwise the winning lines plus which
 * sources were tried.
 *
 * A forced source is never cached: the point of forcing one is to re-ask, and
 * serving a cached answer would make the control look broken.
 */
export async function fetchLyricsWaterfall(
  deps: LyricsDeps,
  item: JfItem,
  options: LyricsOptions = {},
): Promise<LyricsLookup> {
  const forcedRaw = options.forced && options.forced !== 'auto' ? options.forced : null

  if (!forcedRaw) {
    const hit = cache.get(item.Id)
    if (hit !== undefined) return hit
  }

  const meta = metaPattern(item.Name || '')
  const keep = (lines: LyricLine[]) => lines.filter(l => !meta.test(l.Text))

  if (options.serverOnly) {
    return fetchFromCascadePlugin(deps, item, forcedRaw, keep)
  }

  const sources: [LyricsSourceName, () => Promise<LyricsResult | Instrumental | null>][] = [
    ['Kugou', async () => {
      if (!deps.getKugouKrc) return null
      const krc = await deps.getKugouKrc({
        title: item.Name || '',
        artist: artistOf(item),
        durationMs: (item.RunTimeTicks || 0) / 10_000,
      })
      if (!krc) return null
      const lines = keep(parseKrc(krc))
      // Only worth winning if it actually carries word-level timing; without
      // that LRCLIB's line-level result is just as good and usually cleaner.
      if (!lines.length || !lines.some(l => (l.Words?.length ?? 0) > 0)) return null
      return { lines, source: 'Kugou', tried: {} }
    }],
    ['LRCLIB', async () => {
      const q = new URLSearchParams({
        artist_name: artistOf(item),
        track_name: item.Name || '',
        album_name: item.Album || '',
        duration: String(Math.round((item.RunTimeTicks || 0) / 10_000_000)),
      })
      const r = await fetch(`https://lrclib.net/api/get?${q}`, timeout())
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      const d = await r.json() as { instrumental?: boolean; syncedLyrics?: string; plainLyrics?: string }
      if (d.instrumental) return { instrumental: true }
      if (d.syncedLyrics) {
        const lines = keep(parseLRC(d.syncedLyrics))
        if (lines.length) return { lines, source: 'LRCLIB', tried: {} }
      }
      if (d.plainLyrics) {
        const lines = d.plainLyrics.split('\n').map(t => t.trim()).filter(Boolean)
          .map(t => ({ Start: null, End: null, Text: t, Words: null } as LyricLine))
        if (lines.length) return { lines, source: 'LRCLIB (plain)', tried: {} }
      }
      return null
    }],
    ['Jellyfin', async () => {
      const r = await fetch(`${deps.serverUrl}/Audio/${item.Id}/Lyrics`, {
        headers: { 'X-Emby-Token': deps.token },
        ...timeout(),
      })
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      const d = await r.json() as { Lyrics?: { Start?: number | null; Text?: string }[] }
      const lines = (d.Lyrics || [])
        .map((l): LyricLine => ({ Start: l.Start ?? null, End: null, Text: l.Text || '', Words: null }))
        .filter(l => l.Text)
      return lines.length ? { lines, source: 'Jellyfin', tried: {} } : null
    }],
  ]

  const tried: LyricsResult['tried'] = {}

  if (forcedRaw) {
    const entry = sources.find(([name]) => name === forcedRaw)
    if (!entry) return null
    try {
      const result = await entry[1]()
      if (result && 'instrumental' in result) return result
      tried[forcedRaw] = result ? 'ok' : 'fail'
      return result ? { ...result, tried } : null
    } catch (err) {
      if (!isAbort(err)) console.error(`[Lyrics] ${forcedRaw} failed:`, err)
      tried[forcedRaw] = 'fail'
      return null
    }
  }

  const settled = await Promise.all(sources.map(([name, run]) =>
    run()
      .then(result => ({ name, result }))
      .catch(err => {
        if (!isAbort(err)) console.error(`[Lyrics] ${name} failed:`, err)
        return { name, result: null as LyricsResult | Instrumental | null }
      }),
  ))

  // Any source saying "instrumental" settles it - that is a fact about the
  // track, not a preference between sources.
  for (const { result } of settled) {
    if (result && 'instrumental' in result) {
      cachePut(item.Id, { instrumental: true })
      return { instrumental: true }
    }
  }

  for (const { name, result } of settled) tried[name] = result ? 'ok' : 'fail'

  // Priority is the declared source order, applied after the race.
  const winner = settled.find(s => s.result)?.result as LyricsResult | undefined
  if (!winner) return null

  const out: LyricsResult = { ...winner, tried }
  cachePut(item.Id, out)
  return out
}

/** Server Only Mode: the Cascade Jellyfin plugin and nothing else. */
async function fetchFromCascadePlugin(
  deps: LyricsDeps,
  item: JfItem,
  forced: string | null,
  keep: (lines: LyricLine[]) => LyricLine[],
): Promise<LyricsLookup> {
  const wantType = forced === 'cascade-karaoke' ? 'karaoke'
    : forced === 'cascade-synced' ? 'synced'
    : null // auto takes whatever the plugin offers, karaoke first

  const tried: LyricsResult['tried'] = { Cascade: 'fail' }
  try {
    const r = await fetch(`${deps.serverUrl}/Audio/${item.Id}/CascadeLyrics`, {
      headers: { 'X-Emby-Token': deps.token },
      ...timeout(),
    })
    if (!r.ok) throw new Error(`HTTP ${r.status}`)
    const d = await r.json() as { lrc?: string; type?: string }
    if (!d.lrc || (wantType && d.type !== wantType)) return null

    const lines = keep(parseLRC(d.lrc))
    if (!lines.length) return null

    tried.Cascade = 'ok'
    const label = forced === 'cascade-karaoke' ? 'Karaoke'
      : forced === 'cascade-synced' ? 'Synced'
      : 'Cascade'
    const out: LyricsResult = { lines, source: label, tried }
    if (!forced) cachePut(item.Id, out)
    return out
  } catch (err) {
    if (!isAbort(err)) console.error('[Lyrics] Cascade plugin failed:', err)
    return null
  }
}
