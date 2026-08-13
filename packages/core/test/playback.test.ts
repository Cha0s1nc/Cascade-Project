import { test, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { JellyfinClient } from '../src/core/jellyfin.ts'
import { resolveStream, universalStreamUrl, stopActiveEncoding, DEFAULT_MAX_BITRATE, resumeTicks } from '../src/core/playback.ts'
import { ELECTRON_PROFILE, buildElectronProfile } from '../src/core/profiles/electron.ts'
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

// ── Offset streams and track selection ──
//
// The whole reason these exist: a progressive transcode only exposes the part
// the server has already encoded, so seeking is a new stream rather than a
// currentTime assignment. If startTicks ever stops reaching the URL, scrubbing
// a film silently goes back to being impossible.

const TEN_MIN = 6_000_000_000

const transcodeReply = () => ({
  PlaySessionId: 'PS1',
  MediaSources: [{ Id: 'MS1', Container: 'mkv', TranscodingUrl: '/videos/ITEM1/master.mp4?PlaySessionId=PS1' }],
})

test('a transcode seek puts StartTimeTicks on the stream URL', async () => {
  stubFetch(() => transcodeReply())
  const out = await resolveStream(
    client, config, 'ITEM1', ELECTRON_PROFILE, DEFAULT_MAX_BITRATE, 'Video',
    { startTicks: TEN_MIN })

  assert.equal(out.direct, false)
  assert.equal(out.startTicks, TEN_MIN, 'caller needs the offset back to correct its clock')
  const url = new URL(out.url)
  assert.equal(url.searchParams.get('StartTimeTicks'), String(TEN_MIN))
  // The params the server put on TranscodingUrl must survive being added to.
  assert.equal(url.searchParams.get('PlaySessionId'), 'PS1')
})

test('an offset of zero leaves the transcoding URL untouched', async () => {
  stubFetch(() => transcodeReply())
  const out = await resolveStream(
    client, config, 'ITEM1', ELECTRON_PROFILE, DEFAULT_MAX_BITRATE, 'Video', { startTicks: 0 })

  assert.equal(out.startTicks, 0)
  assert.ok(!out.url.includes('StartTimeTicks'))
})

test('seeking twice replaces the offset rather than appending a second one', async () => {
  stubFetch(() => ({
    PlaySessionId: 'PS1',
    MediaSources: [{ Id: 'MS1', TranscodingUrl: '/videos/ITEM1/master.mp4?StartTimeTicks=999' }],
  }))
  const out = await resolveStream(
    client, config, 'ITEM1', ELECTRON_PROFILE, DEFAULT_MAX_BITRATE, 'Video',
    { startTicks: TEN_MIN })

  const url = new URL(out.url)
  assert.deepEqual(url.searchParams.getAll('StartTimeTicks'), [String(TEN_MIN)])
})

test('direct play reports no offset, because it seeks on the element instead', async () => {
  stubFetch(() => ({ PlaySessionId: 'PS1', MediaSources: [{ Id: 'MS1', Container: 'mp4' }] }))
  const out = await resolveStream(
    client, config, 'ITEM1', ELECTRON_PROFILE, DEFAULT_MAX_BITRATE, 'Video',
    { startTicks: TEN_MIN })

  assert.equal(out.direct, true)
  assert.equal(out.startTicks, 0, 'a whole file needs no offset baked into the URL')
  assert.ok(!out.url.includes('StartTimeTicks'))
})

test('a chosen audio track reaches PlaybackInfo, and is absent otherwise', async () => {
  stubFetch(() => transcodeReply())
  await resolveStream(client, config, 'ITEM1', ELECTRON_PROFILE, DEFAULT_MAX_BITRATE, 'Video',
    { audioStreamIndex: 3 })
  assert.equal(calls[0].body.AudioStreamIndex, 3)

  calls = []
  await resolveStream(client, config, 'ITEM1', ELECTRON_PROFILE, DEFAULT_MAX_BITRATE, 'Video')
  assert.ok(!('AudioStreamIndex' in calls[0].body),
    'omitted rather than null, so the server keeps its own default')
})

test('the fallback path still reports a usable shape when PlaybackInfo fails', async () => {
  stubFetch(() => undefined)
  const out = await resolveStream(
    client, config, 'ITEM1', ELECTRON_PROFILE, DEFAULT_MAX_BITRATE, 'Video',
    { startTicks: TEN_MIN })

  assert.equal(out.direct, false)
  assert.equal(out.startTicks, 0, 'the static fallback cannot start partway in')
  assert.ok(out.url.includes('/Videos/ITEM1/stream'))
})

// ── Runtime codec detection ──
//
// PLATFORM-NOTES.md: a guessed profile is worse than no profile, because the
// server believes it. These check that a claim only ever appears when the probe
// actually said yes.

test('the baseline profile claims nothing conditional, but does claim mkv', () => {
  const videos = ELECTRON_PROFILE.DirectPlayProfiles.filter(p => p.Type === 'Video')
  const containers = videos.map(v => v.Container).join(',')
  // Verified against a real file, not against canPlayType - which returns ''
  // for Matroska even though Chromium's bundled FFmpeg demuxes it. Dropping
  // mkv made every ripped file a server-side remux, and a remux cannot be
  // seeked. See the comment in electron.ts.
  assert.ok(containers.includes('mkv'), 'Chromium plays mkv despite the MIME probe')
  assert.ok(containers.includes('webm'))
  for (const v of videos) {
    assert.ok(!v.VideoCodec!.includes('hevc'), 'nothing conditional in the floor')
    assert.ok(!v.AudioCodec!.includes('ac3'))
  }
})

test('a host that decodes nothing extra gets exactly the baseline', () => {
  const built = buildElectronProfile(() => false)
  assert.deepEqual(built.DirectPlayProfiles, ELECTRON_PROFILE.DirectPlayProfiles)
})

test('HEVC is claimed only when the probe says so, under either spelling', () => {
  for (const probe of [(t: string) => t.includes('hev1'), (t: string) => t.includes('hvc1')]) {
    const mp4 = buildElectronProfile(probe).DirectPlayProfiles
      .find(x => x.Type === 'Video' && x.Container.includes('mp4'))!
    assert.ok(mp4.VideoCodec!.includes('hevc'), 'either spelling is enough')
    assert.ok(mp4.VideoCodec!.includes('h264'), 'and it is added, not substituted')
  }
})

test('HEVC is never claimed for mkv, whatever the probe says', () => {
  // The probe asks about mp4 and its answer is only about mp4. Chromium
  // decodes HEVC in ISO-BMFF but not in Matroska, and the failure is silent:
  // readyState stays 0 forever with no error event. Measured on a real file.
  const mkv = buildElectronProfile(() => true).DirectPlayProfiles
    .find(x => x.Type === 'Video' && x.Container === 'mkv')!
  assert.ok(!mkv.VideoCodec!.includes('hevc'))
  assert.ok(mkv.VideoCodec!.includes('h264'), 'mkv still direct-plays what it can')
})

test('AC3 and E-AC3 are claimed independently of each other', () => {
  const ac3Only = buildElectronProfile(t => t.includes('ac-3') && !t.includes('ec-3'))
  const video = ac3Only.DirectPlayProfiles.find(x => x.Type === 'Video')!
  assert.ok(video.AudioCodec!.split(',').includes('ac3'))
  assert.ok(!video.AudioCodec!.split(',').includes('eac3'),
    'a build with AC3 does not necessarily have E-AC3')
})

test('a fully capable host produces a clean codec list', () => {
  const all = buildElectronProfile(() => true)
  const video = all.DirectPlayProfiles.find(x => x.Type === 'Video')!
  for (const list of [video.VideoCodec!, video.AudioCodec!]) {
    assert.ok(!list.includes(',,') && !list.startsWith(',') && !list.endsWith(','),
      `no stray commas from an unsupported codec: ${list}`)
  }
  assert.ok(video.VideoCodec!.includes('hevc'))
  assert.ok(video.AudioCodec!.includes('ac3') && video.AudioCodec!.includes('eac3'))
})

test('a HEVC-capable host lets the server hand HEVC back, so it can copy', () => {
  // The transcoding profile is what the server may *return*. Offering only
  // h264 forces a full re-encode of a video that needed nothing done to it;
  // allowing hevc lets the same request come back as a remux.
  const all = buildElectronProfile(() => true)
  const video = all.TranscodingProfiles.find(p => p.Type === 'Video')!
  assert.ok(video.VideoCodec!.includes('hevc'))
  assert.ok(video.VideoCodec!.includes('h264'), 'h264 stays for everything else')

  const audio = all.TranscodingProfiles.find(p => p.Type === 'Audio')!
  assert.deepEqual(audio, ELECTRON_PROFILE.TranscodingProfiles[0], 'music path untouched')
  assert.deepEqual(all.SubtitleProfiles, ELECTRON_PROFILE.SubtitleProfiles)
})

test('a host without HEVC gets neither the codec profile nor the hevc fallback', () => {
  const none = buildElectronProfile(() => false)
  assert.deepEqual(none.TranscodingProfiles, ELECTRON_PROFILE.TranscodingProfiles)
  assert.deepEqual(none.CodecProfiles, [], 'nothing to describe')
})

test('the HEVC codec profile permits 10-bit, and does not hard-fail outside it', () => {
  // Empty CodecProfiles does not read as "no restrictions" - the server assumes
  // 10-bit is beyond the client and re-encodes. Nearly every HEVC file is Main
  // 10, so this condition is the whole difference between copy and encode.
  const p = buildElectronProfile(() => true).CodecProfiles!
  assert.equal(p.length, 1)
  assert.equal(p[0].Codec, 'hevc')
  const depth = p[0].Conditions.find(c => c.Property === 'VideoBitDepth')!
  assert.equal(depth.Value, '10')
  assert.equal(depth.Condition, 'LessThanEqual')
  // Required conditions make the server refuse the file outright; these should
  // only steer it toward copying, never block playback.
  assert.ok(p[0].Conditions.every(c => c.IsRequired === false))
})

// ── Releasing the encoder ──
//
// Abandoning a transcode without telling the server leaves ffmpeg encoding a
// file nobody is watching, at full speed when throttling is off. A few scrubs
// becomes a few encoders fighting over the same cores, which presents as
// "transcoding got slow" and is entirely self-inflicted.

test('stopActiveEncoding names the device and the session it is releasing', async () => {
  stubFetch(() => ({}))
  const cfg: ServerConfig = { ...config, deviceId: 'DEV1' }
  await stopActiveEncoding(new JellyfinClient(() => cfg), cfg, 'PS9')

  assert.equal(calls.length, 1)
  const u = new URL(calls[0].url)
  assert.equal(u.pathname, '/Videos/ActiveEncodings')
  assert.equal(u.searchParams.get('deviceId'), 'DEV1')
  assert.equal(u.searchParams.get('playSessionId'), 'PS9')
})

test('stopActiveEncoding stays quiet when there is nothing to release', async () => {
  stubFetch(() => ({}))
  const cfg: ServerConfig = { ...config, deviceId: 'DEV1' }
  await stopActiveEncoding(new JellyfinClient(() => cfg), cfg, null)
  // No deviceId means the server cannot match a session anyway.
  await stopActiveEncoding(new JellyfinClient(() => config), config, 'PS9')
  assert.equal(calls.length, 0, 'no request worth making')
})

test('stopActiveEncoding never throws, whatever the server does', async () => {
  const cfg: ServerConfig = { ...config, deviceId: 'DEV1' }
  stubFetch(() => undefined)          // 500
  await stopActiveEncoding(new JellyfinClient(() => cfg), cfg, 'PS9')

  globalThis.fetch = (async () => { throw new Error('network down') }) as typeof fetch
  await stopActiveEncoding(new JellyfinClient(() => cfg), cfg, 'PS9')
  // Reaching here is the assertion: cleanup must not take playback down with it.
  assert.ok(true)
})
