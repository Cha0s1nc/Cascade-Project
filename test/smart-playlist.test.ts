import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  parseSmartPlaylists, serializeSmartPlaylists, toItemsQuery, ruleMatches, matchesRules,
  applySmartPlaylistRules,
} from '../src/core/smart-playlist.ts'
import type { SmartPlaylistDef, SmartPlaylistRule } from '../src/core/smart-playlist.ts'
import type { JfItem } from '../src/core/types.ts'

const item = (over: Partial<JfItem> & { Id: string }): JfItem => over
const NOW = Date.parse('2026-09-27T00:00:00Z')

const baseDef = (over: Partial<SmartPlaylistDef> = {}): SmartPlaylistDef => ({
  id: 'user:1', name: 'Test', match: 'all', rules: [], sortBy: 'name', sortDir: 'asc', limit: 100, ...over,
})

// ── parseSmartPlaylists: untrusted storage ──────────────────────────────────

test('parseSmartPlaylists: empty/missing input is an empty list, not a crash', () => {
  assert.deepEqual(parseSmartPlaylists(undefined), [])
  assert.deepEqual(parseSmartPlaylists(null), [])
  assert.deepEqual(parseSmartPlaylists(''), [])
})

test('parseSmartPlaylists: malformed JSON is dropped entirely', () => {
  assert.deepEqual(parseSmartPlaylists('{not json'), [])
})

test('parseSmartPlaylists: a JSON value that is not an array is dropped', () => {
  assert.deepEqual(parseSmartPlaylists('{"id":"user:1"}'), [])
})

test('parseSmartPlaylists: a def missing name or id is dropped, valid ones kept', () => {
  const raw = JSON.stringify([
    { id: 'user:1', name: 'Good', rules: [] },
    { id: 'user:2', rules: [] },          // no name
    { name: 'No id', rules: [] },          // no id
  ])
  const out = parseSmartPlaylists(raw)
  assert.deepEqual(out.map(d => d.id), ['user:1'])
})

test('parseSmartPlaylists: unknown rule fields/ops are dropped, valid rules kept', () => {
  const raw = JSON.stringify([{
    id: 'user:1', name: 'Mix', rules: [
      { field: 'genre', op: 'is', value: 'Rock' },
      { field: 'genre', op: 'contains', value: 'Rock' },  // unknown op
      { field: 'telepathy', op: 'is', value: true },       // unknown field
      { field: 'favorite', op: 'is', value: 'yes' },        // wrong value type
    ],
  }])
  const out = parseSmartPlaylists(raw)
  assert.equal(out.length, 1)
  assert.deepEqual(out[0].rules, [{ field: 'genre', op: 'is', value: 'Rock' }])
})

test('parseSmartPlaylists: garbage limit/match/sort fall back to safe defaults, never NaN', () => {
  const raw = JSON.stringify([{
    id: 'user:1', name: 'Garbage', match: 'xyz', sortBy: 'xyz', sortDir: 'xyz',
    limit: 'a lot please', rules: [],
  }])
  const out = parseSmartPlaylists(raw)
  assert.equal(out[0].match, 'all')
  assert.equal(out[0].sortBy, 'name')
  assert.equal(out[0].sortDir, 'asc')
  assert.equal(out[0].limit, 100)
  assert.equal(Number.isFinite(out[0].limit), true)
})

test('parseSmartPlaylists: limit is clamped to the allowed range', () => {
  const raw = JSON.stringify([
    { id: 'user:1', name: 'Huge', limit: 999999, rules: [] },
    { id: 'user:2', name: 'Negative', limit: -5, rules: [] },
  ])
  const out = parseSmartPlaylists(raw)
  assert.equal(out[0].limit, 500)
  assert.equal(out[1].limit, 1)   // clamped to the floor, not rejected outright
})

test('parseSmartPlaylists: year rule min/max are clamped and ordered', () => {
  const raw = JSON.stringify([{
    id: 'user:1', name: 'Years', rules: [{ field: 'year', op: 'between', min: 3000, max: 1 }],
  }])
  const rule = parseSmartPlaylists(raw)[0].rules[0] as Extract<SmartPlaylistRule, { field: 'year' }>
  assert.equal(rule.min <= rule.max, true)
  assert.equal(rule.max <= 2100, true)
})

test('serializeSmartPlaylists round-trips through parseSmartPlaylists', () => {
  const defs = [baseDef({ rules: [{ field: 'favorite', op: 'is', value: true }] })]
  const out = parseSmartPlaylists(serializeSmartPlaylists(defs))
  assert.deepEqual(out, defs)
})

// ── toItemsQuery: prefilter only, must stay a superset ──────────────────────

test('toItemsQuery: ANY match pushes nothing, since params AND together server-side', () => {
  const def = baseDef({ match: 'any', rules: [{ field: 'genre', op: 'is', value: 'Rock' }] })
  assert.deepEqual(toItemsQuery(def), {})
})

test('toItemsQuery: ALL match translates favorite/played/genre/artist', () => {
  const def = baseDef({
    rules: [
      { field: 'genre', op: 'is', value: 'Rock' },
      { field: 'artist', op: 'is', value: 'Aurora Vale' },
      { field: 'played', op: 'is', value: true },
      { field: 'favorite', op: 'is', value: true },
    ],
  })
  assert.deepEqual(toItemsQuery(def), { Genres: 'Rock', Artists: 'Aurora Vale', IsPlayed: true, IsFavorite: true })
})

test('toItemsQuery: a second genre-is rule in ALL match is not merged in (would turn AND into OR)', () => {
  const def = baseDef({
    rules: [
      { field: 'genre', op: 'is', value: 'Rock' },
      { field: 'genre', op: 'is', value: 'Jazz' },
    ],
  })
  assert.deepEqual(toItemsQuery(def), { Genres: 'Rock' })
})

test('toItemsQuery: genre isNot, addedWithinDays and playCount have no server param, stay client-side only', () => {
  const def = baseDef({
    rules: [
      { field: 'genre', op: 'isNot', value: 'Jazz' },
      { field: 'addedWithinDays', op: 'lte', days: 7 },
      { field: 'playCount', op: 'gte', value: 3 },
    ],
  })
  assert.deepEqual(toItemsQuery(def), {})
})

test('toItemsQuery: a narrow year range becomes an explicit Years list', () => {
  const def = baseDef({ rules: [{ field: 'year', op: 'between', min: 1980, max: 1982 }] })
  assert.deepEqual(toItemsQuery(def), { Years: '1980,1981,1982' })
})

test('toItemsQuery: a very wide year range is left unpushed rather than building a huge query', () => {
  const def = baseDef({ rules: [{ field: 'year', op: 'between', min: 1000, max: 2100 }] })
  assert.deepEqual(toItemsQuery(def), {})
})

test('toItemsQuery invariant: filtering its own query result by the rules gives the same answer as filtering everything', () => {
  const library: JfItem[] = [
    item({ Id: '1', Genres: ['Rock'], UserData: { IsFavorite: true } }),
    item({ Id: '2', Genres: ['Rock'], UserData: { IsFavorite: false } }),
    item({ Id: '3', Genres: ['Jazz'], UserData: { IsFavorite: true } }),
  ]
  const def = baseDef({ rules: [
    { field: 'genre', op: 'is', value: 'Rock' },
    { field: 'favorite', op: 'is', value: true },
  ] })
  const query = toItemsQuery(def)
  // Simulate the server applying the query (Genres ORs, IsFavorite equals).
  const serverFiltered = library.filter(i =>
    (query.Genres === undefined || (i.Genres || []).includes(String(query.Genres))) &&
    (query.IsFavorite === undefined || !!i.UserData?.IsFavorite === query.IsFavorite))
  const viaQueryThenRules = serverFiltered.filter(i => matchesRules(i, def, NOW))
  const viaRulesDirectly = library.filter(i => matchesRules(i, def, NOW))
  assert.deepEqual(viaQueryThenRules.map(i => i.Id), viaRulesDirectly.map(i => i.Id))
  assert.deepEqual(viaRulesDirectly.map(i => i.Id), ['1'])
})

// ── ruleMatches ──────────────────────────────────────────────────────────────

test('ruleMatches: genre is/isNot, case-insensitive', () => {
  const track = item({ Id: '1', Genres: ['rock', 'Blues'] })
  assert.equal(ruleMatches(track, { field: 'genre', op: 'is', value: 'Rock' }, NOW), true)
  assert.equal(ruleMatches(track, { field: 'genre', op: 'isNot', value: 'Rock' }, NOW), false)
  assert.equal(ruleMatches(track, { field: 'genre', op: 'is', value: 'Jazz' }, NOW), false)
  assert.equal(ruleMatches(track, { field: 'genre', op: 'isNot', value: 'Jazz' }, NOW), true)
})

test('ruleMatches: artist matches either the Artists list or AlbumArtist', () => {
  const track = item({ Id: '1', Artists: ['Feature Guy'], AlbumArtist: 'Aurora Vale' })
  assert.equal(ruleMatches(track, { field: 'artist', op: 'is', value: 'Aurora Vale' }, NOW), true)
  assert.equal(ruleMatches(track, { field: 'artist', op: 'is', value: 'Feature Guy' }, NOW), true)
  assert.equal(ruleMatches(track, { field: 'artist', op: 'is', value: 'Nobody' }, NOW), false)
})

test('ruleMatches: year between is inclusive, missing year never matches', () => {
  assert.equal(ruleMatches(item({ Id: '1', ProductionYear: 1985 }), { field: 'year', op: 'between', min: 1980, max: 1989 }, NOW), true)
  assert.equal(ruleMatches(item({ Id: '1', ProductionYear: 1990 }), { field: 'year', op: 'between', min: 1980, max: 1989 }, NOW), false)
  assert.equal(ruleMatches(item({ Id: '1' }), { field: 'year', op: 'between', min: 1980, max: 1989 }, NOW), false)
})

test('ruleMatches: addedWithinDays uses the passed-in clock, and rejects a bad date rather than crashing', () => {
  const rule: SmartPlaylistRule = { field: 'addedWithinDays', op: 'lte', days: 7 }
  const recent = item({ Id: '1', DateCreated: new Date(NOW - 3 * 24 * 60 * 60 * 1000).toISOString() })
  const old = item({ Id: '2', DateCreated: new Date(NOW - 30 * 24 * 60 * 60 * 1000).toISOString() })
  const bad = item({ Id: '3', DateCreated: 'not-a-date' })
  const missing = item({ Id: '4' })
  assert.equal(ruleMatches(recent, rule, NOW), true)
  assert.equal(ruleMatches(old, rule, NOW), false)
  assert.equal(ruleMatches(bad, rule, NOW), false)
  assert.equal(ruleMatches(missing, rule, NOW), false)
})

test('ruleMatches: played is/never played, missing UserData reads as never played', () => {
  assert.equal(ruleMatches(item({ Id: '1', UserData: { Played: true } }), { field: 'played', op: 'is', value: true }, NOW), true)
  assert.equal(ruleMatches(item({ Id: '2' }), { field: 'played', op: 'is', value: false }, NOW), true)
  assert.equal(ruleMatches(item({ Id: '2' }), { field: 'played', op: 'is', value: true }, NOW), false)
})

test('ruleMatches: playCount at least N, missing PlayCount reads as zero', () => {
  assert.equal(ruleMatches(item({ Id: '1', UserData: { PlayCount: 5 } }), { field: 'playCount', op: 'gte', value: 3 }, NOW), true)
  assert.equal(ruleMatches(item({ Id: '2' }), { field: 'playCount', op: 'gte', value: 1 }, NOW), false)
})

test('ruleMatches: favorite is true/false', () => {
  assert.equal(ruleMatches(item({ Id: '1', UserData: { IsFavorite: true } }), { field: 'favorite', op: 'is', value: true }, NOW), true)
  assert.equal(ruleMatches(item({ Id: '2' }), { field: 'favorite', op: 'is', value: false }, NOW), true)
})

// ── matchesRules: all vs any ─────────────────────────────────────────────────

test('matchesRules: no rules matches everything', () => {
  assert.equal(matchesRules(item({ Id: '1' }), { match: 'all', rules: [] }, NOW), true)
})

test('matchesRules: ALL requires every rule, ANY requires at least one', () => {
  const rules: SmartPlaylistRule[] = [
    { field: 'genre', op: 'is', value: 'Rock' },
    { field: 'favorite', op: 'is', value: true },
  ]
  const bothMatch = item({ Id: '1', Genres: ['Rock'], UserData: { IsFavorite: true } })
  const onlyGenre = item({ Id: '2', Genres: ['Rock'], UserData: { IsFavorite: false } })
  assert.equal(matchesRules(bothMatch, { match: 'all', rules }, NOW), true)
  assert.equal(matchesRules(onlyGenre, { match: 'all', rules }, NOW), false)
  assert.equal(matchesRules(onlyGenre, { match: 'any', rules }, NOW), true)
})

// ── applySmartPlaylistRules: filter + sort + limit ──────────────────────────

test('applySmartPlaylistRules: filters, sorts by name ascending, and limits', () => {
  const items = [
    item({ Id: 'b', Name: 'Banana', Genres: ['Rock'] }),
    item({ Id: 'a', Name: 'Apple', Genres: ['Rock'] }),
    item({ Id: 'c', Name: 'Carrot', Genres: ['Jazz'] }),
  ]
  const def = baseDef({ rules: [{ field: 'genre', op: 'is', value: 'Rock' }], limit: 1 })
  const out = applySmartPlaylistRules(items, def, NOW)
  assert.deepEqual(out.map(i => i.Id), ['a'])
})

test('applySmartPlaylistRules: sortDir desc reverses the order', () => {
  const items = [
    item({ Id: 'a', Name: 'Apple' }),
    item({ Id: 'b', Name: 'Banana' }),
  ]
  const def = baseDef({ sortDir: 'desc' })
  assert.deepEqual(applySmartPlaylistRules(items, def, NOW).map(i => i.Id), ['b', 'a'])
})

test('applySmartPlaylistRules: sortBy playCount, and it does not mutate the input array', () => {
  const items = [
    item({ Id: 'a', UserData: { PlayCount: 1 } }),
    item({ Id: 'b', UserData: { PlayCount: 9 } }),
  ]
  const def = baseDef({ sortBy: 'playCount', sortDir: 'desc' })
  const out = applySmartPlaylistRules(items, def, NOW)
  assert.deepEqual(out.map(i => i.Id), ['b', 'a'])
  assert.equal(items[0].Id, 'a')   // original order untouched
})
