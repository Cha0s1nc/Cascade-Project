import { test, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import {
  JellyfinClient, authenticate, authHeader,
  quickConnectEnabled, quickConnectInitiate, quickConnectApproved, quickConnectAuthenticate,
  QUICK_CONNECT_POLL_MS, QUICK_CONNECT_TIMEOUT_MS, readErrorMessage,
  splitVideoLibraryIds, effectiveLibraryIds,
} from '../src/core/jellyfin.ts'
import type { ServerConfig, JfItemsResponse, JfItem } from '../src/core/types.ts'

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

/** Minimal fake Response for testing readErrorMessage directly, without going
 *  through fetch. */
function fakeResponse(opts: { status?: number, statusText?: string, contentType?: string, body?: string }): Response {
  return {
    status: opts.status ?? 500,
    statusText: opts.statusText ?? 'Server Error',
    headers: { get: (name: string) => name.toLowerCase() === 'content-type' ? (opts.contentType ?? null) : null },
    text: async () => opts.body ?? '',
  } as unknown as Response
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

test('getGrouped: returns one group per library, in the order given', async () => {
  const cfg = { ...baseConfig, libraryIds: ['L1', 'L2'] }
  stubFetch(url => new URL(url).searchParams.get('ParentId') === 'L1'
    ? items('a', 'shared')
    : items('shared', 'b'))

  const groups = await clientFor(cfg).getGrouped('/Items')
  assert.deepEqual(groups.map(g => g.libraryId), ['L1', 'L2'])
  assert.deepEqual(groups[0].items.map(i => i.Id), ['a', 'shared'])
  assert.deepEqual(groups[1].items.map(i => i.Id), ['shared', 'b'])
})

test('getGrouped: a failing library yields an empty group, not a rejection', async () => {
  const cfg = { ...baseConfig, libraryIds: ['L1', 'BAD'] }
  stubFetch(url => new URL(url).searchParams.get('ParentId') === 'BAD' ? undefined : items('a'))

  const groups = await clientFor(cfg).getGrouped('/Items')
  assert.deepEqual(groups.map(g => g.libraryId), ['L1', 'BAD'])
  assert.deepEqual(groups[0].items.map(i => i.Id), ['a'])
  assert.deepEqual(groups[1].items, [])
})

test('getGrouped: with no libraries selected it is a plain get, wrapped as one group', async () => {
  stubFetch(() => items('a', 'b'))
  const groups = await clientFor(baseConfig).getGrouped('/Items')

  assert.equal(calls.length, 1)
  assert.equal(groups.length, 1)
  assert.deepEqual(groups[0].items.map(i => i.Id), ['a', 'b'])
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

test('quickConnectEnabled: true only when the server says so', async () => {
  stubFetch(() => true)
  assert.equal(await quickConnectEnabled('https://jf.test'), true)
  assert.ok(calls[0].url.endsWith('/QuickConnect/Enabled'))
})

test('quickConnectEnabled: never throws on a server without it', async () => {
  // A server that 404s this simply does not offer QuickConnect - that is not an
  // error the sign-in screen should surface.
  stubFetch(() => undefined)
  assert.equal(await quickConnectEnabled('https://jf.test'), false)

  globalThis.fetch = (() => Promise.reject(new Error('offline'))) as unknown as typeof fetch
  assert.equal(await quickConnectEnabled('https://jf.test'), false)
})

test('quickConnectInitiate: binds the request to this device', async () => {
  stubFetch(() => ({ Code: '123456', Secret: 'SEKRIT' }))
  const start = await quickConnectInitiate('https://jf.test', '1.2.0', 'DEV-1')

  assert.deepEqual(start, { Code: '123456', Secret: 'SEKRIT' })
  assert.equal(calls[0].init?.method, 'POST')
  const auth = (calls[0].init?.headers as Record<string, string>)['X-Emby-Authorization']
  assert.ok(auth.includes('DeviceId="DEV-1"'), 'token ends up bound to this device id')
})

test('quickConnectApproved: false until the user approves', async () => {
  stubFetch(() => ({ Authenticated: false }))
  assert.equal(await quickConnectApproved('https://jf.test', 'SEKRIT'), false)

  stubFetch(() => ({ Authenticated: true }))
  assert.equal(await quickConnectApproved('https://jf.test', 'SEKRIT'), true)
})

test('quickConnectApproved: an expired request reads as pending, not a crash', async () => {
  // Jellyfin 404s a request it has forgotten. Throwing here would kill the poll
  // loop; the caller's timeout is what should end it.
  stubFetch(() => undefined)
  assert.equal(await quickConnectApproved('https://jf.test', 'GONE'), false)
})

test('quickConnectApproved: escapes the secret into the query', async () => {
  stubFetch(() => ({ Authenticated: false }))
  await quickConnectApproved('https://jf.test', 'a b&c=d')
  assert.equal(new URL(calls[0].url).searchParams.get('secret'), 'a b&c=d')
})

test('quickConnectAuthenticate: trades the secret for a real token', async () => {
  stubFetch(() => ({ AccessToken: 'TOK', User: { Id: 'U9' } }))
  const auth = await quickConnectAuthenticate('https://jf.test', 'SEKRIT', '1.2.0', 'DEV-1')

  assert.equal(auth.AccessToken, 'TOK')
  assert.equal(auth.User.Id, 'U9')
  assert.deepEqual(JSON.parse(String(calls[0].init?.body)), { Secret: 'SEKRIT' })
  const hdr = (calls[0].init?.headers as Record<string, string>)['X-Emby-Authorization']
  assert.ok(hdr.includes('DeviceId="DEV-1"'), 'must match the device that initiated')
})

test('quickConnectAuthenticate: surfaces a rejection', async () => {
  stubFetch(() => undefined)
  await assert.rejects(() => quickConnectAuthenticate('https://jf.test', 'BAD', '1.2.0', 'DEV-1'))
})

test('quick connect timings are sane', () => {
  assert.ok(QUICK_CONNECT_POLL_MS >= 1000, 'do not hammer the server')
  assert.ok(QUICK_CONNECT_TIMEOUT_MS > QUICK_CONNECT_POLL_MS * 10, 'room for a real approval')
})

test('authHeader: device id is per-install, never the old constant', () => {
  // "cascade-app" was hardcoded, so every Cascade looked like one device to
  // Jellyfin - remote control could not target a specific client, and two
  // instances collided in the session list.
  const header = authHeader('1.2.0', 'DEV-XYZ')
  assert.ok(header.includes('DeviceId="DEV-XYZ"'))
  assert.ok(!header.includes('cascade-app'))
})

// A dead Jellyfin server behind a reverse proxy (Cloudflare, nginx, etc)
// answers with a whole HTML error page instead of Jellyfin's own short JSON/
// text body. Naively turning that page into `error.message` and rendering it
// dumps kilobytes of markup onto the screen. readErrorMessage is the one place
// that tames a failed response before it becomes an Error.
test('readErrorMessage: an HTML error page becomes the status line, not a wall of markup', async () => {
  const res = fakeResponse({
    status: 502, statusText: 'Bad Gateway', contentType: 'text/html; charset=utf-8',
    body: `<html><head><title>502 Bad Gateway</title></head><body>${'cloudflare says no. '.repeat(200)}</body></html>`,
  })
  assert.equal(await readErrorMessage(res), '502 Bad Gateway')
})

test('readErrorMessage: a body starting with "<" is treated as HTML even with no content-type header', async () => {
  const res = fakeResponse({ status: 503, statusText: 'Service Unavailable', body: '<html>whatever</html>' })
  assert.equal(await readErrorMessage(res), '503 Service Unavailable')
})

test('readErrorMessage: a huge non-HTML body is truncated to a single readable line', async () => {
  const huge = 'server exploded '.repeat(500)
  const res = fakeResponse({ status: 500, statusText: 'Internal Server Error', contentType: 'text/plain', body: huge })
  const msg = await readErrorMessage(res)
  assert.ok(msg.length < huge.length, 'must not dump the whole body')
  assert.ok(msg.endsWith('…'), 'truncation must be visible, not silent')
})

test('readErrorMessage: a short Jellyfin error body survives intact and readable', async () => {
  const res = fakeResponse({ status: 400, statusText: 'Bad Request', contentType: 'text/plain', body: 'Invalid username or password.' })
  assert.equal(await readErrorMessage(res), 'Invalid username or password.')
})

test('readErrorMessage: an empty body falls back to the status line', async () => {
  const res = fakeResponse({ status: 401, statusText: 'Unauthorized', body: '' })
  assert.equal(await readErrorMessage(res), '401 Unauthorized')
})

test('readErrorMessage: collapses a multi-line body into one line', async () => {
  const res = fakeResponse({ status: 400, statusText: 'Bad Request', contentType: 'text/plain', body: 'Line one\n  Line two\t\tLine three' })
  assert.equal(await readErrorMessage(res), 'Line one Line two Line three')
})

test('authenticate: a failed request is routed through readErrorMessage end to end', async () => {
  // Confirms the call site actually uses the helper, not just that the helper
  // works in isolation.
  globalThis.fetch = (async () => ({
    ok: false, status: 502, statusText: 'Bad Gateway',
    headers: { get: () => 'text/html' },
    text: async () => '<html><body>cloudflare says no</body></html>',
    json: async () => ({}),
  })) as unknown as typeof fetch

  await assert.rejects(
    () => authenticate('https://jf.test', 'user', 'pw', '1.2.0', 'DEV-1'),
    (e: Error) => { assert.equal(e.message, '502 Bad Gateway'); return true },
  )
})

const videoLib = (Id: string, CollectionType: string): JfItem => ({ Id, CollectionType })

test('splitVideoLibraryIds: sorts a mixed flat list into movies and TV by CollectionType', () => {
  const libs = [videoLib('m1', 'movies'), videoLib('m2', 'movies'), videoLib('t1', 'tvshows')]
  const { movieIds, showIds } = splitVideoLibraryIds(libs, ['m1', 't1', 'm2'])
  assert.deepEqual(movieIds, ['m1', 'm2'])
  assert.deepEqual(showIds, ['t1'])
})

test('splitVideoLibraryIds: an id no longer on the server is dropped, not guessed at', () => {
  const libs = [videoLib('m1', 'movies')]
  const { movieIds, showIds } = splitVideoLibraryIds(libs, ['m1', 'gone'])
  assert.deepEqual(movieIds, ['m1'])
  assert.deepEqual(showIds, [])
})

test('effectiveLibraryIds: a sole library defaults on when nothing was ever chosen', () => {
  const libs = [{ Id: 'm1', Name: 'Movies' }] as any
  assert.deepEqual(effectiveLibraryIds(libs, null), ['m1'])
  assert.deepEqual(effectiveLibraryIds(libs, undefined), ['m1'])
})

test('effectiveLibraryIds: a sole library can be turned off and stay off', () => {
  // The bug: it used to be forced on whatever was saved, so anyone with exactly
  // one movie or TV library could never disable video at all.
  const libs = [{ Id: 'm1', Name: 'Movies' }] as any
  assert.deepEqual(effectiveLibraryIds(libs, []), [])
  assert.deepEqual(effectiveLibraryIds(libs, ['m1']), ['m1'])
  assert.deepEqual(effectiveLibraryIds(libs, ['something-else']), [])
})

test('effectiveLibraryIds: never-chosen with a real choice still selects nothing', () => {
  const libs = [{ Id: 'm1', Name: 'A' }, { Id: 'm2', Name: 'B' }] as any
  assert.deepEqual(effectiveLibraryIds(libs, null), [])
})

test('effectiveLibraryIds: with a real choice, saved ids win but vanished ones are dropped', () => {
  const libs = [videoLib('m1', 'movies'), videoLib('m2', 'movies'), videoLib('m3', 'movies')]
  assert.deepEqual(effectiveLibraryIds(libs, ['m1', 'm3']), ['m1', 'm3'])
  assert.deepEqual(effectiveLibraryIds(libs, ['m1', 'gone']), ['m1'])
})

test('effectiveLibraryIds: no libraries in the category means no ids, regardless of saved state', () => {
  assert.deepEqual(effectiveLibraryIds([], ['m1']), [])
})
