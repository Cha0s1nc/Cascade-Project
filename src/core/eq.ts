// The now-playing equalizer bars, driven by real Web Audio frequency data.
//
// Pure on purpose: renderer.js owns the AudioContext/AnalyserNode and the
// rAF loop, this just turns one frame of getByteFrequencyData() into three
// 0..1 bar heights so the maths can be unit tested without a DOM or an
// AudioContext.

// Bars never fully flatten to zero - a dead-flat bar reads as broken, not quiet.
export const MIN_BAR_HEIGHT = 0.12

// Band edges, as a fraction of the frequency array (bin 0 is DC and is always
// skipped). Fractions rather than fixed bin indices so this keeps working
// whatever fftSize the analyser is built with.
export const LOW_BAND_END = 0.12
export const MID_BAND_END = 0.45

// Calibration knob. Real music carries far more energy in the bass than the
// treble, so without per-band gain the high bar barely twitches while the low
// bar pins at max. Tune these by eye against real tracks - they are the only
// numbers here that encode "what sounds right" rather than "how the FFT bins
// are sliced up".
export const LOW_GAIN = 1.0
export const MID_GAIN = 1.6
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
 * Turn one frame of AnalyserNode.getByteFrequencyData() output into three bar
 * heights (low, mid, high), each clamped to [MIN_BAR_HEIGHT, 1].
 */
export function eqLevels(freqBytes: ArrayLike<number>): [number, number, number] {
  const n = freqBytes.length
  if (n < 2) return [MIN_BAR_HEIGHT, MIN_BAR_HEIGHT, MIN_BAR_HEIGHT]

  // Bin 0 is DC (no audio content), so bands start at 1.
  const lowEnd = Math.max(1, Math.floor(n * LOW_BAND_END))
  const midEnd = Math.max(lowEnd + 1, Math.floor(n * MID_BAND_END))

  const low = bandAverage(freqBytes, 1, lowEnd)
  const mid = bandAverage(freqBytes, lowEnd, midEnd)
  const high = bandAverage(freqBytes, midEnd, n)

  return [toLevel(low, LOW_GAIN), toLevel(mid, MID_GAIN), toLevel(high, HIGH_GAIN)]
}
