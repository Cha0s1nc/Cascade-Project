import { test, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { JellyfinClient, authenticate, authHeader } from '../src/core/jellyfin.ts'
import type { ServerConfig, JfItemsResponse } from '../src/core/types.ts'

const realFetch = globalThis.fetch
let calls: { url: string, init?: RequestInit }[] = []

/** Replace fetch with a scripted responder. `handler` returns the JSON body,
 *  or throws to simulate a failing request. */
function stubFetch(handler: (url: string) => unknown) {
  globalThis.fetch = (async (input: any, init?: RequestInit) => {
    const url = String(input)
    calls.push({ url, init })
    const body = handler(url)
    if (body === undefined) {
      return { ok: false, status: 404, statusText: 'Not Found', json: async () => ({}), text: async () => '' }
    }
    return { ok: true, status: 200, statusText: 'OK', json: async () => body, text: async () => JSON.stringify(body) }
  }) as typeof fetch
}

beforeEach(() => { calls = [] })
afterEach(() => { globalThis.fetch = realFetch })

const baseConfig: ServerConfig = { url: 'https://jf.test', token: 'TOK', userId: 'U1' }
const clientFor = (cfg: ServerConfig) => new JellyfinClient(() => cfg)

const items = (...ids: string[]) => ({ Items: ids.map(Id => ({ Id })), TotalRecordCount: ids.length })

test('get: builds the URL, sends the token, and stringifies params', async () => {
  stubFetch(() => items('a'))
  await clientFor(baseConfig).get('/Items', { Limit: 5, Recursive: true })

  const url = new URL(calls[0].url)
  assert.equal(url.origin + url.pathname, 'https://jf.test/Items')
  assert.equal(url.searchParams.get('Limit'), '5')
  assert.equal(url.searchParams.get('Recursive'), 'true')
  assert.equal((calls[0].init?.headers as Record<string, string>)['X-Emby-Token'], 'TOK')
})

test('get: omits undefined params rather than sending "undefined"', async () => {
  stubFetch(() => items('a'))
  await clientFor(baseConfig).get('/Items', { SortBy: undefined, Limit: 1 })

  const url = new URL(calls[0].url)
  assert.equal(url.searchParams.has('SortBy'), false)
  assert.equal(url.searchParams.get('Limit'), '1')
})

test('get: throws on a non-ok response', async () => {
  stubFetch(() => undefined)
  await assert.rejects(() => clientFor(baseConfig).get('/Items'), /404 Not Found/)
})

test('client reads config lazily, so reconnecting is picked up', async () => {
  // The renderer replaces its `jf` object wholesale on connect. A client that
  // captured the object would keep using the old token.
  let cfg: ServerConfig = { ...baseConfig }
  const client = new JellyfinClient(() => cfg)

  stubFetch(() => items('a'))
  await client.get('/Items')
  assert.equal((calls[0].init?.headers as Record<string, string>)['X-Emby-Token'], 'TOK')

  cfg = { url: 'https://other.test', token: 'NEW', userId: 'U2' }
  await client.get('/Items')
  assert.equal((calls[1].init?.headers as Record<string, string>)['X-Emby-Token'], 'NEW')
  assert.ok(calls[1].url.startsWith('https://other.test'))
})

test('getMerged: with no libraries selected it is a plain get', async () => {
  stubFetch(() => items('a', 'b'))
  const res = await clientFor(baseConfig).getMerged('/Items')

  assert.equal(calls.length, 1)
  assert.equal(new URL(calls[0].url).searchParams.has('ParentId'), false)
  assert.deepEqual(res.Items?.map(i => i.Id), ['a', 'b'])
})

test('getMerged: queries each library and dedupes by Id', async () => {
  const cfg = { ...baseConfig, libraryIds: ['L1', 'L2'] }
  stubFetch(url => new URL(url).searchParams.get('ParentId') === 'L1'
    ? items('a', 'shared')
    : items('shared', 'b'))

  const res = await clientFor(cfg).getMerged('/Items')
  assert.equal(calls.length, 2)
  assert.deepEqual(res.Items?.map(i => i.Id), ['a', 'shared', 'b'], 'first occurrence wins')
  assert.equal(res.TotalRecordCount, 3)
})

test('getMerged: one failing library does not sink the others', async () => {
  const cfg = { ...baseConfig, libraryIds: ['L1', 'BAD'] }
  stubFetch(url => new URL(url).searchParams.get('ParentId') === 'BAD' ? undefined : items('a'))

  const res = await clientFor(cfg).getMerged('/Items')
  assert.deepEqual(res.Items?.map(i => i.Id), ['a'])
})

test('getAllPaged: keeps paging past the first page', async () => {
  // 5 total, page size 2 -> StartIndex 0, then 2 and 4 in parallel.
  stubFetch(url => {
    const start = Number(new URL(url).searchParams.get('StartIndex'))
    const all = ['a', 'b', 'c', 'd', 'e']
    const page = all.slice(start, start + 2)
    return { Items: page.map(Id => ({ Id })), TotalRecordCount: 5 } satisfies JfItemsResponse
  })

  const res = await clientFor(baseConfig).getAllPaged('/Items', { Limit: 2 })
  assert.equal(calls.length, 3)
  assert.deepEqual(res.Items?.map(i => i.Id), ['a', 'b', 'c', 'd', 'e'])
})

test('getAllPaged: stops when the first page is everything', async () => {
  stubFetch(() => items('a', 'b'))
  const res = await clientFor(baseConfig).getAllPaged('/Items', { Limit: 500 })
  assert.equal(calls.length, 1, 'no extra page requests')
  assert.equal(res.TotalRecordCount, 2)
})

test('artUrl: no tag means no art', () => {
  const c = clientFor(baseConfig)
  assert.equal(c.artUrl('X', undefined), null)
  assert.equal(c.artUrl('X', null), null)
  assert.ok(c.artUrl('X', 'tag')?.includes('/Items/X/Images/Primary'))
  // Artists have no tag guard - they always render something.
  assert.ok(c.artistArtUrl('Y').includes('/Items/Y/Images/Primary'))
})

test('authenticate: posts credentials and returns the auth result', async () => {
  stubFetch(() => ({ AccessToken: 'T', User: { Id: 'U9' } }))
  const res = await authenticate('https://jf.test', 'user', 'pw', '1.2.0', 'DEV-ABC')

  assert.equal(res.AccessToken, 'T')
  assert.equal(res.User.Id, 'U9')
  assert.equal(calls[0].init?.method, 'POST')
  assert.deepEqual(JSON.parse(String(calls[0].init?.body)), { Username: 'user', Pw: 'pw' })
  const auth = (calls[0].init?.headers as Record<string, string>)['X-Emby-Authorization']
  assert.ok(auth.includes('Version="1.2.0"'))
  assert.ok(auth.includes('DeviceId="DEV-ABC"'))
})

test('authHeader: device id is per-install, never the old constant', () => {
  // "cascade-app" was hardcoded, so every Cascade looked like one device to
  // Jellyfin - remote control could not target a specific client, and two
  // instances collided in the session list.
  const header = authHeader('1.2.0', 'DEV-XYZ')
  assert.ok(header.includes('DeviceId="DEV-XYZ"'))
  assert.ok(!header.includes('cascade-app'))
})
