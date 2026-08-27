import { test } from 'node:test'
import assert from 'node:assert/strict'
import { menuItemsForKind, clampMenuPosition } from '../src/core/context-menu.ts'

test('album: play family, add to playlist, go to artist, metadata - no track-only rows', () => {
  const v = menuItemsForKind('album')
  assert.equal(v.play, true)
  assert.equal(v.playNext, true)
  assert.equal(v.playLast, true)
  assert.equal(v.shuffle, true)
  assert.equal(v.addPlaylist, true)
  assert.equal(v.goArtist, true)
  assert.equal(v.refreshMeta, true)
  assert.equal(v.editMeta, true)
  assert.equal(v.instantMix, false)
  assert.equal(v.rename, false)
  assert.equal(v.deleteItem, false)
  assert.equal(v.markPlayed, false)
})

test('artist: play all, shuffle all, instant mix, view page - nothing else', () => {
  const v = menuItemsForKind('artist')
  assert.equal(v.play, true)
  assert.equal(v.shuffle, true)
  assert.equal(v.instantMix, true)
  assert.equal(v.viewDetail, true)
  assert.equal(v.playNext, false)
  assert.equal(v.addPlaylist, false)
  assert.equal(v.refreshMeta, false)
})

test('video (movie/episode): play, detail, and exactly one mark-played row', () => {
  const unplayed = menuItemsForKind('video', { isPlayed: false })
  assert.equal(unplayed.play, true)
  assert.equal(unplayed.viewDetail, true)
  assert.equal(unplayed.markPlayed, true)
  assert.equal(unplayed.markUnplayed, false)

  const played = menuItemsForKind('video', { isPlayed: true })
  assert.equal(played.markPlayed, false)
  assert.equal(played.markUnplayed, true)
})

test('video/series with unknown played state hides both mark rows rather than guessing', () => {
  assert.equal(menuItemsForKind('video').markPlayed, false)
  assert.equal(menuItemsForKind('video').markUnplayed, false)
  assert.equal(menuItemsForKind('series').markPlayed, false)
  assert.equal(menuItemsForKind('series').markUnplayed, false)
})

test('series: no direct play - it is a container, not playable media', () => {
  const v = menuItemsForKind('series', { isPlayed: false })
  assert.equal(v.play, false)
  assert.equal(v.viewDetail, true)
  assert.equal(v.markPlayed, true)
})

test('playlist: play, shuffle, rename, delete', () => {
  const v = menuItemsForKind('playlist')
  assert.equal(v.play, true)
  assert.equal(v.shuffle, true)
  assert.equal(v.rename, true)
  assert.equal(v.deleteItem, true)
  assert.equal(v.addPlaylist, false)
  assert.equal(v.viewDetail, false)
})

test('smart playlist: play and shuffle only - not a real playlist to rename or delete', () => {
  const v = menuItemsForKind('smart-playlist')
  assert.equal(v.play, true)
  assert.equal(v.shuffle, true)
  assert.equal(v.rename, false)
  assert.equal(v.deleteItem, false)
})

test('clampMenuPosition: leaves a menu that fits alone', () => {
  const { left, top } = clampMenuPosition(100, 100, 200, 300, 1920, 1080)
  assert.equal(left, 100)
  assert.equal(top, 100)
})

test('clampMenuPosition: flips left off the right edge', () => {
  const { left, top } = clampMenuPosition(1850, 100, 200, 300, 1920, 1080)
  assert.equal(left, 1650) // 1850 - 200
  assert.equal(top, 100)
})

test('clampMenuPosition: flips up off the bottom edge', () => {
  const { left, top } = clampMenuPosition(100, 1000, 200, 300, 1920, 1080)
  assert.equal(left, 100)
  assert.equal(top, 700) // 1000 - 300
})

test('clampMenuPosition: flips both at a corner', () => {
  const { left, top } = clampMenuPosition(1850, 1000, 200, 300, 1920, 1080)
  assert.equal(left, 1650)
  assert.equal(top, 700)
})

test('clampMenuPosition: never goes negative even when the menu is bigger than the viewport', () => {
  const { left, top } = clampMenuPosition(50, 50, 500, 500, 400, 400)
  assert.equal(left, 0)
  assert.equal(top, 0)
})
