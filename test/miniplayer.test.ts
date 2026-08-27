import { test } from 'node:test'
import assert from 'node:assert/strict'
import { buildMiniplayerState, miniplayerProgressPct, isMiniplayerAction } from '../src/core/miniplayer.ts'

test('miniplayerProgressPct is 0 with no duration yet', () => {
  assert.equal(miniplayerProgressPct(0, 0), 0)
  assert.equal(miniplayerProgressPct(5, 0), 0)
})

test('miniplayerProgressPct clamps to 0-100 against garbage input', () => {
  assert.equal(miniplayerProgressPct(NaN, 100), 0)
  assert.equal(miniplayerProgressPct(10, NaN), 0)
  assert.equal(miniplayerProgressPct(-5, 100), 0)
  assert.equal(miniplayerProgressPct(150, 100), 100)
  assert.equal(miniplayerProgressPct(-Infinity, 100), 0)
})

test('miniplayerProgressPct is the plain ratio in the normal case', () => {
  assert.equal(miniplayerProgressPct(30, 120), 25)
})

test('buildMiniplayerState never produces NaN or an out-of-range percentage', () => {
  const track = { itemId: 'abc', title: 'Song', subtitle: 'Artist', artUrl: null }
  for (const [pos, dur] of [[NaN, 100], [10, NaN], [-5, 50], [999, 60], [0, 0]] as const) {
    const s = buildMiniplayerState(track, true, pos, dur)
    assert.ok(Number.isFinite(s.positionSec))
    assert.ok(Number.isFinite(s.durationSec))
    assert.ok(s.progressPct >= 0 && s.progressPct <= 100)
  }
})

test('buildMiniplayerState copies the track fields through untouched', () => {
  const track = { itemId: 'xyz', title: 'Title', subtitle: 'Sub', artUrl: 'http://x/art.jpg' }
  const s = buildMiniplayerState(track, false, 12, 34)
  assert.equal(s.itemId, 'xyz')
  assert.equal(s.title, 'Title')
  assert.equal(s.subtitle, 'Sub')
  assert.equal(s.artUrl, 'http://x/art.jpg')
  assert.equal(s.isPlaying, false)
})

test('isMiniplayerAction accepts only the closed set of control actions', () => {
  assert.ok(isMiniplayerAction('playpause'))
  assert.ok(isMiniplayerAction('next'))
  assert.ok(isMiniplayerAction('prev'))
  assert.ok(!isMiniplayerAction('seek'))
  assert.ok(!isMiniplayerAction(''))
  assert.ok(!isMiniplayerAction(null))
  assert.ok(!isMiniplayerAction(42))
})
