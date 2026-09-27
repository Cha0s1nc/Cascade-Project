import { test } from 'node:test'
import assert from 'node:assert/strict'
import { topSongsOf } from '../src/core/artist-page.ts'
import type { JfItem } from '../src/core/types.ts'

const item = (over: Partial<JfItem> & { Id: string }): JfItem => over

test('topSongsOf: orders by PlayCount descending', () => {
  const songs = [
    item({ Id: 'a', Name: 'A', UserData: { PlayCount: 1 } }),
    item({ Id: 'b', Name: 'B', UserData: { PlayCount: 5 } }),
    item({ Id: 'c', Name: 'C', UserData: { PlayCount: 3 } }),
  ]
  assert.deepEqual(topSongsOf(songs).map(i => i.Id), ['b', 'c', 'a'])
})

test('topSongsOf: a track with no plays (missing PlayCount reads as zero) is excluded, not crashed on', () => {
  const songs = [
    item({ Id: 'a', Name: 'A' }),
    item({ Id: 'b', Name: 'B', UserData: { PlayCount: 2 } }),
  ]
  assert.deepEqual(topSongsOf(songs).map(i => i.Id), ['b'])
})

test('topSongsOf: nobody has played anything yet - empty, not the full list alphabetized', () => {
  const songs = [
    item({ Id: 'a', Name: 'A' }),
    item({ Id: 'b', Name: 'B' }),
  ]
  assert.deepEqual(topSongsOf(songs), [])
})

test('topSongsOf: ties break alphabetically by name for a stable order', () => {
  const songs = [
    item({ Id: 'z', Name: 'Zebra', UserData: { PlayCount: 4 } }),
    item({ Id: 'a', Name: 'Apple', UserData: { PlayCount: 4 } }),
  ]
  assert.deepEqual(topSongsOf(songs).map(i => i.Id), ['a', 'z'])
})

test('topSongsOf: clamped to max, does not mutate the input array', () => {
  const songs = Array.from({ length: 15 }, (_, i) => item({ Id: String(i), Name: String(i), UserData: { PlayCount: i } }))
  const top = topSongsOf(songs)
  assert.equal(top.length, 10)
  assert.equal(top[0].Id, '14')
  assert.equal(songs.length, 15) // unchanged
})

test('topSongsOf: custom max is respected', () => {
  const songs = Array.from({ length: 8 }, (_, i) => item({ Id: String(i), Name: String(i), UserData: { PlayCount: i } }))
  assert.equal(topSongsOf(songs, 5).length, 5)
})
