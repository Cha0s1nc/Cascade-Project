import { test } from 'node:test'
import assert from 'node:assert/strict'
import { windowBoundsToRestore } from '../src/core/window-state.ts'

const MIN = { width: 800, height: 560 }
// Three monitors side by side, the middle one primary, like a desk setup.
const LEFT = { x: -1920, y: 0, width: 1920, height: 1040 }
const MIDDLE = { x: 0, y: 0, width: 2560, height: 1400 }
const RIGHT = { x: 2560, y: 200, width: 1920, height: 1040 }

test('restores a window on any connected monitor, maximized or not', () => {
  assert.deepEqual(windowBoundsToRestore({ x: 2800, y: 300, width: 1100, height: 700, maximized: true }, [LEFT, MIDDLE, RIGHT], MIN),
    { bounds: { x: 2800, y: 300, width: 1100, height: 700 }, maximized: true })
  assert.deepEqual(windowBoundsToRestore({ x: -1500, y: 100, width: 1100, height: 700 }, [LEFT, MIDDLE, RIGHT], MIN)?.bounds,
    { x: -1500, y: 100, width: 1100, height: 700 })
})

test('a window on a monitor that is gone falls back to the default placement', () => {
  assert.equal(windowBoundsToRestore({ x: 2800, y: 300, width: 1100, height: 700 }, [MIDDLE], MIN), null)
  // Title bar above every display (only its bottom edge would show).
  assert.equal(windowBoundsToRestore({ x: 100, y: -500, width: 1100, height: 700 }, [MIDDLE], MIN), null)
})

test('a window too big for its monitor is shrunk and kept on it', () => {
  assert.deepEqual(windowBoundsToRestore({ x: 2600, y: 250, width: 3000, height: 2000 }, [MIDDLE, RIGHT], MIN)?.bounds,
    { x: 2560, y: 200, width: 1920, height: 1040 })
})

test('junk is ignored, and sizes never go below the window minimum', () => {
  for (const junk of [null, undefined, 'x', { x: 1 }, { x: NaN, y: 0, width: 1, height: 1 }]) assert.equal(windowBoundsToRestore(junk, [MIDDLE], MIN), null)
  assert.deepEqual(windowBoundsToRestore({ x: 10, y: 10, width: 100, height: 100 }, [MIDDLE], MIN)?.bounds, { x: 10, y: 10, width: 800, height: 560 })
})
