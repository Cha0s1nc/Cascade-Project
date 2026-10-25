import { test } from 'node:test'
import assert from 'node:assert/strict'
import { stepSpring, SPRING_SNAP_GAP_S, type SpringMotion } from '../src/core/spring.ts'

// The shipped lyric motion (LYRIC_MOTION in renderer.js).
const LYRIC: SpringMotion = { stiffness: 250, damping: 50 }

/** Runs a 100px move at a fixed frame rate, the way createSpring does. */
function run(fps: number, seconds = 4) {
  let state = { pos: 0, vel: 0 }
  let maxPos = -Infinity, minPos = Infinity, settledAt: number | null = null
  const frames = Math.ceil(seconds * fps)
  for (let i = 1; i <= frames; i++) {
    const next = stepSpring(state, 100, 1 / fps, LYRIC)
    state = { pos: next.pos, vel: next.vel }
    maxPos = Math.max(maxPos, state.pos)
    minPos = Math.min(minPos, state.pos)
    if (next.settled && settledAt == null) settledAt = i / fps
  }
  return { state, maxPos, minPos, settledAt }
}

test('the lyric spring settles without overshoot at any frame rate', () => {
  // 25 fps and below is where one explicit step per frame used to diverge.
  for (const fps of [120, 60, 30, 25, 20, 10, 5]) {
    const r = run(fps)
    assert.ok(r.maxPos <= 100 + 1e-6, `${fps} fps overshot to ${r.maxPos}`)
    assert.ok(r.minPos >= 0, `${fps} fps went backwards to ${r.minPos}`)
    assert.equal(r.state.pos, 100, `${fps} fps did not land on the target`)
    assert.ok(r.settledAt != null && r.settledAt < 2.5, `${fps} fps settled at ${r.settledAt}`)
  }
})

test('the same move takes about the same time whatever the frame rate', () => {
  const fast = run(120).settledAt!
  const slow = run(10).settledAt!
  assert.ok(Math.abs(fast - slow) < 0.2, `${fast}s at 120 fps against ${slow}s at 10 fps`)
})

test('a gap longer than the snap limit lands on the target', () => {
  const next = stepSpring({ pos: 0, vel: 400 }, 100, SPRING_SNAP_GAP_S + 0.01, LYRIC)
  assert.deepEqual(next, { pos: 100, vel: 0, settled: true })
})

test('a zero, negative or non-finite gap does not move the spring', () => {
  for (const dt of [0, -1, NaN]) {
    const next = stepSpring({ pos: 10, vel: 5 }, 100, dt, LYRIC)
    assert.equal(next.pos, 10)
    assert.equal(next.vel, 5)
    assert.equal(next.settled, false)
  }
})

test('a spring already on its target reports settled', () => {
  assert.deepEqual(stepSpring({ pos: 100, vel: 0 }, 100, 1 / 60, LYRIC), { pos: 100, vel: 0, settled: true })
})
