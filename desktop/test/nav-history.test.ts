import { test } from 'node:test'
import assert from 'node:assert/strict'
import { navHost, navPush, navTop, navBack, navHome, navCanGoBack, navForget, NAV_MAX_DEPTH, type NavStacks } from '../src/core/nav-history.ts'

test('navHost keeps a page in the tab you are in', () => {
  assert.equal(navHost('playlists', 'artist'), 'playlists')
  assert.equal(navHost('home', 'series'), 'home')
  assert.equal(navHost('downloads', 'album'), 'downloads')
  assert.equal(navHost('albums', 'album'), 'albums')
})

test('navHost sends a page to its category from Settings or the other mode', () => {
  assert.equal(navHost('settings', 'playlist'), 'playlists')
  assert.equal(navHost('albums', 'movie'), 'movies')
  assert.equal(navHost('shows', 'artist'), 'artists')
  assert.equal(navHost('playlists', 'smart'), 'playlists')
})

test('Back walks a tab back to its home, and no further', () => {
  const s: NavStacks = {}
  assert.equal(navCanGoBack(s, 'playlists'), false)
  navPush(s, 'playlists', 'playlist', ['p1'])
  navPush(s, 'playlists', 'artist', ['a1', 'Artist'])
  assert.equal(navTop(s, 'playlists').page, 'artist')
  assert.deepEqual(navBack(s, 'playlists')?.args, ['p1'])
  assert.equal(navBack(s, 'playlists')?.page, null)
  assert.equal(navBack(s, 'playlists'), null)
})

test('each tab keeps its own history', () => {
  const s: NavStacks = {}
  navPush(s, 'playlists', 'playlist', ['p1'])
  navPush(s, 'albums', 'album', ['al1'])
  assert.equal(navTop(s, 'playlists').page, 'playlist')
  assert.equal(navTop(s, 'albums').page, 'album')
  assert.equal(navCanGoBack(s, 'artists'), false)
})

test('clicking the tab you are on goes home, and Back undoes it', () => {
  const s: NavStacks = {}
  navPush(s, 'playlists', 'playlist', ['p1'])
  assert.equal(navHome(s, 'playlists')?.page, null)
  assert.equal(navHome(s, 'playlists'), null)   // already home: no extra step
  assert.deepEqual(navBack(s, 'playlists')?.args, ['p1'])
})

test('history stops growing at NAV_MAX_DEPTH, dropping the oldest steps', () => {
  const s: NavStacks = {}
  for (let i = 0; i < NAV_MAX_DEPTH + 10; i++) navPush(s, 'albums', 'album', [i])
  assert.equal(s.albums.length, NAV_MAX_DEPTH)
  assert.deepEqual(navTop(s, 'albums').args, [NAV_MAX_DEPTH + 9])
})

test('navForget drops a deleted page everywhere and merges the homes it leaves', () => {
  const s: NavStacks = {}
  navPush(s, 'playlists', 'playlist', ['gone'])
  navHome(s, 'playlists')
  navPush(s, 'playlists', 'playlist', ['kept'])
  navPush(s, 'playlists', 'playlist', ['gone'])
  navPush(s, 'home', 'album', ['al1'])
  assert.deepEqual(navForget(s, 'playlist', 'gone'), ['playlists'])
  assert.deepEqual(s.playlists.map(e => e.args[0] ?? 'home'), ['home', 'kept'])
  assert.equal(navTop(s, 'home').page, 'album')
})
