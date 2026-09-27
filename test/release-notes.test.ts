import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const { renderReleaseNotes } = createRequire(import.meta.url)('../release-notes.js')

test('renderReleaseNotes nests tab-indented bullets under their parent', () => {
  const html = renderReleaseNotes('- Added Jellyfin 12 support\r\n\t- Older versions will *not* connect\r\n- Karaoke lyrics')
  assert.equal(html,
    '<ul><li>Added Jellyfin 12 support<ul><li>Older versions will <em>not</em> connect</li></ul></li><li>Karaoke lyrics</li></ul>')
})

test('renderReleaseNotes handles the emphasis the 2.2.0 notes use', () => {
  assert.equal(renderReleaseNotes('Spicy Lyrics is ***ONLY*** with **the** plugin'),
    '<p>Spicy Lyrics is <strong><em>ONLY</em></strong> with <strong>the</strong> plugin</p>')
  assert.equal(renderReleaseNotes('Use `npm test` and ~~old~~ new'),
    '<p>Use <code>npm test</code> and <del>old</del> new</p>')
})

test('renderReleaseNotes links only http(s) URLs and escapes everything else', () => {
  assert.equal(renderReleaseNotes('[CascadeServer](https://github.com/Cha0s1nc/CascadeServer_x_)'),
    '<p><a href="https://github.com/Cha0s1nc/CascadeServer_x_">CascadeServer</a></p>')
  const hostile = renderReleaseNotes('[x](javascript:alert(1)) <img src=x onerror=alert(1)>')
  assert.doesNotMatch(hostile, /<img|href="javascript/)
  assert.match(hostile, /&lt;img/)
})

test('renderReleaseNotes renders headings, rules and an empty body', () => {
  assert.equal(renderReleaseNotes('## Major changes\n\n---\nDone'), '<h2>Major changes</h2><hr><p>Done</p>')
  assert.match(renderReleaseNotes(''), /No release notes available/)
})
