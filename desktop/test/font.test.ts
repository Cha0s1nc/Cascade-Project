import { test } from 'node:test'
import assert from 'node:assert/strict'
import { FONT_PRESETS, sanitizeFontName, resolveUiFont } from '../src/core/font.ts'

test('sanitizeFontName strips anything outside letters/digits/spaces/hyphens', () => {
  assert.equal(sanitizeFontName('Comic Sans MS'), 'Comic Sans MS')
  assert.equal(sanitizeFontName('Fira Code'), 'Fira Code')
  assert.equal(sanitizeFontName('"; } body { display:none'), '  body  displaynone')
  assert.equal(sanitizeFontName("Evil'); DROP TABLE fonts;--"), 'Evil DROP TABLE fonts--')
})

test('sanitizeFontName caps length and rejects non-strings', () => {
  assert.equal(sanitizeFontName('a'.repeat(200)).length, 60)
  assert.equal(sanitizeFontName(null), '')
  assert.equal(sanitizeFontName(undefined), '')
  assert.equal(sanitizeFontName(42), '')
  assert.equal(sanitizeFontName('   '), '')
})

test('resolveUiFont: known preset returns its stack', () => {
  assert.equal(resolveUiFont('sans'), FONT_PRESETS.sans)
  assert.equal(resolveUiFont('serif'), FONT_PRESETS.serif)
  assert.equal(resolveUiFont('mono'), FONT_PRESETS.mono)
  assert.equal(resolveUiFont('system'), FONT_PRESETS.system)
})

test('resolveUiFont: unknown or missing preset falls back to system', () => {
  assert.equal(resolveUiFont(undefined), FONT_PRESETS.system)
  assert.equal(resolveUiFont(null), FONT_PRESETS.system)
  assert.equal(resolveUiFont('a-stale-preset-id-from-an-old-build'), FONT_PRESETS.system)
})

test('resolveUiFont: custom name is quoted and always carries the system stack', () => {
  assert.equal(resolveUiFont('custom', 'Fira Code'), `"Fira Code", ${FONT_PRESETS.system}`)
})

test('resolveUiFont: custom with no usable name falls back to system rather than an empty value', () => {
  assert.equal(resolveUiFont('custom', ''), FONT_PRESETS.system)
  assert.equal(resolveUiFont('custom', undefined), FONT_PRESETS.system)
  assert.equal(resolveUiFont('custom', ';{}/*"'), FONT_PRESETS.system)
})

test('resolveUiFont: a sanitized custom name can never break out of the quoted value', () => {
  const resolved = resolveUiFont('custom', 'Evil"); } * { color: red')
  // Exactly the wrapping quote pair - none of the stripped punctuation reached the value.
  assert.equal((resolved.match(/"/g) || []).length, 2)
  assert.ok(resolved.endsWith(`, ${FONT_PRESETS.system}`))
})
