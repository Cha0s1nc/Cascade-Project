import { test } from 'node:test'
import assert from 'node:assert/strict'
import { songSortValue, sortSongs, shuffleInPlace, shuffled } from '../src/core/queue.ts'
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
