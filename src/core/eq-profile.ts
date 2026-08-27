// The 5-band equalizer's pure data and maths. renderer.js owns the actual
// BiquadFilterNode chain (see _ensureEqGraph) - everything here is just the
// numbers: what the bands and presets are, how much the preamp should cut to
// keep a boosted curve from clipping, and how to turn whatever came out of
// the store into a profile that is safe to feed straight into a filter's gain.

export const EQ_BANDS = [60, 250, 1000, 4000, 12000]
export const EQ_GAIN_LIMIT = 12

export interface EQProfile {
  preamp: number | null   // null means "use the auto value"
  bands: number[]         // one gain in dB per entry of EQ_BANDS
}

// Named curves. Just data - gains in dB, one per EQ_BANDS entry.
export const EQ_PRESETS: Record<string, number[]> = {
  Flat: [0, 0, 0, 0, 0],
  'Bass Boost': [7, 4, 0, -1, -1],
  Vocal: [-3, -1, 4, 3, -1],
  Treble: [-2, -1, 0, 4, 6],
  Loudness: [6, 2, -2, 2, 6],
}

function isFiniteNumber(n: unknown): n is number {
  return typeof n === 'number' && Number.isFinite(n)
}

export function clampGain(n: number): number {
  return Math.max(-EQ_GAIN_LIMIT, Math.min(EQ_GAIN_LIMIT, n))
}

/** dB to a linear amplitude multiplier, for feeding a GainNode.gain. */
export function dbToGain(db: number): number {
  return Math.pow(10, db / 20)
}

// The common rule: cut the preamp by roughly 1 dB per 1 dB of the biggest
// boost in the curve, so a boosted band cannot push the signal past what it
// would have hit unequalized. A curve that only cuts needs no preamp cut of
// its own, so this never returns a positive number.
export function autoPreamp(bands: number[]): number {
  const maxBoost = bands.reduce((m, b) => Math.max(m, isFiniteNumber(b) ? b : 0), 0)
  return maxBoost === 0 ? 0 : -maxBoost
}

// Trust boundary: `raw` is whatever JSON.parse handed back from the store,
// which a hand edit or an old/corrupt value can turn into anything at all.
// Never let that reach a filter's gain unclamped.
export function normalizeProfile(raw: unknown): EQProfile {
  const r = (raw && typeof raw === 'object') ? raw as Record<string, unknown> : {}
  const rawBands = Array.isArray(r.bands) ? r.bands : []
  const bands = EQ_BANDS.map((_, i) => {
    const v = rawBands[i]
    return isFiniteNumber(v) ? clampGain(v) : 0
  })
  const preamp = isFiniteNumber(r.preamp) ? clampGain(r.preamp) : null
  return { preamp, bands }
}

// ── Response-graph geometry ──────────────────────────────────────────────────
// The settings-panel EQ used to be five separate sliders; now it is one
// draggable response curve. Everything about turning band gains into pixel
// coordinates (and a pointer position back into a gain) lives here, pure, so
// it can be tested without a DOM or an SVG - renderer.js only ever hands the
// numbers this returns straight to SVG attributes.

/** Even x position for band index i of `count` bands, inset a little so the
 *  first and last points aren't clipped against the graph's edge. Bands are
 *  spaced evenly rather than by actual log-frequency: with only five fixed
 *  points the two look almost identical and even spacing is simpler. */
export function eqBandX(i: number, count: number, width: number): number {
  if (count <= 1) return width / 2
  const inset = width * 0.08
  return inset + (i / (count - 1)) * (width - inset * 2)
}

/** A gain in dB to a y pixel: +EQ_GAIN_LIMIT at the top (y=0), -EQ_GAIN_LIMIT
 *  at the bottom (y=height). Clamped first - this must never place a point
 *  off a corrupt profile's say-so. */
export function eqDbToY(db: number, height: number): number {
  const clamped = clampGain(isFiniteNumber(db) ? db : 0)
  return height * (1 - (clamped + EQ_GAIN_LIMIT) / (2 * EQ_GAIN_LIMIT))
}

/**
 * Inverse of eqDbToY: a y pixel (already clamped to the graph's own height)
 * back to a dB gain, clamped to +-EQ_GAIN_LIMIT and rounded to the sliders'
 * own 0.5 dB step. This is the one function standing between a mouse/keyboard
 * event and a filter's gain - it has to bound the result itself rather than
 * trusting normalizeProfile to catch it later on the next store read.
 */
export function eqYToDb(y: number, height: number): number {
  const boundedY = Math.max(0, Math.min(height, isFiniteNumber(y) ? y : height / 2))
  const ratio = height === 0 ? 0.5 : 1 - boundedY / height
  const db = ratio * (2 * EQ_GAIN_LIMIT) - EQ_GAIN_LIMIT
  return clampGain(Math.round(db * 2) / 2)
}

/**
 * Smooth SVG path ("M x y C ...") through the band points, via a Catmull-Rom
 * to cubic-Bezier conversion - the standard, dependency-free way to draw a
 * curve through a handful of fixed points instead of connecting them with
 * straight lines.
 */
export function eqCurvePath(bands: number[], width: number, height: number): string {
  const pts = bands.map((db, i) => ({ x: eqBandX(i, bands.length, width), y: eqDbToY(db, height) }))
  if (pts.length === 0) return ''
  if (pts.length === 1) return `M ${pts[0].x} ${pts[0].y}`

  let d = `M ${pts[0].x} ${pts[0].y}`
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] ?? pts[i]
    const p1 = pts[i]
    const p2 = pts[i + 1]
    const p3 = pts[i + 2] ?? p2
    // Standard Catmull-Rom -> Bezier tangent factor of 1/6.
    const c1x = p1.x + (p2.x - p0.x) / 6
    const c1y = p1.y + (p2.y - p0.y) / 6
    const c2x = p2.x - (p3.x - p1.x) / 6
    const c2y = p2.y - (p3.y - p1.y) / 6
    d += ` C ${c1x} ${c1y}, ${c2x} ${c2y}, ${p2.x} ${p2.y}`
  }
  return d
}

/**
 * A band's frequency as a short label - generated from EQ_BANDS rather than
 * hardcoded, so a future change to the band frequencies (EQ_BANDS above)
 * needs no matching edit anywhere else. index.html used to hardcode these
 * five labels as plain text; that was the trap.
 */
export function formatEqBandLabel(hz: number): string {
  return hz >= 1000 ? `${hz / 1000} kHz` : `${hz} Hz`
}
