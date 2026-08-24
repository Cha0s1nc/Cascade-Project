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

function clampGain(n: number): number {
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
