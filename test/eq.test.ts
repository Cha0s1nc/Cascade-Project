import { test } from 'node:test'
import assert from 'node:assert/strict'
import { eqLevels, MIN_BAR_HEIGHT, EQ_BARS, LOW_GAIN, LEVEL_SCALE } from '../src/core/eq.ts'

const flat = (count = EQ_BARS) => Array(count).fill(MIN_BAR_HEIGHT)

test('draws at least six bars', () => {
  assert.ok(EQ_BARS >= 6)
  assert.equal(eqLevels(new Uint8Array(32)).length, EQ_BARS)
})

test('all-zero input gives every bar the minimum height', () => {
  assert.deepEqual(eqLevels(new Uint8Array(64)), flat())
})

test('a loud low band raises the first bar and not the last ones', () => {
  const bytes = new Uint8Array(64)
  for (let i = 1; i < 8; i++) bytes[i] = 255   // well inside the low band
  const levels = eqLevels(bytes)
  assert.ok(levels[0] > MIN_BAR_HEIGHT, `expected low bar to rise, got ${levels[0]}`)
  assert.equal(levels[EQ_BARS - 1], MIN_BAR_HEIGHT)
  assert.equal(levels[EQ_BARS - 2], MIN_BAR_HEIGHT)
})

test('every bar gets its own bins, even from the analyser\'s 32', () => {
  // Only the top band's bins: the highest ones, well clear of its lower edge.
  const bytes = new Uint8Array(32).fill(255, 24)
  const levels = eqLevels(bytes)
  assert.ok(levels[EQ_BARS - 1] > MIN_BAR_HEIGHT)
  assert.deepEqual(levels.slice(0, -1), flat(EQ_BARS - 1))
})

test('output is always clamped into range', () => {
  for (const level of eqLevels(new Uint8Array(64).fill(255))) {
    assert.ok(level >= MIN_BAR_HEIGHT && level <= 1, `${level} out of range`)
  }
})

test('a short or empty array does not throw', () => {
  assert.deepEqual(eqLevels(new Uint8Array(0)), flat())
  assert.deepEqual(eqLevels(new Uint8Array(1)), flat())
  assert.doesNotThrow(() => eqLevels(new Uint8Array(3)))
})

test('a full-scale signal leaves the low bars room to move', () => {
  const levels = eqLevels(new Uint8Array(32).fill(255))
  assert.equal(levels[0], LOW_GAIN * LEVEL_SCALE)
  assert.ok(levels[0] < 1)
})
