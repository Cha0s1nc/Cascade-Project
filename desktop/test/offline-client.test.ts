// The swap point: JellyfinClient with an offline source answers from the
// catalog and sends nothing (docs/offline-mode-plan.md, section 2).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { JellyfinClient, OfflineError, JellyfinHttpError } from '../src/core/jellyfin.ts'
import { offlineQuery } from '../src/core/offline-query.ts'
import { parseIndex } from '../src/core/offline-index.ts'

const fixture = JSON.parse(readFileSync(new URL('../../shared/fixtures/offline-query.json', import.meta.url), 'utf8'))
const engine = offlineQuery(parseIndex(fixture.catalog))
const config = { url: 'https://jf.example', token: 't', userId: 'user1', libraryIds: ['libmusic'] }

function offlineClient(): { client: JellyfinClient, sent: string[] } {
  const sent: string[] = []
  globalThis.fetch = (async (url: unknown) => { sent.push(String(url)); throw new TypeError('fetch failed') }) as typeof fetch
  const client = new JellyfinClient(() => config)
  client.setOfflineSource((path, params) => engine.answer(path, params))
  return { client, sent }
}

const ids = (r: { Items?: { Id: string }[] }) => (r.Items ?? []).map(i => i.Id)

test('reads come from the catalog and nothing is sent', async () => {
  const { client, sent } = offlineClient()
  assert.equal(client.offline, true)
  const albums = await client.get<{ Items: { Id: string }[] }>('/Items', { IncludeItemTypes: 'MusicAlbum', SortBy: 'SortName' })
  assert.deepEqual(ids(albums), ['alb1', 'alb2', 'alb3'])
  assert.deepEqual(sent, [])
})

test('a chosen library list also covers the placeholder libraries', async () => {
  const { client, sent } = offlineClient()
  // libmusic is chosen; alb3 is in the placeholder and still shows.
  const merged = await client.getMerged('/Items', { IncludeItemTypes: 'MusicAlbum', SortBy: 'SortName' })
  assert.deepEqual(ids(merged).sort(), ['alb1', 'alb3'])
  const paged = await client.getAllPaged('/Items', { IncludeItemTypes: 'MusicAlbum', Limit: 1 })
  assert.deepEqual(ids(paged).sort(), ['alb1', 'alb3'])
  assert.deepEqual(sent, [])
})

test('grouped lists leave out libraries with nothing downloaded', async () => {
  const { client } = offlineClient()
  const groups = await client.getAllGrouped('/Items', { IncludeItemTypes: 'Movie' }, ['libfilms', 'libmusic'])
  assert.deepEqual(groups.map(g => g.libraryId), ['libfilms'])
  assert.deepEqual(groups[0].items.map(i => i.Id).sort(), ['mov1', 'mov2'])
})

test('an id that is not downloaded is a 404, with its status', async () => {
  const { client } = offlineClient()
  await assert.rejects(client.get('/Items/nothere'), (e: unknown) => e instanceof JellyfinHttpError && e.status === 404)
})

test('writes are refused without a request', async () => {
  const { client, sent } = offlineClient()
  await assert.rejects(client.post('/Sessions/Playing', {}), (e: unknown) => e instanceof OfflineError)
  assert.equal(await client.del('/Videos/ActiveEncodings'), false)
  assert.deepEqual(sent, [])
})

test('online again, requests go out, and failures are reported', async () => {
  const { client, sent } = offlineClient()
  client.setOfflineSource(null)
  const seen: (number | null)[] = []
  client.onFailure = s => seen.push(s)
  await assert.rejects(client.get('/Items'))
  assert.equal(sent.length, 1)
  globalThis.fetch = (async () => new Response('nope', { status: 503, statusText: 'Service Unavailable' })) as typeof fetch
  await assert.rejects(client.get('/Items'), (e: unknown) => e instanceof JellyfinHttpError && e.status === 503)
  assert.deepEqual(seen, [null, 503])
})
