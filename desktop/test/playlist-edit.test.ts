import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  entryIdOf, removeSelected, moveSelectedToTop, moveSelectedToBottom,
  sniffImageType, playlistDetailsRoute, bytesToBase64, createPlaylistWriteGate,
} from '../src/core/playlist-edit.ts'
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

test('createPlaylistWriteGate: writes to one playlist wait their turn', async () => {
  let clock = 1000
  const slept: number[] = []
  const wait = createPlaylistWriteGate(400, () => clock, async ms => { slept.push(ms) })
  await wait('a')
  await wait('a')
  await wait('a')
  // Two calls in the same instant reserve the next two slots, 400 ms apart.
  assert.deepEqual(slept, [400, 800])
  clock += 2000
  await wait('a')
  assert.deepEqual(slept, [400, 800], 'a write long after the last one does not wait')
})

test('createPlaylistWriteGate: other playlists do not wait', async () => {
  const slept: number[] = []
  const wait = createPlaylistWriteGate(400, () => 0, async ms => { slept.push(ms) })
  await wait('a')
  await wait('b')
  assert.deepEqual(slept, [])
})

test('sniffImageType: JPEG, PNG and WebP by their first bytes, nothing else', () => {
  assert.equal(sniffImageType(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0])), 'image/jpeg')
  assert.equal(sniffImageType(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0])), 'image/png')
  assert.equal(sniffImageType(new Uint8Array([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50])), 'image/webp')
  // A WAV is RIFF too, but not WEBP.
  assert.equal(sniffImageType(new Uint8Array([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x41, 0x56, 0x45])), null)
  assert.equal(sniffImageType(new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])), null) // GIF
  assert.equal(sniffImageType(new TextEncoder().encode('<svg xmlns=')), null)
  assert.equal(sniffImageType(new Uint8Array([0xff, 0xd8])), null) // too short
  assert.equal(sniffImageType(new Uint8Array(0)), null)
})

test('playlistDetailsRoute: the plugin when it offers it, else admins only', () => {
  const caps = new Set(['lyrics-read', 'playlist-edit'])
  assert.equal(playlistDetailsRoute(caps, true, false), 'plugin')
  assert.equal(playlistDetailsRoute(caps, true, true), 'plugin')
  assert.equal(playlistDetailsRoute(new Set(['lyrics-read']), true, false), null)
  assert.equal(playlistDetailsRoute(new Set(['lyrics-read']), true, true), 'admin')
  // A stale capability set from a server that has since lost the plugin.
  assert.equal(playlistDetailsRoute(caps, false, false), null)
  assert.equal(playlistDetailsRoute(caps, false, true), 'admin')
})

test('bytesToBase64: matches Buffer, including past one chunk', () => {
  const big = new Uint8Array(0x8000 * 2 + 17).map((_, i) => (i * 31) & 0xff)
  for (const bytes of [new Uint8Array(0), new Uint8Array([1, 2, 3]), big]) {
    assert.equal(bytesToBase64(bytes), Buffer.from(bytes).toString('base64'))
  }
})
