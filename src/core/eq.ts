// The now-playing equalizer bars, driven by real Web Audio frequency data.
//
// Pure on purpose: renderer.js owns the AudioContext/AnalyserNode and the
// rAF loop, this just turns one frame of getByteFrequencyData() into bar
// heights so the maths can be unit tested without a DOM or an AudioContext.

// Bars never fully flatten to zero - a dead-flat bar reads as broken, not quiet.
export const MIN_BAR_HEIGHT = 0.12

/** How many bars a playing row draws. renderer.js writes this many <i>. */
export const EQ_BARS = 7

// Calibration knob. Real music carries far more energy in the bass than the
// treble, so without per-band gain the high bars barely twitch while the low
// ones pin at max. The lowest bar gets LOW_GAIN, the highest HIGH_GAIN, and the
// ones between are spread evenly. Tune by eye against real tracks.
export const LOW_GAIN = 1.0
export const HIGH_GAIN = 2.8

function bandAverage(bytes: ArrayLike<number>, start: number, end: number): number {
  if (end <= start) return 0
  let sum = 0
  for (let i = start; i < end; i++) sum += bytes[i]
  return sum / (end - start)
}

function toLevel(avg: number, gain: number): number {
  const v = (avg / 255) * gain
  return Math.min(1, Math.max(MIN_BAR_HEIGHT, v))
}

/**
 * Turn one frame of AnalyserNode.getByteFrequencyData() output into `count`
 * bar heights, lowest frequency first, each clamped to [MIN_BAR_HEIGHT, 1].
 * Bands are spaced logarithmically, the way pitch is heard, and each gets at
 * least one bin.
 */
export function eqLevels(freqBytes: ArrayLike<number>, count = EQ_BARS): number[] {
  const n = freqBytes.length
  if (n < 2 || count < 1) return Array(Math.max(0, count)).fill(MIN_BAR_HEIGHT)

  // Bin 0 is DC (no audio content), so bands start at 1.
  const edges = [1]
  for (let k = 1; k <= count; k++) {
    const edge = Math.floor((n ** (k / count)))
    edges.push(Math.min(n, Math.max(edges[k - 1] + 1, edge)))
  }
  return Array.from({ length: count }, (_, k) => {
    const gain = count === 1 ? LOW_GAIN : LOW_GAIN + (HIGH_GAIN - LOW_GAIN) * k / (count - 1)
    return toLevel(bandAverage(freqBytes, edges[k], edges[k + 1]), gain)
  })
}
