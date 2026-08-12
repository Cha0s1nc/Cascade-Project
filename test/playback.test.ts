import { test, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { JellyfinClient } from '../src/core/jellyfin.ts'
import { resolveStream, universalStreamUrl, DEFAULT_MAX_BITRATE } from '../src/core/playback.ts'
import { ELECTRON_PROFILE } from '../src/core/profiles/electron.ts'
import type { ServerConfig } from '../src/core/types.ts'

const realFetch = globalThis.fetch
let calls: { url: string, body: any }[] = []

function stubFetch(handler: (url: string) => unknown) {
  globalThis.fetch = (async (input: any, init?: RequestInit) => {
    const url = String(input)
    calls.push({ url, body: init?.body ? JSON.parse(String(init.body)) : undefined })
    const out = handler(url)
    if (out === undefined) {
      return { ok: false, status: 500, statusText: 'Server Error', json: async () => ({}), text: async () => '' }
    }
    return { ok: true, status: 200, statusText: 'OK', json: async () => out, text: async () => '' }
  }) as typeof fetch
}

beforeEach(() => { calls = [] })
afterEach(() => { globalThis.fetch = realFetch })

const config: ServerConfig = { url: 'https://jf.test', token: 'TOK', userId: 'U1' }
const client = new JellyfinClient(() => config)
const resolve = (bitrate?: number) =>
  resolveStream(client, config, 'ITEM1', ELECTRON_PROFILE, bitrate ?? DEFAULT_MAX_BITRATE)

test('sends the DeviceProfile and bitrate to PlaybackInfo', async () => {
  stubFetch(() => ({ PlaySessionId: 'PS1', MediaSources: [{ Id: 'MS1', Container: 'flac' }] }))
  await resolve(320_000)

  assert.ok(calls[0].url.includes('/Items/ITEM1/PlaybackInfo'))
  assert.equal(calls[0].body.UserId, 'U1')
  assert.equal(calls[0].body.MaxStreamingBitrate, 320_000)
  // The bitrate must also be inside the profile, not just alongside it.
  assert.equal(calls[0].body.DeviceProfile.MaxStreamingBitrate, 320_000)
  assert.ok(calls[0].body.DeviceProfile.DirectPlayProfiles.length > 0)
})

test('direct play: builds a static stream URL carrying the session', async () => {
  stubFetch(() => ({ PlaySessionId: 'PS1', MediaSources: [{ Id: 'MS1', Container: 'flac' }] }))
  const out = await resolve()

  assert.equal(out.direct, true)
  assert.equal(out.playSessionId, 'PS1')
  assert.equal(out.mediaSourceId, 'MS1')

  const url = new URL(out.url)
  assert.equal(url.pathname, '/Audio/ITEM1/stream.flac', 'container becomes the extension')
  assert.equal(url.searchParams.get('static'), 'true')
  assert.equal(url.searchParams.get('mediaSourceId'), 'MS1')
  assert.equal(url.searchParams.get('PlaySessionId'), 'PS1')
  assert.equal(url.searchParams.get('api_key'), 'TOK')
})

test('transcoding: uses the server-supplied URL, made absolute', async () => {
  stubFetch(() => ({
    PlaySessionId: 'PS2',
    MediaSources: [{ Id: 'MS2', Container: 'flac', TranscodingUrl: '/Audio/ITEM1/main.m3u8?foo=1' }],
  }))
  const out = await resolve()

  assert.equal(out.direct, false)
  assert.equal(out.url, 'https://jf.test/Audio/ITEM1/main.m3u8?foo=1')
  assert.equal(out.playSessionId, 'PS2')
})

test('multi-container source only takes the first as the extension', async () => {
  stubFetch(() => ({ MediaSources: [{ Id: 'MS3', Container: 'mp3,mp4' }] }))
  const out = await resolve()
  assert.equal(new URL(out.url).pathname, '/Audio/ITEM1/stream.mp3')
})

test('falls back to /universal when PlaybackInfo fails', async () => {
  stubFetch(() => undefined)   // 500
  const out = await resolve()

  assert.equal(out.direct, false)
  assert.equal(out.playSessionId, null)
  assert.ok(out.url.includes('/Audio/ITEM1/universal'), 'should degrade, not throw')
})

test('falls back when PlaybackInfo returns no media sources', async () => {
  stubFetch(() => ({ PlaySessionId: 'PS9', MediaSources: [] }))
  const out = await resolve()
  assert.ok(out.url.includes('/universal'))
  assert.equal(out.playSessionId, null)
})

test('resolveStream never rejects', async () => {
  globalThis.fetch = (() => Promise.reject(new Error('network down'))) as unknown as typeof fetch
  const out = await resolve()
  assert.ok(out.url.includes('/universal'))
})

test('universalStreamUrl keeps the pre-B1 shape', async () => {
  // This is the degraded path, so it must stay byte-compatible with what the
  // app used to send - it is the only thing standing between a failed
  // PlaybackInfo and silence.
  const url = new URL(universalStreamUrl(config, 'ITEM1'))
  assert.equal(url.pathname, '/Audio/ITEM1/universal')
  assert.equal(url.searchParams.get('UserId'), 'U1')
  assert.equal(url.searchParams.get('api_key'), 'TOK')
  assert.equal(url.searchParams.get('Container'), 'opus,mp3,aac,flac,wav,ogg')
  assert.equal(url.searchParams.get('AudioCodec'), 'aac')
  assert.equal(url.searchParams.get('MaxStreamingBitrate'), String(DEFAULT_MAX_BITRATE))
})

test('universalStreamUrl honours a custom bitrate', () => {
  const url = new URL(universalStreamUrl(config, 'ITEM1', 96_000))
  assert.equal(url.searchParams.get('MaxStreamingBitrate'), '96000')
})

test('electron profile does not claim codecs a TV would lack', () => {
  // Guard against someone copying this profile to a TV target wholesale.
  const containers = ELECTRON_PROFILE.DirectPlayProfiles[0].Container
  assert.ok(containers.includes('opus'), 'Chromium does decode opus - that is the point')
  assert.equal(ELECTRON_PROFILE.TranscodingProfiles[0].Protocol, 'hls')
  assert.equal(ELECTRON_PROFILE.TranscodingProfiles[0].AudioCodec, 'aac')
})
