import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  NORMALIZATION_MAX_BOOST_DB, NORMALIZATION_MAX_CUT_DB,
  clampNormalizationDb, normalizationGainLinear,
} from '../src/core/normalization.ts'

test('clampNormalizationDb bounds a boost and a cut without touching a normal value', () => {
  assert.equal(clampNormalizationDb(34.2), NORMALIZATION_MAX_BOOST_DB)
  assert.equal(clampNormalizationDb(-40), -NORMALIZATION_MAX_CUT_DB)
  assert.equal(clampNormalizationDb(3.5), 3.5)
  assert.equal(clampNormalizationDb(0), 0)
})

test('normalizationGainLinear never returns something unsafe for garbage input', () => {
  const garbage = [null, undefined, {}, 'loud', NaN, Infinity, -Infinity, '5', []]
  for (const raw of garbage) {
    const gain = normalizationGainLinear(raw)
    assert.equal(gain, 1, `expected unity for ${JSON.stringify(raw)}`)
  }
})

test('normalizationGainLinear matches the clamped dB-to-linear conversion for real values', () => {
  // +34.2dB (this library's deliberately extreme quiet album) clamps to the
  // boost ceiling before converting, so it must equal the ceiling's own gain,
  // not blow up to whatever 34.2dB would otherwise be.
  const ceilingGain = normalizationGainLinear(NORMALIZATION_MAX_BOOST_DB)
  assert.equal(normalizationGainLinear(34.2), ceilingGain)
  assert.ok(ceilingGain < 5, 'a clamped boost should stay well short of a 50x multiplier')

  // A small, ordinary cut is applied as-is (0dB = unity, negative = quieter).
  assert.equal(normalizationGainLinear(0), 1)
  assert.ok(normalizationGainLinear(-3.8) < 1)
  assert.ok(normalizationGainLinear(-3.8) > 0)

  // A moderate boost is genuinely louder than unity but still finite and sane.
  const modest = normalizationGainLinear(6)
  assert.ok(modest > 1 && modest < 3)
})

test('normalizationGainLinear is monotonic in the unclamped range', () => {
  const low = normalizationGainLinear(-6)
  const mid = normalizationGainLinear(0)
  const high = normalizationGainLinear(6)
  assert.ok(low < mid)
  assert.ok(mid < high)
})
