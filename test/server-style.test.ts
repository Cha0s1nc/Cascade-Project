import { test } from 'node:test'
import assert from 'node:assert/strict'
import { layeredLook, layeredLyricChanges, parseServerStyle, serverStylePart, SERVER_STYLE_OFF } from '../src/core/server-style.ts'

const preset = {
  format: 'cascade-preset', version: 1, name: 'House',
  theme: { mode: 'light', gradStart: '#111111', gradEnd: '#222222', albumArt: true, bgDim: 0.5, bgBlend: false, font: { preset: 'serif', custom: '' } },
  lyrics: { style: { pastBlur: 3 }, lyricScale: 1.2 },
}
const mine = { gradStart: '#aaaaaa', gradEnd: '#bbbbbb', albumArt: false, bgDim: 0.16, bgBlend: true, lyricScale: 1 }

test('anything unexpected from the server reads as off', () => {
  for (const raw of [null, 'x', {}, { mode: 'off', preset }, { mode: 'default' }, { mode: 'enforced', preset: { format: 'nope' } }]) {
    assert.deepEqual(parseServerStyle(raw), SERVER_STYLE_OFF)
  }
})

test('enforce flags count only in enforced mode', () => {
  const d = parseServerStyle({ mode: 'default', enforce: { theme: true, lyrics: true }, preset })
  assert.equal(serverStylePart(d, 'theme'), 'fill')
  const e = parseServerStyle({ mode: 'enforced', enforce: { theme: true, lyrics: false }, preset })
  assert.equal(serverStylePart(e, 'theme'), 'force')
  assert.equal(serverStylePart(e, 'lyrics'), 'fill')
})

test('default fills only what the person never set', () => {
  const s = parseServerStyle({ mode: 'default', preset })
  assert.deepEqual(layeredLyricChanges({ pastBlur: 1, lineGap: 9 }, s), { pastBlur: 1, lineGap: 9 })
  assert.deepEqual(layeredLyricChanges(null, s), { pastBlur: 3 })
  const fresh = layeredLook(mine, { colors: false, tuning: false }, s)
  assert.equal(fresh.gradStart, '#111111'); assert.equal(fresh.bgDim, 0.5); assert.equal(fresh.lyricScale, 1.2)
  assert.deepEqual(layeredLook(mine, { colors: true, tuning: true }, s), mine)
})

test('enforced puts the server look over the person\'s own', () => {
  const s = parseServerStyle({ mode: 'enforced', enforce: { theme: true, lyrics: true }, preset })
  assert.deepEqual(layeredLyricChanges({ pastBlur: 1, lineGap: 9 }, s), { pastBlur: 3 })
  const look = layeredLook(mine, { colors: true, tuning: true }, s)
  assert.equal(look.gradEnd, '#222222'); assert.equal(look.albumArt, true); assert.equal(look.bgBlend, false); assert.equal(look.lyricScale, 1.2)
})

test('off leaves everything as the person has it', () => {
  assert.deepEqual(layeredLook(mine, { colors: false, tuning: false }, SERVER_STYLE_OFF), mine)
  assert.deepEqual(layeredLyricChanges({ lineGap: 9 }, SERVER_STYLE_OFF), { lineGap: 9 })
})
