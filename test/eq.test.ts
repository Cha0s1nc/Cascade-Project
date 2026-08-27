import { test } from 'node:test'
import assert from 'node:assert/strict'
import { eqLevels, MIN_BAR_HEIGHT } from '../src/core/eq.ts'

test('all-zero input gives every bar the minimum height', () => {
  const bytes = new Uint8Array(64)
  assert.deepEqual(eqLevels(bytes), [MIN_BAR_HEIGHT, MIN_BAR_HEIGHT, MIN_BAR_HEIGHT])
})

test('a loud low band raises the first bar and not the others', () => {
  const bytes = new Uint8Array(64)
  for (let i = 1; i < 8; i++) bytes[i] = 255   // well inside the low band
  const [low, mid, high] = eqLevels(bytes)
  assert.ok(low > MIN_BAR_HEIGHT, `expected low bar to rise, got ${low}`)
  assert.equal(mid, MIN_BAR_HEIGHT)
  assert.equal(high, MIN_BAR_HEIGHT)
})

test('output is always clamped into range', () => {
  const bytes = new Uint8Array(64).fill(255)
  for (const level of eqLevels(bytes)) {
    assert.ok(level >= MIN_BAR_HEIGHT && level <= 1, `${level} out of range`)
  }
})

test('a short or empty array does not throw', () => {
  assert.deepEqual(eqLevels(new Uint8Array(0)), [MIN_BAR_HEIGHT, MIN_BAR_HEIGHT, MIN_BAR_HEIGHT])
  assert.deepEqual(eqLevels(new Uint8Array(1)), [MIN_BAR_HEIGHT, MIN_BAR_HEIGHT, MIN_BAR_HEIGHT])
  assert.doesNotThrow(() => eqLevels(new Uint8Array(3)))
})
