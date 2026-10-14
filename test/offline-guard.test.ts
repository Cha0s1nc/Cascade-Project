// Offline Mode sends nothing: every request in the renderer's scripts goes
// through jfClient, jfFetch or webFetch, which refuse while it is on
// (docs/offline-mode-plan.md, section 2). A raw fetch( is allowed only under
// a comment, right above it, that says "offline-ok:" and why.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

for (const file of ['renderer.js', 'waterfall.js', 'lyric-karaoke.js']) {
  test(`${file} sends nothing to the network around Offline Mode's guards`, () => {
    const lines = readFileSync(new URL(`../${file}`, import.meta.url), 'utf8').split('\n')
    const raw: string[] = []
    lines.forEach((line, i) => {
      if (/^\s*(\/\/|\*)/.test(line)) return
      if (!/(?<![\w.])fetch\(/.test(line)) return
      // The comment block right above the call names why it may go out.
      let j = i - 1
      while (j >= 0 && /^\s*\/\//.test(lines[j])) { if (/offline-ok:/.test(lines[j])) return; j-- }
      raw.push(`${file}:${i + 1}: ${line.trim()}`)
    })
    assert.deepEqual(raw, [], 'use jfFetch (the server) or webFetch (anything else)')
  })
}

test('the guard refuses while offline', () => {
  const src = readFileSync(new URL('../renderer.js', import.meta.url), 'utf8')
  assert.match(src, /const jfFetch = \(input, init\) => jfClient\.offline\s*\n\s*\? Promise\.reject\(new CascadeCore\.OfflineError\(\)\)/)
})
