import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  songSortValue, sortSongs, shuffleInPlace, shuffled, nextQueueIndex, insertAfterCurrent,
  queueRemainingSec, formatQueueSpan, queueSourceFallback,
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

test('nextQueueIndex: plain advance', () => {
  assert.equal(nextQueueIndex(5, 0, 'none'), 1)
  assert.equal(nextQueueIndex(5, 3, 'none'), 4)
})

test('nextQueueIndex: end of queue with no repeat has nothing next', () => {
  assert.equal(nextQueueIndex(5, 4, 'none'), null)
})

test('nextQueueIndex: end of queue with repeat-all wraps to the start', () => {
  assert.equal(nextQueueIndex(5, 4, 'all'), 0)
})

test('nextQueueIndex: repeat-one never advances, even at the end', () => {
  assert.equal(nextQueueIndex(5, 2, 'one'), null)
  assert.equal(nextQueueIndex(5, 4, 'one'), null)
})

test('nextQueueIndex: empty queue has nothing next', () => {
  assert.equal(nextQueueIndex(0, -1, 'none'), null)
})

test('insertAfterCurrent: lands directly after the playing track', () => {
  const out = insertAfterCurrent(['a', 'b', 'c'], 0, ['x'])
  assert.deepEqual(out, ['a', 'x', 'b', 'c'])
})

test('insertAfterCurrent: never lands before or on the playing track', () => {
  // queueIndex + 1, not queueIndex - inserting at/before it would change
  // what's currently playing.
  const out = insertAfterCurrent(['a', 'b', 'c'], 1, ['x'])
  assert.deepEqual(out, ['a', 'b', 'x', 'c'])
})

test('insertAfterCurrent: appending after the last track', () => {
  const out = insertAfterCurrent(['a', 'b'], 1, ['x'])
  assert.deepEqual(out, ['a', 'b', 'x'])
})

test('insertAfterCurrent: nothing playing yet inserts at the front, not negative', () => {
  const out = insertAfterCurrent(['a', 'b'], -1, ['x'])
  assert.deepEqual(out, ['x', 'a', 'b'])
})

test('insertAfterCurrent: multiple items keep their given order', () => {
  const out = insertAfterCurrent(['a', 'b'], 0, ['x', 'y', 'z'])
  assert.deepEqual(out, ['a', 'x', 'y', 'z', 'b'])
})

test('insertAfterCurrent: does not mutate the input queue', () => {
  const original = ['a', 'b', 'c']
  const copy = [...original]
  insertAfterCurrent(original, 0, ['x'])
  assert.deepEqual(original, copy)
})

test('queue remaining: rest of the current track plus everything after it', () => {
  const t = (sec: number) => ({ Id: String(sec), Name: '', RunTimeTicks: sec * 10_000_000 })
  const q = [t(100), t(200), t(300), { Id: 'x', Name: '' }]
  assert.equal(queueRemainingSec(q, 1, 50), 150 + 300)
  assert.equal(queueRemainingSec(q, 1, 999), 300)        // past the end of the current track
  assert.equal(queueRemainingSec(q, 3, 0), 0)            // no RunTimeTicks counts as 0
  assert.equal(queueRemainingSec(q, -1, 0), 0)
  assert.equal(queueRemainingSec([], 0, 0), 0)
})

test('queue span formatting, up to days', () => {
  assert.equal(formatQueueSpan(30), '<1m')
  assert.equal(formatQueueSpan(34 * 60 + 59), '34m')
  assert.equal(formatQueueSpan(2 * 3600 + 5 * 60), '2h 5m')
  assert.equal(formatQueueSpan(3 * 3600), '3h')
  assert.equal(formatQueueSpan(25 * 3600 + 10 * 60), '1d 1h')
  assert.equal(formatQueueSpan(48 * 3600), '2d')
})

test('queue source fallback: the album name only when every track shares it', () => {
  const a = { Id: '1', Name: '', AlbumId: 'A', Album: 'Fever' }
  assert.equal(queueSourceFallback([a, { ...a, Id: '2' }]), 'Fever')
  assert.equal(queueSourceFallback([a, { ...a, Id: '2', AlbumId: 'B' }]), null)
  assert.equal(queueSourceFallback([{ Id: '1', Name: '' }]), null)
  assert.equal(queueSourceFallback([]), null)
})
