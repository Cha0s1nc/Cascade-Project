// Equal power crossfade envelope for the two-deck crossfade in renderer.js.
//
// A linear volume ramp dips in the middle: gain is proportional to amplitude,
// but perceived loudness tracks power, which is amplitude squared. At the
// halfway point of a linear fade both decks sit at 0.5 gain, so the summed
// power is 0.5^2 + 0.5^2 = 0.5 - half of either endpoint's power - audible as
// a brief dip. An equal power curve (cos/sin instead of a straight line) keeps
// outGain^2 + inGain^2 == 1 across the whole fade, so the crossover sounds
// like one continuous level.
//
// Pure on purpose, same reasoning as eq.ts: renderer.js owns the AudioContext
// and feeds these curves straight into GainNode.setValueCurveAtTime(), so the
// audio thread - not a requestAnimationFrame loop - owns the actual timing.

/** Default number of samples in each curve handed to setValueCurveAtTime. */
export const CROSSFADE_CURVE_POINTS = 50

/**
 * Equal power fade-out/fade-in gain curves, each `points` samples long,
 * running from fade start (index 0) to fade end (last index).
 *
 * outCurve: 1 -> 0, for the deck fading out.
 * inCurve:  0 -> 1, for the deck fading in.
 */
export function equalPowerCrossfadeCurves(points: number = CROSSFADE_CURVE_POINTS): { outCurve: Float32Array, inCurve: Float32Array } {
  const n = Math.max(2, Math.floor(points))
  const outCurve = new Float32Array(n)
  const inCurve = new Float32Array(n)
  for (let i = 0; i < n; i++) {
    const p = i / (n - 1)
    const angle = p * (Math.PI / 2)
    outCurve[i] = Math.cos(angle)
    inCurve[i] = Math.sin(angle)
  }
  return { outCurve, inCurve }
}

/**
 * Shortest fade worth doing, in seconds. Below this a "fade" is just a hard cut
 * with a smear on it, and it lands mid-phrase because the outgoing track is
 * being ended early to make room for it. Handing over cleanly sounds better
 * than a 100ms crossfade.
 */
export const MIN_USEFUL_FADE_SECS = 1.0

/**
 * How long to actually fade for, given the configured length and how much of
 * the outgoing track is genuinely left at the moment the ramp is about to
 * start.
 *
 * `remaining` is re-read late on purpose: waiting for the incoming deck to
 * buffer costs real time, and fading for longer than remains means the
 * outgoing track hits `ended` partway through the ramp, handing over abruptly.
 *
 * Returns null when there is not enough left to be worth fading at all. The
 * old code clamped to a 0.1s floor instead, so a slow incoming buffer silently
 * turned a 6 second crossfade into a 100ms cut - audible as a glitch at the
 * track boundary, and one of the few things here that varies run to run.
 */
export function fadeDurationSecs(configuredSecs: number, remaining: number): number | null {
  if (!isFinite(remaining)) return configuredSecs > 0 ? configuredSecs : null
  if (remaining < MIN_USEFUL_FADE_SECS) return null
  const secs = Math.min(configuredSecs, remaining)
  return secs >= MIN_USEFUL_FADE_SECS ? secs : null
}
