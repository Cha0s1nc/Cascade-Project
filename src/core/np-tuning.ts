// Now Playing overlay knobs: lyric size, background dim, background blend.
// Pure clamp/guard logic only - renderer.js's saveNpTuning()/loadNpTuning()
// own writing the CSS custom properties these values drive
// (--np-lyric-scale, --np-scrim-left/right/header, --np-blend; see the "four
// custom properties" comment in styles/theme.css and initLightTuningPanel()
// in renderer.js, which exposes the same scrim/blend properties as debug-only
// sliders that never persist).
//
// Store values are untrusted, same rule as everywhere else a stored number
// could reach a CSS value or an audio param: a corrupted or hand-edited
// setting must clamp to something safe rather than reach --np-lyric-scale (or
// a filter gain, or a bitrate) as NaN.

/** Multiplier on .ov-lyric-line's clamp(22px, 3vw, 50px). 1 is the shipped
 *  size; the range stops short of illegible-small or line-wrapping-large. */
export const LYRIC_SCALE_MIN = 0.8
export const LYRIC_SCALE_MAX = 1.4
export const LYRIC_SCALE_DEFAULT = 1

/** --np-scrim-left/right/header's shipped fallback (styles/theme.css) - one
 *  knob sets all three identically, since they already share this default
 *  and the debug panel's per-scrim split is a tuning tool, not something a
 *  normal setting needs to expose. */
export const BG_DIM_MIN = 0
export const BG_DIM_MAX = 1
export const BG_DIM_DEFAULT = 0.16

function isFiniteNumber(n: unknown): n is number {
  return typeof n === 'number' && Number.isFinite(n)
}

function clampTo(n: unknown, min: number, max: number, fallback: number): number {
  if (!isFiniteNumber(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

export function clampLyricScale(n: unknown): number {
  return clampTo(n, LYRIC_SCALE_MIN, LYRIC_SCALE_MAX, LYRIC_SCALE_DEFAULT)
}

export function clampBgDim(n: unknown): number {
  return clampTo(n, BG_DIM_MIN, BG_DIM_MAX, BG_DIM_DEFAULT)
}

/** --np-blend only ever has two real values, and anything else (a stale
 *  string, a corrupted store entry) should read as the shipped default
 *  (multiply) rather than silently becoming an unblended overlay. */
export function clampBgBlend(v: unknown): boolean {
  return v !== false
}
