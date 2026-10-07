import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  buildPreset, parsePreset, serializePreset, presetFileName,
  PRESET_DEFAULT_GRADIENT, PRESET_MAX_BYTES,
} from '../src/core/presets.ts'
import { LYRIC_KNOBS } from '../src/core/lyric-style.ts'
import { BG_DIM_DEFAULT, LYRIC_SCALE_DEFAULT, LYRIC_SCALE_MAX } from '../src/core/np-tuning.ts'

const theme = {
  mode: 'light', gradStart: '#F97316', gradEnd: '#ec4899', albumArt: true,
  bgDim: 0.4, bgBlend: false, font: { preset: 'custom', custom: 'Inter' },
}
const lyrics = { style: { pastBlur: 1.5, currentLinePosition: 0.12 }, lyricScale: 1.2 }

test('a preset survives export and import unchanged', () => {
  const built = buildPreset({ name: 'Sunset', theme, lyrics })
  const parsed = parsePreset(serializePreset(built))
  assert.ok(parsed.ok)
  assert.deepEqual(parsed.preset, built)
  assert.equal(built.theme!.gradStart, '#f97316')
  assert.deepEqual(built.theme!.font, { preset: 'custom', custom: 'Inter' })
  assert.deepEqual(built.lyrics, { style: { pastBlur: 1.5, currentLinePosition: 0.12 }, lyricScale: 1.2 })
})

test('a lyrics-only or theme-only preset carries only that part', () => {
  const l = parsePreset(serializePreset(buildPreset({ name: 'L', lyrics })))
  assert.ok(l.ok)
  assert.equal(l.preset.theme, undefined)
  assert.ok(l.preset.lyrics)
  const t = parsePreset(serializePreset(buildPreset({ name: 'T', theme })))
  assert.ok(t.ok)
  assert.equal(t.preset.lyrics, undefined)
  assert.ok(t.preset.theme)
})

test('bad values take the shipped default instead of reaching CSS', () => {
  const text = JSON.stringify({
    format: 'cascade-preset', version: 1, name: 'Bad',
    theme: {
      mode: 'neon', gradStart: 'red; background: url(x)', gradEnd: '#12345', albumArt: 'yes',
      bgDim: 'NaN', bgBlend: 'no', font: { preset: 'custom', custom: 'Evil"; } body { x' },
    },
    lyrics: { style: { pastBlur: 9999, lineGap: 'wide', notAKnob: 3 }, lyricScale: Infinity },
  })
  const r = parsePreset(text)
  assert.ok(r.ok)
  const t = r.preset.theme!
  assert.equal(t.mode, 'dark')
  assert.equal(t.gradStart, PRESET_DEFAULT_GRADIENT.start)
  assert.equal(t.gradEnd, PRESET_DEFAULT_GRADIENT.end)
  assert.equal(t.albumArt, false)
  assert.equal(t.bgDim, BG_DIM_DEFAULT)
  assert.equal(t.bgBlend, true)
  assert.equal(t.font.custom, 'Evil  body  x')
  const pastBlurMax = LYRIC_KNOBS.find(k => k.key === 'pastBlur')!.max
  assert.deepEqual(r.preset.lyrics!.style, { pastBlur: pastBlurMax })
  assert.equal(r.preset.lyrics!.lyricScale, LYRIC_SCALE_DEFAULT)
})

test('out-of-range numbers are clamped, not dropped', () => {
  const r = parsePreset(JSON.stringify({ format: 'cascade-preset', version: 1, lyrics: { lyricScale: 99 } }))
  assert.ok(r.ok)
  assert.equal(r.preset.lyrics!.lyricScale, LYRIC_SCALE_MAX)
})

test('an unknown font preset falls back to System', () => {
  const r = parsePreset(JSON.stringify({ format: 'cascade-preset', version: 1, theme: { font: { preset: 'comic', custom: 'x' } } }))
  assert.ok(r.ok)
  assert.deepEqual(r.preset.theme!.font, { preset: 'system', custom: '' })
})

test('anything that is not a preset is refused with a reason', () => {
  const cases: unknown[] = [
    '', '   ', 42, null, 'not json', '[]', '{}',
    JSON.stringify({ format: 'something-else', version: 1, theme: {} }),
    JSON.stringify({ format: 'cascade-preset', theme: {} }),
    JSON.stringify({ format: 'cascade-preset', version: 1.5, theme: {} }),
    JSON.stringify({ format: 'cascade-preset', version: 1 }),
    JSON.stringify({ format: 'cascade-preset', version: 1, theme: 'dark' }),
  ]
  for (const c of cases) {
    const r = parsePreset(c)
    assert.equal(r.ok, false, `accepted ${JSON.stringify(c)}`)
    if (!r.ok) assert.ok(r.error.length > 0)
  }
})

test('a preset from a newer Cascade says to update', () => {
  const r = parsePreset(JSON.stringify({ format: 'cascade-preset', version: 2, theme: {} }))
  assert.equal(r.ok, false)
  if (!r.ok) assert.match(r.error, /newer Cascade/)
})

test('oversized input is refused before it is parsed', () => {
  const r = parsePreset(' '.repeat(PRESET_MAX_BYTES + 1) + '{}')
  assert.equal(r.ok, false)
  if (!r.ok) assert.match(r.error, /too large/)
})

test('names are cleaned, and file names are safe', () => {
  const r = parsePreset(JSON.stringify({ format: 'cascade-preset', version: 1, name: '  My\u0007 look  ', theme: {} }))
  assert.ok(r.ok)
  assert.equal(r.preset.name, 'My look')
  assert.equal(buildPreset({ name: 42, theme: {} }).name, 'Untitled')
  assert.equal(presetFileName('a/b:c*?'), 'a-b-c-.cascadepreset')
  assert.equal(presetFileName('...'), 'Cascade preset.cascadepreset')
})
