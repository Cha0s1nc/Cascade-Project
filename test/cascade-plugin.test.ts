import { test } from 'node:test'
import assert from 'node:assert/strict'
import { interpretCascadePluginProbe } from '../src/core/cascade-plugin.ts'

test('400 means the plugin is present - route matched, guid binding failed', () => {
  assert.equal(interpretCascadePluginProbe(400), 'present')
})

test('404 means the plugin is absent - no route matched at all', () => {
  assert.equal(interpretCascadePluginProbe(404), 'absent')
})

test('401 is inconclusive, not absent', () => {
  assert.equal(interpretCascadePluginProbe(401), 'unknown')
})

test('a 5xx is inconclusive, not absent', () => {
  assert.equal(interpretCascadePluginProbe(500), 'unknown')
  assert.equal(interpretCascadePluginProbe(503), 'unknown')
})

test('no status at all (a thrown/network error) is inconclusive', () => {
  assert.equal(interpretCascadePluginProbe(null), 'unknown')
})
