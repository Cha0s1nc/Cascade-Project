import { test } from 'node:test'
import assert from 'node:assert/strict'
import { LYRIC_KNOBS, lyricStyleFrom, lyricStyleChanges, lyricStyleCss } from '../src/core/lyric-style.ts'

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
  assert.equal(s.lyricsDelay, -0.35)
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
