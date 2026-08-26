import { test } from 'node:test'
import assert from 'node:assert/strict'
import { equalPowerCrossfadeCurves, CROSSFADE_CURVE_POINTS, fadeDurationSecs } from '../src/core/crossfade.ts'

// Curves are Float32Array (that is what setValueCurveAtTime wants), so the
// tolerance has to fit float32 precision (~1e-7), not float64.
const EPS = 1e-6

test('curves are the requested length', () => {
  const { outCurve, inCurve } = equalPowerCrossfadeCurves(41)
  assert.equal(outCurve.length, 41)
  assert.equal(inCurve.length, 41)
})

test('default length matches the exported constant', () => {
  const { outCurve } = equalPowerCrossfadeCurves()
  assert.equal(outCurve.length, CROSSFADE_CURVE_POINTS)
})

test('each curve starts and ends at the right endpoint', () => {
  const { outCurve, inCurve } = equalPowerCrossfadeCurves(41)
  const last = outCurve.length - 1
  assert.ok(Math.abs(outCurve[0] - 1) < EPS, 'outCurve should start at 1 (fully audible)')
  assert.ok(Math.abs(outCurve[last] - 0) < EPS, 'outCurve should end at 0 (silent)')
  assert.ok(Math.abs(inCurve[0] - 0) < EPS, 'inCurve should start at 0 (silent)')
  assert.ok(Math.abs(inCurve[last] - 1) < EPS, 'inCurve should end at 1 (fully audible)')
})

test('the two gains are equal at the midpoint', () => {
  // 41 points puts an exact p=0.5 sample at index 20.
  const { outCurve, inCurve } = equalPowerCrossfadeCurves(41)
  const mid = 20
  assert.ok(Math.abs(outCurve[mid] - inCurve[mid]) < EPS, `expected equal gains at midpoint, got ${outCurve[mid]} vs ${inCurve[mid]}`)
  // And that shared value should be ~0.707 (1/sqrt(2)), not 0.5 - the
  // linear-ramp value a straight-line fade would have used here.
  assert.ok(Math.abs(outCurve[mid] - Math.SQRT1_2) < EPS)
})

test('summed power stays approximately constant across the fade', () => {
  // This is the property equal power buys and a linear ramp does not: at a
  // linear ramp's own midpoint, 0.5^2 + 0.5^2 = 0.5, a real dip. Here every
  // sample's out^2 + in^2 should land on 1.
  const { outCurve, inCurve } = equalPowerCrossfadeCurves(41)
  for (let i = 0; i < outCurve.length; i++) {
    const power = outCurve[i] * outCurve[i] + inCurve[i] * inCurve[i]
    assert.ok(Math.abs(power - 1) < EPS, `power at sample ${i} was ${power}, expected ~1`)
  }
})

test('a tiny or fractional point count still produces a usable curve', () => {
  const { outCurve, inCurve } = equalPowerCrossfadeCurves(2.7)
  assert.equal(outCurve.length, 2)
  assert.equal(inCurve.length, 2)
})

test('fadeDurationSecs uses the configured length when the track has room', () => {
  assert.equal(fadeDurationSecs(6, 30), 6)
})

test('fadeDurationSecs shortens to what is actually left', () => {
  assert.equal(fadeDurationSecs(6, 3), 3)
})

test('fadeDurationSecs refuses a fade too short to be worth doing', () => {
  // The bug this exists for: the old code clamped to 0.1s, turning a slow
  // incoming buffer into a 100ms cut instead of a clean handoff.
  assert.equal(fadeDurationSecs(6, 0.4), null)
  assert.equal(fadeDurationSecs(6, 0), null)
  assert.equal(fadeDurationSecs(6, -2), null)
})

test('fadeDurationSecs falls back to the configured length on an unknown duration', () => {
  assert.equal(fadeDurationSecs(6, NaN), 6)
  assert.equal(fadeDurationSecs(6, Infinity), 6)
})
