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
// Deliberately not used: OppositeAligned (no renderer home for a second
// singer's side), TranslatedText and TransliteratedText (Cascade has its own
// on-device translation; mixing two would disagree line by line).

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
    // Background vocals follow the lead in parentheses, the way the API's own
    // Line type flattens them. Their own timings stay, so they still fill.
    for (const bg of arr(c.Background)) {
      const bw = groupWords(bg)
      if (!bw.length) continue
      if (words.length) words[words.length - 1].Text = words[words.length - 1].Text.trimEnd() + ' '
      bw[0].Text = '(' + bw[0].Text
      bw[bw.length - 1].Text = bw[bw.length - 1].Text.trimEnd() + ')'
      words.push(...bw)
    }
    if (!words.length) continue
    const lead = isObj(c.Lead) ? c.Lead : {}
    const start = ticks(lead.StartTime) ?? words[0].Start
    const end = ticks(lead.EndTime) ?? words[words.length - 1].End
    const text = words.map(w => w.Text).join('').trim()
    if (text) lines.push({ Start: start, End: end, Text: text, Words: words })
  }
  return lines
}

function lineLines(content: unknown[]): LyricLine[] {
  const lines: LyricLine[] = []
  for (const c of content) {
    if (!isObj(c)) continue
    const text = str(c.Text).trim()
    const start = ticks(c.StartTime)
    if (text && start != null) lines.push({ Start: start, End: ticks(c.EndTime), Text: text, Words: null })
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
