import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  LYRIC_SCALE_MIN, LYRIC_SCALE_MAX, LYRIC_SCALE_DEFAULT,
  BG_DIM_MIN, BG_DIM_MAX, BG_DIM_DEFAULT,
  clampLyricScale, clampBgDim, clampBgBlend,
} from '../src/core/np-tuning.ts'

test('clampLyricScale keeps an in-range value as-is', () => {
  assert.equal(clampLyricScale(1), 1)
  assert.equal(clampLyricScale(0.9), 0.9)
  assert.equal(clampLyricScale(1.25), 1.25)
})

test('clampLyricScale clamps out-of-range values to the bounds', () => {
  assert.equal(clampLyricScale(0.1), LYRIC_SCALE_MIN)
  assert.equal(clampLyricScale(5), LYRIC_SCALE_MAX)
  assert.equal(clampLyricScale(-1), LYRIC_SCALE_MIN)
})

test('clampLyricScale on garbage input always yields a finite default', () => {
  for (const garbage of [NaN, Infinity, -Infinity, null, undefined, 'x', {}, [], '1.1']) {
    const v = clampLyricScale(garbage)
    assert.ok(Number.isFinite(v))
    assert.equal(v, LYRIC_SCALE_DEFAULT)
  }
})

test('clampBgDim keeps an in-range value and clamps out-of-range ones', () => {
  assert.equal(clampBgDim(0.35), 0.35)
  assert.equal(clampBgDim(-2), BG_DIM_MIN)
  assert.equal(clampBgDim(9), BG_DIM_MAX)
})

test('clampBgDim on garbage input never reaches NaN', () => {
  for (const garbage of [NaN, undefined, null, 'x', {}]) {
    assert.equal(clampBgDim(garbage), BG_DIM_DEFAULT)
  }
})

test('clampBgBlend: only an explicit false turns multiply off', () => {
  assert.equal(clampBgBlend(false), false)
  assert.equal(clampBgBlend(true), true)
  assert.equal(clampBgBlend(undefined), true)
  assert.equal(clampBgBlend(null), true)
  assert.equal(clampBgBlend('normal'), true) // a stale/corrupt value reads as the shipped default
})
