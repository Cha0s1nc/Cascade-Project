import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  interpretCascadePluginProbe,
  resolveCascadePluginProbe,
  cascadeLyricsPath,
} from '../src/core/cascade-plugin.ts'

test('200 means the plugin is present - the Info route answered', () => {
  assert.equal(interpretCascadePluginProbe(200), 'present')
})

test('404 means the plugin is absent - no such route', () => {
  assert.equal(interpretCascadePluginProbe(404), 'absent')
})

test('401 is inconclusive, not absent', () => {
  assert.equal(interpretCascadePluginProbe(401), 'unknown')
})

test('a 5xx is inconclusive, not absent', () => {
  assert.equal(interpretCascadePluginProbe(500), 'unknown')
  assert.equal(interpretCascadePluginProbe(503), 'unknown')
})

test('no status at all (the request threw) is inconclusive', () => {
  assert.equal(interpretCascadePluginProbe(null), 'unknown')
})

test('CascadeServer/Info answering means the current plugin, current routes', () => {
  assert.deepEqual(resolveCascadePluginProbe(200, null), { probe: 'present', api: 'server' })
})

test('new route 404 and old route 200 is the pre-rename plugin, old routes', () => {
  assert.deepEqual(resolveCascadePluginProbe(404, 200), { probe: 'present', api: 'legacy' })
})

test('both routes 404 means no plugin', () => {
  assert.equal(resolveCascadePluginProbe(404, 404).probe, 'absent')
})

test('new route 404 and old route inconclusive stays unknown, not absent', () => {
  assert.equal(resolveCascadePluginProbe(404, 500).probe, 'unknown')
  assert.equal(resolveCascadePluginProbe(404, null).probe, 'unknown')
})

test('an inconclusive new route stays unknown on the current routes', () => {
  assert.deepEqual(resolveCascadePluginProbe(null, null), { probe: 'unknown', api: 'server' })
  assert.deepEqual(resolveCascadePluginProbe(401, null), { probe: 'unknown', api: 'server' })
})

test('lyrics path follows the api that answered', () => {
  assert.equal(cascadeLyricsPath('server', 'abc'), 'CascadeServer/Lyrics/abc')
  assert.equal(cascadeLyricsPath('legacy', 'abc'), 'Audio/abc/CascadeLyrics')
})
