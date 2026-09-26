// SpicyLyrics API response -> Cascade's lyric lines, plus the credit the API's
// terms require wherever those lyrics are shown.
//
// Shape checked against the reference's embedded OpenAPI schema
// (developers.spicylyrics.org/docs/reference/get.lyrics, 2026-09-23):
//   Body.Type 'Syllable' -> Content[] of { Lead: {Syllables[]}, Background?: [...] }
//   Body.Type 'Line'     -> Content[] of { Text, StartTime, EndTime }
//   Body.Type 'Static'   -> Lines[] of { Text }            (Lines, not Content)
// Every time is SECONDS as a float; Cascade keeps ticks (1s = 10,000,000).
//
// OppositeAligned marks a duet's second voice; it becomes LyricLine.Opposite.
// Deliberately not used: TranslatedText and TransliteratedText (Cascade has
// its own on-device translation; mixing two would disagree line by line).

/** The duet flag, only when set, so ordinary lines keep their old shape. */
const opposite = (c: Record<string, unknown>) => c.OppositeAligned === true ? { Opposite: true } : {}

import type { LyricLine, LyricWord } from './lyrics.ts'

const TICKS_PER_SEC = 10_000_000

export type SpicySource = 'spicy_lyrics' | 'apple_music' | 'spotify' | 'unknown'

export interface SpicyContributor { name: string, url: string | null }

/** What the lyrics UI must show next to SpicyLyrics lyrics. `provider` is
 *  always shown; uploader and maker only exist for a community sync. */
export interface SpicyCredit {
  provider: string
  uploader: SpicyContributor | null
  maker: SpicyContributor | null
}

export interface SpicyConversion {
  lines: LyricLine[]
  credit: SpicyCredit
}

const PROVIDER_LABEL: Record<SpicySource, string> = {
  spicy_lyrics: 'Spicy Lyrics',
  apple_music: 'Apple Music via Spicy Lyrics',
  spotify: 'Spotify via Spicy Lyrics',
  unknown: 'Spicy Lyrics',
}

type Obj = Record<string, unknown>
const isObj = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v)
const arr = (v: unknown): unknown[] => Array.isArray(v) ? v : []
const str = (v: unknown): string => typeof v === 'string' ? v : ''

/** Seconds to ticks, or null for anything that is not a usable time. */
function ticks(sec: unknown): number | null {
  return typeof sec === 'number' && Number.isFinite(sec) && sec >= 0 ? Math.round(sec * TICKS_PER_SEC) : null
}

/** Only an https link is ever handed to the OS: this came from a third party. */
export function safeCreditUrl(url: unknown): string | null {
  if (typeof url !== 'string') return null
  try {
    const u = new URL(url)
    return u.protocol === 'https:' ? u.href : null
  } catch {
    return null
  }
}

function contributor(v: unknown): SpicyContributor | null {
  if (!isObj(v)) return null
  const name = str(v.username).trim()
  return name ? { name, url: safeCreditUrl(v.url) } : null
}

/** The credit for a response body. Uploader and maker are read only for a
 *  community sync, as the terms say; for a commercial source they are absent. */
export function spicyCredit(body: unknown): SpicyCredit {
  const b = isObj(body) ? body : {}
  const source = (Object.hasOwn(PROVIDER_LABEL, str(b.source)) ? b.source : 'unknown') as SpicySource
  const attr = source === 'spicy_lyrics' && isObj(b.UploadAttribution) ? b.UploadAttribution : null
  return {
    provider: PROVIDER_LABEL[source],
    uploader: attr ? contributor(attr.Uploader) : null,
    maker: attr ? contributor(attr.Maker) : null,
  }
}

/** One vocal group's syllables as words. `IsPartOfWord` joins a syllable to
 *  the next with no space; otherwise a word carries its trailing space, the
 *  same convention parseLRC uses. Each syllable keeps its own end time, so
 *  gaps between words survive (Enhanced LRC could not carry them). */
function groupWords(group: unknown): LyricWord[] {
  const out: LyricWord[] = []
  const syls = isObj(group) ? arr(group.Syllables) : []
  let prevEnd: number | null = isObj(group) ? ticks(group.StartTime) : null
  syls.forEach((s, i) => {
    if (!isObj(s)) return
    const text = str(s.Text)
    if (!text) return
    const start = ticks(s.StartTime) ?? prevEnd
    if (start == null) return   // no time at all: cannot place it on the clock
    const end = ticks(s.EndTime)
    const last = i === syls.length - 1
    out.push({ Start: start, End: end, Text: text + (s.IsPartOfWord === true || last ? '' : ' ') })
    prevEnd = end ?? start
  })
  return out
}

function syllableLines(content: unknown[]): LyricLine[] {
  const lines: LyricLine[] = []
  for (const c of content) {
    if (!isObj(c)) continue
    const words = groupWords(c.Lead)
    // Background vocals get a row of their own under the lead, as Apple Music
    // and SpicyLyrics draw them; merged into the lead line, two fills ran
    // across one line at once. Several background phrases on one line join
    // into one row, each keeping its own timings.
    const background: LyricWord[] = []
    for (const bg of arr(c.Background)) {
      const bw = groupWords(bg)
      if (!bw.length) continue
      if (background.length) background[background.length - 1].Text = background[background.length - 1].Text.trimEnd() + ' '
      background.push(...bw)
    }
    if (!words.length) continue
    const lead = isObj(c.Lead) ? c.Lead : {}
    const start = ticks(lead.StartTime) ?? words[0].Start
    const end = ticks(lead.EndTime) ?? words[words.length - 1].End
    const text = words.map(w => w.Text).join('').trim()
    if (text) lines.push({ Start: start, End: end, Text: text, Words: words, ...(background.length ? { Background: background } : {}), ...opposite(c) })
  }
  return lines
}

function lineLines(content: unknown[]): LyricLine[] {
  const lines: LyricLine[] = []
  for (const c of content) {
    if (!isObj(c)) continue
    const text = str(c.Text).trim()
    const start = ticks(c.StartTime)
    if (text && start != null) lines.push({ Start: start, End: ticks(c.EndTime), Text: text, Words: null, ...opposite(c) })
  }
  return lines
}

/** Untimed lines use `Start: null`, the same shape LRCLIB's plain lyrics use. */
function staticLines(list: unknown[]): LyricLine[] {
  return list
    .map(l => isObj(l) ? str(l.Text).trim() : '')
    .filter(Boolean)
    .map(t => ({ Start: null as unknown as number, End: null, Text: t, Words: null }))
}

/** How far past the end of the file a sync may run before it is taken to be
 *  for a different version. A little slack for rounding and trailing silence. */
export const SPICY_END_TOLERANCE_SEC = 1.5

/**
 * Whether a SpicyLyrics sync can belong to the file being played. A sync is
 * keyed to a Spotify track, and a song has one per release; the id found for
 * it can belong to another version (a longer edit, a remaster), whose timings
 * drift against this file. Vocals cannot end after the track does, so a sync
 * whose EndTime runs past the file's length is for a different version.
 * Tested on the real case: a 190.7s sync against a 186.6s file ran 3.5s late
 * at the first verse and 8s late by the end.
 *
 * Only catches a LONGER version: a shorter one ends in time and passes. With
 * no EndTime or no known duration there is nothing to judge, so it passes.
 */
export function spicyFitsTrack(raw: unknown, durationSec: number): boolean {
  const body = isObj(raw) && isObj(raw.Body) ? raw.Body : raw
  const end = isObj(body) ? body.EndTime : undefined
  if (typeof end !== 'number' || !Number.isFinite(end) || !(durationSec > 0)) return true
  return end <= durationSec + SPICY_END_TOLERANCE_SEC
}

/**
 * Converts a SpicyLyrics response (the whole envelope, or just its Body) into
 * lines plus the credit to show. Null when there is nothing usable, so the
 * caller falls through to its other sources.
 */
export function convertSpicyLyrics(raw: unknown): SpicyConversion | null {
  const body = isObj(raw) && isObj(raw.Body) ? raw.Body : raw
  if (!isObj(body)) return null
  let lines: LyricLine[]
  if (body.Type === 'Syllable') lines = syllableLines(arr(body.Content))
  else if (body.Type === 'Line') lines = lineLines(arr(body.Content))
  else if (body.Type === 'Static') lines = staticLines(arr(body.Lines))
  else return null
  return lines.length ? { lines, credit: spicyCredit(body) } : null
}

/**
 * The Spotify track id in whatever a user pastes: a share link
 * (open.spotify.com/track/ID?si=..., with or without an /intl-xx/ segment),
 * a spotify:track:ID URI, or the bare 22-character id. Null for anything
 * else, including album, playlist and artist links.
 */
export function parseSpotifyTrackId(input: unknown): string | null {
  if (typeof input !== 'string') return null
  const s = input.trim()
  const id = /^[A-Za-z0-9]{22}$/.test(s) ? s
    : s.match(/^spotify:track:([A-Za-z0-9]{22})$/)?.[1]
    ?? s.match(/^(?:https?:\/\/)?open\.spotify\.com\/(?:intl-[a-z-]+\/)?(?:embed\/)?track\/([A-Za-z0-9]{22})(?:[/?#].*)?$/i)?.[1]
  return id ?? null
}
