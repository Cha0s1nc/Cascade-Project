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
