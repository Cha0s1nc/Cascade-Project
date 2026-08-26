import { test } from 'node:test'
import assert from 'node:assert/strict'
import { entryIdOf, removeSelected, moveSelectedToTop, moveSelectedToBottom } from '../src/core/playlist-edit.ts'
import type { JfItem } from '../src/core/types.ts'

const item = (over: Partial<JfItem> & { Id: string }): JfItem => over

test('entryIdOf: prefers PlaylistItemId, falls back to Id', () => {
  assert.equal(entryIdOf(item({ Id: 'track1', PlaylistItemId: 'entry1' })), 'entry1')
  assert.equal(entryIdOf(item({ Id: 'track1' })), 'track1')
})

test('removeSelected: drops selected rows, keeps the rest in order', () => {
  const items = [item({ Id: 'a' }), item({ Id: 'b' }), item({ Id: 'c' }), item({ Id: 'd' })]
  const out = removeSelected(items, new Set(['b', 'd']))
  assert.deepEqual(out.map(i => i.Id), ['a', 'c'])
})

test('removeSelected: empty selection is a no-op copy', () => {
  const items = [item({ Id: 'a' }), item({ Id: 'b' })]
  const out = removeSelected(items, new Set())
  assert.deepEqual(out.map(i => i.Id), ['a', 'b'])
  assert.notEqual(out, items, 'must not mutate/alias the input array')
})

test('removeSelected: a duplicate track (same Id, different entry) removes only the selected entry', () => {
  const items = [
    item({ Id: 'track', PlaylistItemId: 'e1' }),
    item({ Id: 'track', PlaylistItemId: 'e2' }),
  ]
  const out = removeSelected(items, new Set(['e1']))
  assert.deepEqual(out.map(i => i.PlaylistItemId), ['e2'])
})

test('moveSelectedToTop: pulls selected rows to the front, relative order preserved on both sides', () => {
  const items = [item({ Id: 'a' }), item({ Id: 'b' }), item({ Id: 'c' }), item({ Id: 'd' })]
  const out = moveSelectedToTop(items, new Set(['c', 'a']))
  assert.deepEqual(out.map(i => i.Id), ['a', 'c', 'b', 'd'])
})

test('moveSelectedToBottom: pushes selected rows to the back, relative order preserved on both sides', () => {
  const items = [item({ Id: 'a' }), item({ Id: 'b' }), item({ Id: 'c' }), item({ Id: 'd' })]
  const out = moveSelectedToBottom(items, new Set(['a', 'c']))
  assert.deepEqual(out.map(i => i.Id), ['b', 'd', 'a', 'c'])
})

test('moveSelectedToTop/Bottom: does not mutate the input array', () => {
  const items = [item({ Id: 'a' }), item({ Id: 'b' })]
  const copy = [...items]
  moveSelectedToTop(items, new Set(['b']))
  assert.deepEqual(items, copy)
})

test('moveSelectedToTop: selecting everything or nothing is a no-op order-wise', () => {
  const items = [item({ Id: 'a' }), item({ Id: 'b' }), item({ Id: 'c' })]
  assert.deepEqual(moveSelectedToTop(items, new Set()).map(i => i.Id), ['a', 'b', 'c'])
  assert.deepEqual(moveSelectedToTop(items, new Set(['a', 'b', 'c'])).map(i => i.Id), ['a', 'b', 'c'])
})
