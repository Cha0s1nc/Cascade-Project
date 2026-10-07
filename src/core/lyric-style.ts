// The full-screen lyrics' look, as user settings: the desktop's side of the
// Apple app's Style Tuning (apple/App/Sources/StyleTuning.swift). Keys match
// the Apple app's wherever the meaning does, so a look can move between them.
//
// Each knob drives a CSS custom property (`css`, with `unit` appended) or,
// without one, a value renderer.js reads itself. Only the knobs the user
// changed are stored, so a better default later still reaches everything
// they left alone. Stored values are untrusted: each is clamped to its range
// before it reaches CSS or the lyric timing.

export interface LyricKnob {
  key: string
  section: string
  label: string
  min: number
  max: number
  step: number
  /** The default: the shipped look. */
  value: number
  /** The CSS custom property it sets on :root, if any. */
  css?: string
  unit?: 'px' | 'em' | 's'
}

export const LYRIC_KNOBS: readonly LyricKnob[] = [
  { key: 'currentLinePosition', section: 'Layout', label: 'Current line position', min: 0.1, max: 0.6, step: 0.01, value: 0.5 },
  { key: 'lineGap', section: 'Layout', label: 'Line gap', min: 0, max: 40, step: 1, value: 8, css: '--ly-line-gap', unit: 'px' },

  { key: 'pastScale', section: 'Past lines', label: 'Size', min: 0.4, max: 1, step: 0.01, value: 0.75, css: '--ly-past-scale' },
  { key: 'pastOpacity', section: 'Past lines', label: 'Opacity', min: 0, max: 1, step: 0.01, value: 0.3, css: '--ly-past-opacity' },
  { key: 'pastBlur', section: 'Past lines', label: 'Blur', min: 0, max: 8, step: 0.5, value: 3.5, css: '--ly-past-blur', unit: 'px' },

  { key: 'next1Opacity', section: 'Upcoming lines', label: 'Next opacity', min: 0, max: 1, step: 0.01, value: 0.15, css: '--ly-next1-opacity' },
  { key: 'next1Blur', section: 'Upcoming lines', label: 'Next blur', min: 0, max: 8, step: 0.5, value: 2.5, css: '--ly-next1-blur', unit: 'px' },
  { key: 'next2Opacity', section: 'Upcoming lines', label: 'Second opacity', min: 0, max: 1, step: 0.01, value: 0.11, css: '--ly-next2-opacity' },
  { key: 'next2Blur', section: 'Upcoming lines', label: 'Second blur', min: 0, max: 8, step: 0.5, value: 4, css: '--ly-next2-blur', unit: 'px' },
  { key: 'next3Opacity', section: 'Upcoming lines', label: 'Third opacity', min: 0, max: 1, step: 0.01, value: 0.1, css: '--ly-next3-opacity' },
  { key: 'next3Blur', section: 'Upcoming lines', label: 'Third blur', min: 0, max: 8, step: 0.5, value: 4, css: '--ly-next3-blur', unit: 'px' },
  { key: 'farBlur', section: 'Upcoming lines', label: 'Blur further out', min: 0, max: 12, step: 0.5, value: 6, css: '--ly-far-blur', unit: 'px' },
  { key: 'browsingOpacity', section: 'Upcoming lines', label: 'Opacity while scrolling', min: 0, max: 1, step: 0.01, value: 0.8, css: '--ly-browsing-opacity' },
  { key: 'browsingBlur', section: 'Upcoming lines', label: 'Blur while scrolling', min: 0, max: 8, step: 0.5, value: 2.5, css: '--ly-browsing-blur', unit: 'px' },

  { key: 'unsungOpacity', section: 'Karaoke', label: 'Unsung word opacity', min: 0, max: 1, step: 0.01, value: 0.29, css: '--ly-unsung-opacity' },
  { key: 'wordLift', section: 'Karaoke', label: 'Word lift (em)', min: 0, max: 0.2, step: 0.005, value: 0.04, css: '--word-lift', unit: 'em' },
  // Held notes (SpicyLyrics only): see heldSwell() below.
  { key: 'heldFullSeconds', section: 'Karaoke', label: 'Held note: full swell after (s)', min: 1, max: 8, step: 0.1, value: 1.4 },
  { key: 'heldMinStrength', section: 'Karaoke', label: 'Held note: short note strength', min: 0, max: 1, step: 0.05, value: 0.45 },
  { key: 'heldLift', section: 'Karaoke', label: 'Held note lift (em)', min: 0, max: 0.4, step: 0.01, value: 0.16, css: '--emph-lift', unit: 'em' },
  { key: 'heldScale', section: 'Karaoke', label: 'Held note swell', min: 1, max: 1.4, step: 0.01, value: 1.19, css: '--emph-scale' },
  { key: 'heldSettle', section: 'Karaoke', label: 'Held note settle', min: 0, max: 1, step: 0.05, value: 0.7 },
  { key: 'heldSettleSeconds', section: 'Karaoke', label: 'Held note settle time (s)', min: 0, max: 2, step: 0.05, value: 0.4 },
  { key: 'backgroundVocalSize', section: 'Karaoke', label: 'Background vocal size', min: 0.4, max: 1, step: 0.01, value: 0.64, css: '--ly-bg-vocal-size', unit: 'em' },
  { key: 'backgroundVocalOpacity', section: 'Karaoke', label: 'Background vocal opacity', min: 0, max: 1, step: 0.01, value: 0.85, css: '--ly-bg-vocal-opacity' },

  { key: 'fadeSeconds', section: 'Motion', label: 'Line fade (s)', min: 0, max: 2, step: 0.05, value: 1, css: '--ly-fade', unit: 's' },
  { key: 'rippleSeconds', section: 'Motion', label: 'Ripple per line (s)', min: 0, max: 0.4, step: 0.01, value: 0.04 },
  // Negative is earlier, as in the Apple app: a line takes its fade to light
  // up, so one drawn exactly on the beat reads as late.
  { key: 'lyricsDelay', section: 'Motion', label: 'Lyrics timing (s)', min: -2, max: 2, step: 0.05, value: -0.05 },
]

export type LyricStyle = Record<string, number>

const BY_KEY = new Map(LYRIC_KNOBS.map(k => [k.key, k]))

const clamp = (knob: LyricKnob, v: unknown): number =>
  typeof v === 'number' && Number.isFinite(v) ? Math.min(knob.max, Math.max(knob.min, v)) : knob.value

/** Every knob's value: the stored ones (clamped) over the defaults. Unknown
 *  keys and anything that is not an object of numbers are ignored. */
export function lyricStyleFrom(stored: unknown): LyricStyle {
  const s = stored && typeof stored === 'object' && !Array.isArray(stored) ? stored as Record<string, unknown> : {}
  return Object.fromEntries(LYRIC_KNOBS.map(k => [k.key, k.key in s ? clamp(k, s[k.key]) : k.value]))
}

/** Only the knobs that differ from their defaults: what gets stored. */
export function lyricStyleChanges(style: LyricStyle): LyricStyle {
  const out: LyricStyle = {}
  for (const k of LYRIC_KNOBS) {
    const v = clamp(k, style[k.key])
    if (Math.abs(v - k.value) > 1e-9) out[k.key] = v
  }
  return out
}

/** The CSS custom properties a style sets, e.g. { '--ly-past-blur': '3.5px' }. */
export function lyricStyleCss(style: LyricStyle): Record<string, string> {
  const out: Record<string, string> = {}
  for (const k of LYRIC_KNOBS) {
    if (k.css) out[k.css] = `${clamp(k, style[k.key])}${k.unit ?? ''}`
  }
  return out
}

export const lyricKnob = (key: string): LyricKnob | undefined => BY_KEY.get(key)

/** CSS's (and SwiftUI's) ease-in-out, cubic-bezier(0.42, 0, 0.58, 1). */
export function easeInOut(t: number): number {
  if (!(t > 0)) return 0
  if (t >= 1) return 1
  // Solve x(u) = t for the curve parameter u (Newton), then return y(u).
  let u = t
  for (let i = 0; i < 8; i++) {
    const x = 3 * 0.42 * (1 - u) ** 2 * u + 3 * 0.58 * (1 - u) * u * u + u ** 3 - t
    if (Math.abs(x) < 1e-7) break
    const dx = 3 * 0.42 * (1 - u) ** 2 + 6 * (0.58 - 0.42) * (1 - u) * u + 3 * (1 - 0.58) * u * u
    u = Math.min(1, Math.max(0, u - x / dx))
  }
  return 3 * (1 - u) * u * u + u ** 3
}

/**
 * How swollen one letter of a held note is, 0 to 1 of the full swell: the
 * Apple app's LyricStyle.swell, so both apps draw held notes alike.
 *
 * Apple Music swells a held note more the longer it is. So the strength comes
 * from the note's length (a 1 s hold gets heldMinStrength, heldFullSeconds or
 * longer gets all of it), each letter rises from when the fill reaches it
 * until the note ends (over at least 0.35 s, so a letter reached near the end
 * does not pop), then settles to heldSettle of its peak over
 * heldSettleSeconds and holds there until the line changes.
 */
export function heldSwell(sinceLit: number, untilEnd: number, held: number, style: LyricStyle): number {
  if (!(sinceLit >= 0)) return 0
  const full = style.heldFullSeconds
  const reach = full > 1 ? Math.min(1, Math.max(0, (held - 1) / (full - 1))) : 1
  const strength = style.heldMinStrength + (1 - style.heldMinStrength) * reach
  const rise = Math.max(untilEnd, 0.35)
  if (sinceLit < rise) return strength * easeInOut(sinceLit / rise)
  const settle = style.heldSettleSeconds > 0 ? Math.min(1, (sinceLit - rise) / style.heldSettleSeconds) : 1
  return strength * (1 - (1 - style.heldSettle) * easeInOut(settle))
}
