import { test, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { JellyfinClient } from '../src/core/jellyfin.ts'
import { resolveStream, universalStreamUrl, DEFAULT_MAX_BITRATE, resumeTicks } from '../src/core/playback.ts'
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
const resolveVideo = () =>
  resolveStream(client, config, 'ITEM1', ELECTRON_PROFILE, DEFAULT_MAX_BITRATE, 'Video')

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

// ── Video ────────────────────────────────────────────────────────────────────

test('video direct play uses /Videos, not /Audio', async () => {
  stubFetch(() => ({ PlaySessionId: 'PS1', MediaSources: [{ Id: 'MS1', Container: 'mkv' }] }))
  const out = await resolveVideo()

  const url = new URL(out.url)
  assert.equal(url.pathname, '/Videos/ITEM1/stream.mkv')
  assert.equal(url.searchParams.get('static'), 'true')
  assert.equal(url.searchParams.get('mediaSourceId'), 'MS1')
})

test('audio is still the default kind', async () => {
  stubFetch(() => ({ MediaSources: [{ Id: 'MS1', Container: 'flac' }] }))
  const out = await resolve()
  assert.ok(new URL(out.url).pathname.startsWith('/Audio/'))
})

test('video falls back to a static stream, never /universal', async () => {
  // /Audio/{id}/universal has no video counterpart - asking for it would 404
  // and the fallback would be worse than useless.
  stubFetch(() => undefined)   // 500
  const out = await resolveVideo()

  assert.ok(!out.url.includes('/universal'))
  assert.equal(new URL(out.url).pathname, '/Videos/ITEM1/stream')
  assert.equal(new URL(out.url).searchParams.get('static'), 'true')
  assert.equal(out.playSessionId, null)
})

test('video transcode uses the server URL like audio does', async () => {
  stubFetch(() => ({
    PlaySessionId: 'PS3',
    MediaSources: [{ Id: 'MS3', Container: 'mkv', TranscodingUrl: '/Videos/ITEM1/stream.mp4?foo=1' }],
  }))
  const out = await resolveVideo()

  assert.equal(out.direct, false)
  assert.equal(out.url, 'https://jf.test/Videos/ITEM1/stream.mp4?foo=1')
})

test('video transcoding profile is progressive http, not hls', () => {
  // Chromium cannot play an .m3u8 and this app ships no HLS player. If someone
  // flips this to 'hls' to match the audio profile, video silently stops
  // playing whenever the server decides to transcode - which is most of the
  // time. Add hls.js in the same change or leave this alone.
  const video = ELECTRON_PROFILE.TranscodingProfiles.find(p => p.Type === 'Video')
  assert.ok(video, 'video transcoding profile must exist')
  assert.equal(video.Protocol, 'http')
  assert.equal(video.Container, 'mp4')
  assert.equal(video.VideoCodec, 'h264')
})

test('video direct play profile omits codecs Chromium cannot decode', () => {
  // Claiming these gets a direct-play URL and a black screen, which is worse
  // than letting the server transcode.
  const video = ELECTRON_PROFILE.DirectPlayProfiles.find(p => p.Type === 'Video')
  assert.ok(video)
  for (const codec of ['hevc', 'h265', 'mpeg2video', 'vc1']) {
    assert.ok(!video.VideoCodec?.includes(codec), `must not claim ${codec}`)
  }
  for (const codec of ['ac3', 'eac3', 'dts', 'truehd']) {
    assert.ok(!video.AudioCodec?.includes(codec), `must not claim ${codec}`)
  }
})

// ── Resume ───────────────────────────────────────────────────────────────────

const HOUR = 36_000_000_000   // ticks

test('resumeTicks returns a stored mid-item position', () => {
  assert.equal(
    resumeTicks({ Id: 'X', RunTimeTicks: 2 * HOUR, UserData: { PlaybackPositionTicks: HOUR } }),
    HOUR)
})

test('resumeTicks ignores an item already marked played', () => {
  // Jellyfin keeps a position after you finish something. Honouring it would
  // drop the user back into the last minute of a film they already watched.
  assert.equal(
    resumeTicks({ Id: 'X', RunTimeTicks: 2 * HOUR, UserData: { PlaybackPositionTicks: HOUR, Played: true } }),
    0)
})

test('resumeTicks treats the last 5% as finished', () => {
  const total = 2 * HOUR
  assert.equal(resumeTicks({ Id: 'X', RunTimeTicks: total, UserData: { PlaybackPositionTicks: total * 0.96 } }), 0)
  // Just inside the threshold still resumes.
  const near = total * 0.94
  assert.equal(resumeTicks({ Id: 'X', RunTimeTicks: total, UserData: { PlaybackPositionTicks: near } }), near)
})

test('resumeTicks is 0 for anything unwatched, missing or malformed', () => {
  assert.equal(resumeTicks(null), 0)
  assert.equal(resumeTicks(undefined), 0)
  assert.equal(resumeTicks({ Id: 'X' }), 0)
  assert.equal(resumeTicks({ Id: 'X', UserData: {} }), 0)
  assert.equal(resumeTicks({ Id: 'X', UserData: { PlaybackPositionTicks: 0 } }), 0)
})

test('resumeTicks honours a position when the runtime is unknown', () => {
  // No RunTimeTicks means the completion check cannot run - resuming is still
  // better than silently restarting.
  assert.equal(resumeTicks({ Id: 'X', UserData: { PlaybackPositionTicks: HOUR } }), HOUR)
})

test('subtitle profile offers text formats externally and no image formats', () => {
  const formats = (ELECTRON_PROFILE.SubtitleProfiles ?? []).map(p => p.Format)
  assert.ok(formats.includes('vtt'))
  assert.ok(formats.includes('subrip'))
  // PGS/VOBSUB are bitmaps; a <track> cannot draw them, so the server has to
  // burn them in. Listing them here would produce subtitles that never appear.
  assert.ok(!formats.includes('pgssub'))
  assert.ok(!formats.includes('dvdsub'))
  assert.ok((ELECTRON_PROFILE.SubtitleProfiles ?? []).every(p => p.Method === 'External'))
})
