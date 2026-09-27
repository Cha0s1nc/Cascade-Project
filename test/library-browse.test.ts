import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  sortLibraryItems, filterLibraryItems, libraryFilterOptions,
  normalizeLibraryPrefs, groupByDay,
} from '../src/core/library-browse.ts'

const item = (over: any = {}) => ({ Id: 'x', Name: 'x', ...over })

test('sortLibraryItems: name falls back to SortName then Name', () => {
  const items = [item({ Id: '1', Name: 'The Beta' }), item({ Id: '2', Name: 'Alpha' })]
  const sorted = sortLibraryItems(items, 'name', 'asc')
  assert.deepEqual(sorted.map(i => i.Id), ['2', '1'])
})

test('sortLibraryItems: year, missing sorts as 0 (first ascending)', () => {
  const items = [item({ Id: '1', ProductionYear: 2020 }), item({ Id: '2' }), item({ Id: '3', ProductionYear: 1990 })]
  const sorted = sortLibraryItems(items, 'year', 'asc')
  assert.deepEqual(sorted.map(i => i.Id), ['2', '3', '1'])
})

test('sortLibraryItems: ties break on name regardless of direction', () => {
  const items = [
    item({ Id: '1', Name: 'Zeta', ProductionYear: 2000 }),
    item({ Id: '2', Name: 'Alpha', ProductionYear: 2000 }),
  ]
  assert.deepEqual(sortLibraryItems(items, 'year', 'asc').map(i => i.Id), ['2', '1'])
  assert.deepEqual(sortLibraryItems(items, 'year', 'desc').map(i => i.Id), ['2', '1'])
})

test('sortLibraryItems: random keeps the same items, does not mutate input', () => {
  const items = [item({ Id: '1' }), item({ Id: '2' }), item({ Id: '3' })]
  const before = items.map(i => i.Id)
  const shuffled = sortLibraryItems(items, 'random', 'asc')
  assert.deepEqual(items.map(i => i.Id), before)   // input untouched
  assert.deepEqual([...shuffled.map(i => i.Id)].sort(), ['1', '2', '3'])
})

test('filterLibraryItems: favorite, genre, decade, played all narrow independently', () => {
  const items = [
    item({ Id: '1', UserData: { IsFavorite: true, Played: true }, Genres: ['Jazz'], ProductionYear: 1994 }),
    item({ Id: '2', UserData: { IsFavorite: false, Played: false }, Genres: ['Rock'], ProductionYear: 2021 }),
  ]
  assert.deepEqual(filterLibraryItems(items, { favorite: true }).map(i => i.Id), ['1'])
  assert.deepEqual(filterLibraryItems(items, { genre: 'Rock' }).map(i => i.Id), ['2'])
  assert.deepEqual(filterLibraryItems(items, { decade: 1990 }).map(i => i.Id), ['1'])
  assert.deepEqual(filterLibraryItems(items, { played: 'unplayed' }).map(i => i.Id), ['2'])
  assert.deepEqual(filterLibraryItems(items, {}).map(i => i.Id), ['1', '2'])
})

test('filterLibraryItems: an item missing ProductionYear never matches a decade filter', () => {
  const items = [item({ Id: '1' })]
  assert.deepEqual(filterLibraryItems(items, { decade: 1990 }), [])
})

test('libraryFilterOptions: only genres/decades actually present, deduped and sorted', () => {
  const items = [
    item({ Genres: ['Rock', 'Jazz'], ProductionYear: 1994 }),
    item({ Genres: ['Jazz'], ProductionYear: 2021 }),
    item({}),
  ]
  const opts = libraryFilterOptions(items)
  assert.deepEqual(opts.genres, ['Jazz', 'Rock'])
  assert.deepEqual(opts.decades, [2020, 1990])
})

test('normalizeLibraryPrefs: corrupted store values fall back to defaults, never NaN/garbage', () => {
  assert.deepEqual(normalizeLibraryPrefs(null, ['name', 'year']),
    { field: 'name', dir: 'asc', favorite: false, genre: null, decade: null, played: null })
  assert.deepEqual(normalizeLibraryPrefs('not json', ['name', 'year']).field, 'name')
  assert.deepEqual(normalizeLibraryPrefs('{"field":"bogus"}', ['name', 'year']).field, 'name')
  assert.deepEqual(normalizeLibraryPrefs('{"dir":"sideways"}', ['name', 'year']).dir, 'asc')
  assert.deepEqual(normalizeLibraryPrefs('{"decade":"1990"}', ['name', 'year']).decade, null)
  assert.deepEqual(normalizeLibraryPrefs('{"decade":NaN}', ['name', 'year']).decade, null)
  assert.deepEqual(normalizeLibraryPrefs('[1,2,3]', ['name', 'year']).field, 'name')
})

test('normalizeLibraryPrefs: a valid, allowed value round-trips', () => {
  const p = normalizeLibraryPrefs('{"field":"year","dir":"desc","favorite":true,"genre":"Jazz","decade":1990,"played":"played"}', ['name', 'year'])
  assert.deepEqual(p, { field: 'year', dir: 'desc', favorite: true, genre: 'Jazz', decade: 1990, played: 'played' })
})

test('groupByDay: local calendar days, not UTC, using Today/Yesterday labels', () => {
  const now = new Date(2026, 8, 27, 10, 0)   // local Sep 27 2026, 10am - never a Z string
  const items = [
    item({ Id: '1', UserData: { LastPlayedDate: new Date(2026, 8, 27, 23, 0).toISOString() } }),
    item({ Id: '2', UserData: { LastPlayedDate: new Date(2026, 8, 27, 9, 0).toISOString() } }),
    item({ Id: '3', UserData: { LastPlayedDate: new Date(2026, 8, 26, 12, 0).toISOString() } }),
  ]
  const groups = groupByDay(items, now)
  assert.equal(groups.length, 2)
  assert.equal(groups[0].label, 'Today')
  assert.deepEqual(groups[0].items.map(i => i.Id), ['1', '2'])
  assert.equal(groups[1].label, 'Yesterday')
  assert.deepEqual(groups[1].items.map(i => i.Id), ['3'])
})

test('groupByDay: an item with no parseable play date is dropped, not crashed on', () => {
  const items = [item({ Id: '1', UserData: {} }), item({ Id: '2', UserData: { LastPlayedDate: 'garbage' } })]
  assert.deepEqual(groupByDay(items), [])
})
