import { test } from 'node:test'
import assert from 'node:assert/strict'
import { EQ_BANDS, EQ_GAIN_LIMIT, EQ_PRESETS, autoPreamp, normalizeProfile, dbToGain } from '../src/core/eq-profile.ts'

function inRange(n: number): boolean {
  return Number.isFinite(n) && n >= -EQ_GAIN_LIMIT && n <= EQ_GAIN_LIMIT
}

test('normalizeProfile on garbage input always yields a valid in-range profile', () => {
  const garbage = [
    null,
    undefined,
    {},
    { bands: 'nope' },
    { bands: [1, 2] },                          // wrong length
    { bands: [1, 2, 3, 4, 5, 6, 7] },            // too long
    { bands: [NaN, Infinity, -Infinity, 1, 2] },
    { bands: ['3', '4', '5', '6', '7'] },        // strings, not numbers
    { bands: [400, -400, 0, 0, 0] },             // out of range
    { preamp: NaN, bands: [0, 0, 0, 0, 0] },
    { preamp: '5', bands: [0, 0, 0, 0, 0] },
    { preamp: 999, bands: [0, 0, 0, 0, 0] },
    'a whole string instead of an object',
    42,
  ]
  for (const raw of garbage) {
    const p = normalizeProfile(raw)
    assert.equal(p.bands.length, EQ_BANDS.length, `bands length wrong for ${JSON.stringify(raw)}`)
    for (const g of p.bands) assert.ok(inRange(g), `band ${g} out of range for ${JSON.stringify(raw)}`)
    assert.ok(p.preamp === null || inRange(p.preamp), `preamp ${p.preamp} out of range for ${JSON.stringify(raw)}`)
  }
})

test('normalizeProfile passes a valid profile through unchanged', () => {
  const p = normalizeProfile({ preamp: -3, bands: [1, 2, 3, 4, 5] })
  assert.deepEqual(p, { preamp: -3, bands: [1, 2, 3, 4, 5] })
})

test('normalizeProfile treats a missing or explicit-null preamp as auto', () => {
  assert.equal(normalizeProfile({ bands: [0, 0, 0, 0, 0] }).preamp, null)
  assert.equal(normalizeProfile({ preamp: null, bands: [0, 0, 0, 0, 0] }).preamp, null)
})

test('autoPreamp never returns a positive gain', () => {
  assert.ok(autoPreamp([12, 12, 12, 12, 12]) <= 0)
  assert.ok(autoPreamp([-12, -12, -12, -12, -12]) <= 0)
  assert.ok(autoPreamp([0, 0, 0, 0, 0]) <= 0)
})

test('autoPreamp cuts more for a bigger boost', () => {
  const smallBoost = autoPreamp([3, 0, 0, 0, 0])
  const bigBoost = autoPreamp([9, 0, 0, 0, 0])
  assert.ok(bigBoost < smallBoost, `expected ${bigBoost} < ${smallBoost}`)
})

test('a flat curve needs no cut', () => {
  assert.equal(autoPreamp([0, 0, 0, 0, 0]), 0)
  assert.equal(autoPreamp([-4, -2, -1, -3, -5]), 0)
})

test('every preset is the right length and in range', () => {
  for (const [name, bands] of Object.entries(EQ_PRESETS)) {
    assert.equal(bands.length, EQ_BANDS.length, `${name} has the wrong number of bands`)
    for (const g of bands) assert.ok(inRange(g), `${name} band ${g} out of range`)
  }
})

test('dbToGain is unity at 0dB and grows with positive dB', () => {
  assert.ok(Math.abs(dbToGain(0) - 1) < 1e-9)
  assert.ok(dbToGain(6) > 1)
  assert.ok(dbToGain(-6) < 1)
})
