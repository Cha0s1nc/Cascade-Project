import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  songSortValue,
  sortSongs,
  shuffleInPlace,
  shuffled,
  nextRepeatMode,
  setShuffle,
  advanceOnEnd,
  manualNextIndex,
  manualPreviousIndex,
} from '../src/core/queue.ts'
import type { JfItem } from '../src/core/types.ts'

const item = (over: Partial<JfItem> & { Id: string }): JfItem => over

test('songSortValue: falls back through artist sources', () => {
  assert.equal(songSortValue(item({ Id: '1', AlbumArtist: 'Boards' }), 'artist'), 'boards')
  assert.equal(songSortValue(item({ Id: '2', Artists: ['Aphex'] }), 'artist'), 'aphex')
  assert.equal(songSortValue(item({ Id: '3' }), 'artist'), '')
})

test('songSortValue: dates become epoch millis, junk becomes 0', () => {
  assert.equal(songSortValue(item({ Id: '1', DateCreated: '2020-01-01T00:00:00Z' }), 'added'),
    Date.parse('2020-01-01T00:00:00Z'))
  assert.equal(songSortValue(item({ Id: '2', DateCreated: 'not-a-date' }), 'added'), 0)
  assert.equal(songSortValue(item({ Id: '3' }), 'added'), 0)
})

test('songSortValue: unknown field sorts by name', () => {
  assert.equal(songSortValue(item({ Id: '1', Name: 'Zebra' }), 'nonsense'), 'zebra')
})

test('sortSongs: ascending and descending by name', () => {
  const items = [item({ Id: '1', Name: 'Charlie' }), item({ Id: '2', Name: 'alpha' }), item({ Id: '3', Name: 'Bravo' })]

  sortSongs(items, 'name', 'asc')
  assert.deepEqual(items.map(i => i.Id), ['2', '3', '1'], 'case-insensitive ascending')

  sortSongs(items, 'name', 'desc')
  assert.deepEqual(items.map(i => i.Id), ['1', '3', '2'])
})

test('sortSongs: sorts in place and returns the same array', () => {
  // renderer.js holds a long-lived reference to `allSongs`; replacing the array
  // instead of sorting it would strand every other holder.
  const items = [item({ Id: '1', Name: 'b' }), item({ Id: '2', Name: 'a' })]
  const out = sortSongs(items, 'name', 'asc')
  assert.equal(out, items, 'must be the same array reference')
  assert.equal(items[0].Id, '2')
})

test('shuffleInPlace: keeps every element, mutates the original', () => {
  const arr = Array.from({ length: 50 }, (_, i) => i)
  const out = shuffleInPlace(arr)
  assert.equal(out, arr, 'same reference')
  assert.deepEqual([...arr].sort((a, b) => a - b), Array.from({ length: 50 }, (_, i) => i))
})

test('shuffled: leaves the input untouched', () => {
  const original = [1, 2, 3, 4, 5]
  const copy = [...original]
  const out = shuffled(original)
  assert.deepEqual(original, copy, 'input must not be mutated')
  assert.notEqual(out, original)
  assert.deepEqual([...out].sort((a, b) => a - b), copy)
})

test('shuffled: actually reorders (not a no-op)', () => {
  // 40 elements shuffled 20 times - if every run came back identical the
  // shuffle is broken. Odds of a false failure are effectively nil.
  const src = Array.from({ length: 40 }, (_, i) => i)
  const anyDifferent = Array.from({ length: 20 })
    .some(() => shuffled(src).some((v, i) => v !== src[i]))
  assert.ok(anyDifferent, 'shuffled() never changed the order')
})

test('shuffleInPlace: handles empty and single-element arrays', () => {
  assert.deepEqual(shuffleInPlace([]), [])
  assert.deepEqual(shuffleInPlace([7]), [7])
})

// --- repeat and shuffle ----------------------------------------------------

const track = (id: string): JfItem => ({ Id: id, Name: id } as JfItem)
const ids = (items: { Id: string }[]) => items.map(t => t.Id)

test('the repeat button cycles none -> all -> one -> none', () => {
  assert.equal(nextRepeatMode('none'), 'all')
  assert.equal(nextRepeatMode('all'), 'one')
  assert.equal(nextRepeatMode('one'), 'none')
})

test('turning shuffle on keeps the current track playing, at the front', () => {
  const items = ['a', 'b', 'c', 'd', 'e'].map(track)
  const on = setShuffle({ items, index: 2, unshuffled: null }, true)

  assert.equal(on.items[0]?.Id, 'c', 'the playing track moves to the front')
  assert.equal(on.index, 0)
  assert.deepEqual(ids(on.items).sort(), ['a', 'b', 'c', 'd', 'e'], 'no track lost or duplicated')
  assert.deepEqual(ids(on.unshuffled ?? []), ['a', 'b', 'c', 'd', 'e'], 'original order saved')
})

test('turning shuffle off restores the order and finds the track by id, not index', () => {
  const items = ['a', 'b', 'c', 'd', 'e'].map(track)
  const on = setShuffle({ items, index: 3, unshuffled: null }, true)
  const off = setShuffle(on, false)

  assert.deepEqual(ids(off.items), ['a', 'b', 'c', 'd', 'e'])
  assert.equal(off.items[off.index]?.Id, 'd', 'still playing the same track')
  assert.equal(off.unshuffled, null)
})

test('setShuffle does not mutate what it is given', () => {
  const items = ['a', 'b', 'c', 'd'].map(track)
  const before = ids(items)
  setShuffle({ items, index: 1, unshuffled: null }, true)
  assert.deepEqual(ids(items), before)
})

test('turning shuffle on twice does not reshuffle or lose the saved order', () => {
  const items = ['a', 'b', 'c', 'd'].map(track)
  const once = setShuffle({ items, index: 0, unshuffled: null }, true)
  const twice = setShuffle(once, true)
  assert.equal(twice, once)
})

test('a track ending advances, wraps on repeat-all, and stops otherwise', () => {
  assert.deepEqual(advanceOnEnd(3, 0, 'none'), { action: 'play', index: 1 })
  assert.deepEqual(advanceOnEnd(3, 2, 'none'), { action: 'stop' })
  assert.deepEqual(advanceOnEnd(3, 2, 'all'), { action: 'play', index: 0 })
  assert.deepEqual(advanceOnEnd(3, 1, 'one'), { action: 'restart' })
  assert.deepEqual(advanceOnEnd(0, 0, 'all'), { action: 'stop' }, 'an empty queue has nothing to wrap to')
})

test('pressing next with repeat-one on still skips', () => {
  // The distinction that makes advanceOnEnd and manualNextIndex separate
  // functions: repeat-one replays on end, but a next press must still move.
  assert.deepEqual(advanceOnEnd(3, 0, 'one'), { action: 'restart' })
  assert.equal(manualNextIndex(3, 0, 'one'), 1)
})

test('next and previous wrap only on repeat-all', () => {
  assert.equal(manualNextIndex(3, 2, 'none'), -1)
  assert.equal(manualNextIndex(3, 2, 'all'), 0)
  assert.equal(manualPreviousIndex(3, 0, 'none'), -1)
  assert.equal(manualPreviousIndex(3, 0, 'all'), 2)
  assert.equal(manualPreviousIndex(3, 2, 'none'), 1)
  assert.equal(manualNextIndex(0, 0, 'all'), -1)
})
