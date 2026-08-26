import { test } from 'node:test'
import assert from 'node:assert/strict'
import { sectionMode, resolveBrowseMode } from '../src/core/browse-mode.ts'

test('sectionMode classifies music and video views correctly', () => {
  assert.equal(sectionMode('albums'), 'music')
  assert.equal(sectionMode('artists'), 'music')
  assert.equal(sectionMode('songs'), 'music')
  assert.equal(sectionMode('playlists'), 'music')
  assert.equal(sectionMode('movies'), 'video')
  assert.equal(sectionMode('shows'), 'video')
})

test('sectionMode returns null for views shown in every mode', () => {
  assert.equal(sectionMode('home'), null)
  assert.equal(sectionMode('settings'), null)
})

test('a fresh install with a video library defaults to music', () => {
  assert.equal(resolveBrowseMode(null, true), 'music')
  assert.equal(resolveBrowseMode(undefined, true), 'music')
})

test('a saved video choice sticks when a video library exists', () => {
  assert.equal(resolveBrowseMode('video', true), 'video')
})

test('a saved music choice, or anything unrecognized, resolves to music', () => {
  assert.equal(resolveBrowseMode('music', true), 'music')
  assert.equal(resolveBrowseMode('garbage', true), 'music')
})

test('no video library forces music regardless of what was saved', () => {
  assert.equal(resolveBrowseMode('video', false), 'music')
  assert.equal(resolveBrowseMode('music', false), 'music')
  assert.equal(resolveBrowseMode(null, false), 'music')
})
