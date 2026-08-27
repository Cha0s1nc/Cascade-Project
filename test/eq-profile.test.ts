import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  EQ_BANDS, EQ_GAIN_LIMIT, EQ_PRESETS, autoPreamp, normalizeProfile, dbToGain,
  eqBandX, eqDbToY, eqYToDb, eqCurvePath, formatEqBandLabel,
} from '../src/core/eq-profile.ts'

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

// ── Response-graph geometry ──────────────────────────────────────────────────

test('eqBandX: first and last bands are inset from the edges, evenly spaced between', () => {
  const xs = EQ_BANDS.map((_, i) => eqBandX(i, EQ_BANDS.length, 260))
  assert.ok(xs[0] > 0 && xs[0] < 26, 'first point should be inset, not flush left')
  assert.ok(xs[4] < 260 && xs[4] > 234, 'last point should be inset, not flush right')
  for (let i = 1; i < xs.length; i++) assert.ok(xs[i] > xs[i - 1], 'x must increase with band index')
  const gaps = xs.slice(1).map((x, i) => x - xs[i])
  for (const g of gaps) assert.ok(Math.abs(g - gaps[0]) < 1e-9, 'bands must be evenly spaced')
})

test('eqBandX: a single band sits in the middle', () => {
  assert.equal(eqBandX(0, 1, 260), 130)
})

test('eqDbToY: +limit is the top, -limit is the bottom, 0dB is the middle', () => {
  assert.equal(eqDbToY(EQ_GAIN_LIMIT, 140), 0)
  assert.equal(eqDbToY(-EQ_GAIN_LIMIT, 140), 140)
  assert.equal(eqDbToY(0, 140), 70)
})

test('eqDbToY: clamps and sanitises a corrupt value rather than placing it off-graph', () => {
  assert.equal(eqDbToY(400, 140), 0)
  assert.equal(eqDbToY(-400, 140), 140)
  assert.equal(eqDbToY(NaN, 140), 70)
})

test('eqYToDb inverts eqDbToY at the reference points', () => {
  assert.equal(eqYToDb(0, 140), EQ_GAIN_LIMIT)
  assert.equal(eqYToDb(140, 140), -EQ_GAIN_LIMIT)
  assert.equal(eqYToDb(70, 140), 0)
})

test('eqYToDb: never leaves +-EQ_GAIN_LIMIT even for a wildly out-of-bounds pointer', () => {
  assert.equal(eqYToDb(-9999, 140), EQ_GAIN_LIMIT)
  assert.equal(eqYToDb(9999, 140), -EQ_GAIN_LIMIT)
})

test('eqYToDb: rounds to the same 0.5dB step the old sliders used', () => {
  const db = eqYToDb(37, 140)
  assert.equal(db, Math.round(db * 2) / 2)
})

test('eqYToDb: NaN and a degenerate zero-height graph do not explode', () => {
  assert.ok(Number.isFinite(eqYToDb(NaN, 140)))
  assert.ok(Number.isFinite(eqYToDb(50, 0)))
})

test('eqCurvePath: starts at the first band point and has one curve segment per gap', () => {
  const bands = [0, 0, 0, 0, 0]
  const d = eqCurvePath(bands, 260, 140)
  const x0 = eqBandX(0, 5, 260)
  const y0 = eqDbToY(0, 140)
  assert.ok(d.startsWith(`M ${x0} ${y0} `), d)
  assert.equal((d.match(/C /g) || []).length, bands.length - 1)
})

test('eqCurvePath: passes exactly through every band point (Catmull-Rom property)', () => {
  const bands = [3, -6, 0, 4.5, -12]
  const d = eqCurvePath(bands, 260, 140)
  bands.forEach((db, i) => {
    const x = eqBandX(i, bands.length, 260)
    const y = eqDbToY(db, 140)
    assert.ok(d.includes(`${x} ${y}`), `curve should pass through band ${i} at ${x},${y}`)
  })
})

test('eqCurvePath: degenerate band counts do not throw', () => {
  assert.doesNotThrow(() => eqCurvePath([], 260, 140))
  assert.doesNotThrow(() => eqCurvePath([2], 260, 140))
})

test('formatEqBandLabel: matches EQ_BANDS exactly, generated not hardcoded', () => {
  assert.deepEqual(EQ_BANDS.map(formatEqBandLabel), ['60 Hz', '250 Hz', '1 kHz', '4 kHz', '12 kHz'])
})
