import { test } from 'node:test'
import assert from 'node:assert/strict'
import { LYRIC_KNOBS, lyricStyleFrom, lyricStyleChanges, lyricStyleCss, easeInOut, heldSwell, lyricKnobsWithNewDefaults, LYRIC_DEFAULTS_REVISION, LYRIC_DEFAULTS_CHANGED } from '../src/core/lyric-style.ts'

test('every knob has a sane, unique definition', () => {
  const keys = new Set<string>()
  for (const k of LYRIC_KNOBS) {
    assert.ok(!keys.has(k.key), `${k.key} twice`); keys.add(k.key)
    assert.ok(k.min < k.max && k.value >= k.min && k.value <= k.max, `${k.key} default out of range`)
    assert.ok(k.step > 0 && k.step <= k.max - k.min, `${k.key} step`)
  }
})

test('lyricStyleFrom keeps valid stored values, clamps the rest, and ignores junk', () => {
  const s = lyricStyleFrom({ pastBlur: 2, pastOpacity: 5, next1Blur: 'x', bogus: 1, lyricsDelay: NaN })
  assert.equal(s.pastBlur, 2)
  assert.equal(s.pastOpacity, 1)
  assert.equal(s.next1Blur, 2.5)
  assert.equal(s.lyricsDelay, -0.05)
  assert.ok(!('bogus' in s))
  for (const junk of [null, undefined, 'str', [1, 2], 42]) assert.deepEqual(lyricStyleFrom(junk), lyricStyleFrom({}))
})

test('lyricStyleChanges stores only what differs from the defaults', () => {
  assert.deepEqual(lyricStyleChanges(lyricStyleFrom({})), {})
  assert.deepEqual(lyricStyleChanges(lyricStyleFrom({ pastBlur: 2, wordLift: 0.04 })), { pastBlur: 2 })
})

test('lyricStyleCss writes units, and leaves JS-only knobs out', () => {
  const css = lyricStyleCss(lyricStyleFrom({ pastBlur: 2 }))
  assert.equal(css['--ly-past-blur'], '2px')
  assert.equal(css['--ly-fade'], '1s')
  assert.equal(css['--word-lift'], '0.04em')
  assert.equal(css['--ly-past-opacity'], '0.3')
  assert.ok(!Object.values(css).some(v => v.includes('NaN')))
  assert.equal(Object.keys(css).length, LYRIC_KNOBS.filter(k => k.css).length)
})

test('easeInOut matches cubic-bezier(0.42, 0, 0.58, 1) at its known points', () => {
  assert.equal(easeInOut(0), 0)
  assert.equal(easeInOut(1), 1)
  assert.ok(Math.abs(easeInOut(0.5) - 0.5) < 1e-6)
  assert.ok(easeInOut(0.25) < 0.25 && easeInOut(0.75) > 0.75)
  for (let t = 0; t < 1; t += 0.05) assert.ok(easeInOut(t + 0.05) >= easeInOut(t), 'monotonic')
})

test('heldSwell: longer holds swell more, rise until the note ends, then go back to normal', () => {
  // Pinned rather than the defaults, which are tuned by ear and move: full
  // after 3 s, 0.3 at 1 s, released over 0.6 s.
  const s = lyricStyleFrom({ heldFullSeconds: 3, heldMinStrength: 0.3, heldSettleSeconds: 0.6 })
  assert.equal(heldSwell(-0.1, 1, 1, s), 0)
  // Peak strength by length: 1 s hold 0.3, 2 s halfway, 3 s and longer full.
  assert.ok(Math.abs(heldSwell(1, 1, 1, s) - 0.3) < 1e-6)
  assert.ok(Math.abs(heldSwell(2, 2, 2, s) - 0.65) < 1e-6)
  assert.ok(Math.abs(heldSwell(5, 5, 5, s) - 1) < 1e-6)
  // Rising until the note ends, easing off after, and back to nothing once released.
  assert.ok(heldSwell(1, 4, 4, s) < heldSwell(3, 4, 4, s))
  assert.ok(heldSwell(4 + 0.3, 4, 4, s) < heldSwell(4, 4, 4, s))
  assert.equal(heldSwell(4 + 0.6, 4, 4, s), 0)
  assert.equal(heldSwell(30, 4, 4, s), 0)
  // A letter reached near the end still takes 0.35 s to rise, not a pop.
  assert.ok(heldSwell(0.1, 0.05, 4, s) < heldSwell(0.34, 0.05, 4, s))
})

test('lyricKnobsWithNewDefaults: only re-baked knobs this person changed, once', () => {
  // Never touched anything: the new defaults already reach them, nothing to ask.
  assert.deepEqual(lyricKnobsWithNewDefaults({}, undefined), [])
  // Changed a re-baked knob and an untouched one: only the re-baked one is asked about.
  const keys = lyricKnobsWithNewDefaults({ heldScale: 1.12, pastBlur: 2 }, 1).map(k => k.key)
  assert.deepEqual(keys, ['heldScale'])
  // Already saw this revision: nothing.
  assert.deepEqual(lyricKnobsWithNewDefaults({ heldScale: 1.12 }, LYRIC_DEFAULTS_REVISION), [])
  // Junk for the seen revision counts as the first.
  assert.deepEqual(lyricKnobsWithNewDefaults({ lyricsDelay: -0.3 }, 'x').map(k => k.key), ['lyricsDelay'])
})

test('LYRIC_DEFAULTS_CHANGED names real knobs', () => {
  const known = new Set(LYRIC_KNOBS.map(k => k.key))
  for (const keys of Object.values(LYRIC_DEFAULTS_CHANGED)) for (const k of keys) assert.ok(known.has(k), k)
})
