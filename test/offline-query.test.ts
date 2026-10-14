// The offline query engine against the shared cases in
// test/fixtures/offline-query.json, which CascadeKit's OfflineQueryTests runs
// too, plus the desktop-only details.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { answerOffline, placeholderLibraryIds } from '../src/core/offline-query.ts'
import { parseIndex, PLACEHOLDER_LIBRARIES } from '../src/core/offline-index.ts'

interface Case {
  name: string
  path: string
  params: Record<string, unknown>
  status?: number
  ids?: string[]
  total?: number
  body?: unknown
  unknownRoute?: boolean
}

const fixture = JSON.parse(readFileSync(new URL('./fixtures/offline-query.json', import.meta.url), 'utf8'))
const catalog = parseIndex(fixture.catalog)

/** Every key of `expected` matches in `actual`; arrays match element by
 *  element and must be the same length. */
function partial(actual: unknown, expected: unknown, at: string): void {
  if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), `${at} is not an array`)
    assert.equal(actual.length, expected.length, `${at} length`)
    expected.forEach((e, i) => partial(actual[i], e, `${at}[${i}]`))
  } else if (expected && typeof expected === 'object') {
    assert.ok(actual && typeof actual === 'object', `${at} is not an object`)
    for (const [k, v] of Object.entries(expected)) partial((actual as Record<string, unknown>)[k], v, `${at}.${k}`)
  } else {
    assert.equal(actual, expected, at)
  }
}

test('the catalog fixture reads back whole', () => {
  assert.equal(Object.keys(catalog.tracks).length, Object.keys(fixture.catalog.tracks).length)
  assert.equal(catalog.collections.length, fixture.catalog.collections.length)
})

for (const c of fixture.cases as Case[]) {
  test(`shared case: ${c.name}`, () => {
    const answer = answerOffline(catalog, c.path, c.params, () => 0)
    assert.equal(answer.status, c.status ?? 200)
    assert.equal(answer.unknownRoute === true, c.unknownRoute === true, 'unknownRoute')
    const body = answer.body as { Items?: { Id: string }[], TotalRecordCount?: number } | { Id: string }[]
    if (c.ids) {
      const items = Array.isArray(body) ? body : body.Items ?? []
      assert.deepEqual(items.map(i => i.Id), c.ids)
    }
    if (c.total !== undefined) assert.equal((body as { TotalRecordCount?: number }).TotalRecordCount, c.total)
    if (c.body !== undefined) partial(answer.body, c.body, 'body')
  })
}

test('SortBy=Random shuffles with the given source and keeps every item', () => {
  const ask = (r: () => number) => (answerOffline(catalog, '/Items', { IncludeItemTypes: 'Audio', SortBy: 'Random' }, r).body as { Items: { Id: string }[] }).Items.map(i => i.Id)
  const sorted = ask(() => 0).slice().sort()
  assert.deepEqual(ask(() => 0.999).slice().sort(), sorted)
  assert.notDeepEqual(ask(() => 0), ask(() => 0.999))
})

test('a query string on the path is read like params', () => {
  const a = answerOffline(catalog, '/Items?IncludeItemTypes=Playlist').body as { Items: { Id: string }[] }
  assert.deepEqual(a.Items.map(i => i.Id), ['pls1'])
})

test('an empty catalog answers empty lists, not errors', () => {
  const empty = parseIndex(null)
  for (const path of ['/Items', '/Artists', '/MusicGenres', '/UserViews', '/Shows/NextUp']) {
    const a = answerOffline(empty, path)
    assert.equal(a.status, 200, path)
    assert.deepEqual((a.body as { Items: unknown[] }).Items, [], path)
  }
  assert.equal(answerOffline(empty, '/Users/me').status, 404)
})

test('the placeholder ids are the catalog\'s', () => {
  assert.deepEqual(placeholderLibraryIds(), Object.values(PLACEHOLDER_LIBRARIES).map(l => l.Id))
})
