// Syncing what happened offline: coalescing, the conflict rule and the play
// history catch-up (src/core/offline-sync.ts), plus the catalog's side of it
// (offline-index.ts). The fixture cases are shared with CascadeKit's
// OfflineSyncTests.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { coalesceChanges, updateToSend, playsCatchUp, playsOldestFirst, HISTORY_QUERY, type PendingUpdate } from '../src/core/offline-sync.ts'
import {
  emptyIndex, addCollection, addPlay, addChange, setHistory, refreshUserData, parseIndex, userDataIds, overStorageLimit,
  type UserDataChange, type HistorySnapshot, type OfflinePlay,
} from '../src/core/offline-index.ts'
import type { JfItem } from '../src/core/types.ts'

const fx = JSON.parse(readFileSync(new URL('../../shared/fixtures/offline-sync.json', import.meta.url), 'utf8')) as {
  coalesce: { name: string, changes: UserDataChange[], expected: PendingUpdate[] }[]
  decide: { name: string, update: PendingUpdate, server: JfItem | null, expected: object | null }[]
  catchUp: { name: string, history: HistorySnapshot | null, playsHeld: boolean, plays: OfflinePlay[], server: JfItem[], expected: string }[]
  replayOrder: { plays: OfflinePlay[], expected: string[] }
}

for (const c of fx.coalesce) test(`coalesce: ${c.name}`, () => assert.deepEqual(coalesceChanges(c.changes), c.expected))
for (const c of fx.decide) test(`conflict: ${c.name}`, () => assert.deepEqual(updateToSend(c.update, c.server), c.expected))
for (const c of fx.catchUp) test(`catch-up: ${c.name}`, () => assert.equal(playsCatchUp(c, c.server), c.expected))
test('plays replay oldest first, ties in queue order', () =>
  assert.deepEqual(playsOldestFirst(fx.replayOrder.plays).map(p => p.itemId), fx.replayOrder.expected))

test('the history query asks for the snapshot\'s 200 rows across every library', () => {
  assert.equal(HISTORY_QUERY.Limit, '200')
  assert.equal(HISTORY_QUERY.IncludeItemTypes, 'Audio,Movie,Episode')
  assert.ok(!('ParentId' in HISTORY_QUERY))
})

const ep = (id: string, ud: object = {}): JfItem => ({ Id: id, Name: id, Type: 'Episode', RunTimeTicks: 1000, UserData: ud } as unknown as JfItem)

test('a queued change shows in the catalog at once, and over a refresh until it is sent', () => {
  const index = emptyIndex()
  addCollection(index, ep('e1'), [ep('e1', { PlaybackPositionTicks: 0, Played: false })])
  addChange(index, { itemId: 'e1', userId: 'u1', at: '2026-10-16T10:00:00.000Z', kind: 'position', ticks: 500 })
  assert.equal(index.tracks.e1.item.UserData?.PlaybackPositionTicks, 500)
  assert.equal(index.collections[0].item.UserData?.PlaybackPositionTicks, 500, 'the collection\'s copy too')
  refreshUserData(index, [ep('e1', { PlaybackPositionTicks: 0, Played: false, IsFavorite: true })])
  assert.equal(index.tracks.e1.item.UserData?.PlaybackPositionTicks, 500)
  assert.equal(index.tracks.e1.item.UserData?.IsFavorite, true)
  index.changes = []
  refreshUserData(index, [ep('e1', { PlaybackPositionTicks: 0 })])
  assert.equal(index.tracks.e1.item.UserData?.PlaybackPositionTicks, 0)
  assert.deepEqual(userDataIds(index), ['e1'])
})

test('offline plays sit on top of the snapshot in the catalog', () => {
  const index = emptyIndex()
  const song = (id: string) => ({ Id: id, Name: id, Type: 'Audio' } as JfItem)
  addCollection(index, { Id: 'al', Name: 'al', Type: 'MusicAlbum' } as JfItem, [song('s1'), song('s2')])
  setHistory(index, [{ Id: 's1', UserData: { LastPlayedDate: '2026-10-15T20:00:00.0000000Z', PlayCount: 4 } } as unknown as JfItem], new Date())
  assert.deepEqual(index.tracks.s1.item.UserData, { Played: true, PlayCount: 4, LastPlayedDate: '2026-10-15T20:00:00.0000000Z' })
  addPlay(index, { itemId: 's2', userId: 'u1', date: '2026-10-16T09:00:00.000Z' })
  addPlay(index, { itemId: 's1', userId: 'u1', date: '2026-10-16T10:00:00.000Z' })
  assert.equal(index.tracks.s1.item.UserData?.PlayCount, 5)
  assert.equal(index.tracks.s1.item.UserData?.LastPlayedDate, '2026-10-16T10:00:00.000Z')
  // A snapshot taken again keeps the queued play counted.
  setHistory(index, [{ Id: 's1', UserData: { LastPlayedDate: '2026-10-15T20:00:00.0000000Z', PlayCount: 4 } } as unknown as JfItem], new Date())
  assert.equal(index.tracks.s1.item.UserData?.PlayCount, 5)
})

test('queued changes and the held flag survive a save, checked like the rest', () => {
  const index = emptyIndex()
  addCollection(index, ep('e1'), [ep('e1')])
  addPlay(index, { itemId: 'e1', userId: 'u1', date: '2026-10-16T09:00:00.000Z' })
  addChange(index, { itemId: 'e1', userId: 'u1', at: '2026-10-16T10:00:00.000Z', kind: 'favorite', favorite: true, was: false })
  index.playsHeld = true
  const raw = JSON.parse(JSON.stringify(index))
  raw.changes.push({ itemId: '../x', userId: 'u1', at: 'x', kind: 'position', ticks: 1 }, { itemId: 'e1', userId: 'u1', at: '2026-10-16T10:00:00Z', kind: 'nonsense' })
  const back = parseIndex(raw)
  assert.deepEqual(back.changes, index.changes)
  assert.equal(back.playsHeld, true)
  assert.equal(parseIndex({ ...raw, plays: [] }).playsHeld, false, 'nothing to hold')
  assert.deepEqual(parseIndex({ tracks: {} }).changes, [], 'an older file has none')
})

test('the storage limit', () => {
  assert.equal(overStorageLimit(9, 2, 10), true)
  assert.equal(overStorageLimit(8, 2, 10), false)
  assert.equal(overStorageLimit(1e12, 1e12, null), false)
})
