import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

// electron-builder strips the "build" section from the package.json it packs
// into the app, so reading it at runtime works in a dev run and throws in every
// shipped copy. That is how every Mac update in 2.1.0 and 2.2.0 hung.
test('shipped code never reads build settings from package.json', () => {
  for (const file of ['main.js', 'mac-update.js']) {
    const src = readFileSync(new URL(`../${file}`, import.meta.url), 'utf8')
    assert.doesNotMatch(src, /package\.json['"]\)\s*\.build\b/, `${file} reads package.json's build section`)
  }
})
