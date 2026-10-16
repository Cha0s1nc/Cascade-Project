// Video downloads: the profile, the outcome, the size estimate and the
// truncation check (src/core/offline-video.ts), plus the catalog's follow and
// remove-watched rules (offline-index.ts). The outcome cases are shared with
// CascadeKit's OfflineVideoTests.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  downloadProfile, downloadOutcome, estimatedBytes, fragmentedEndSeconds, isWholeTranscode, parseVideoQuality,
  secondsLeft, downloadPlaybackInfoBody, DOWNLOAD_MAX_BITRATE, isWatchedPosition, type DownloadSource,
} from '../src/core/offline-video.ts'
import { buildElectronProfile, ELECTRON_PROFILE } from '../src/core/profiles/electron.ts'
import {
  emptyIndex, addCollection, markReady, markWatched, setFollow, newEpisodes, addToCollection, watchedToRemove,
  removeTracks, parseIndex, collectionOf, REMOVE_WATCHED_AFTER_MS, judgeDownload, contentTypeForFile,
  placementGroups, libraryFromAncestors, setLibraries, unplacedTrackIds,
} from '../src/core/offline-index.ts'
import type { JfItem } from '../src/core/types.ts'

const fixture = JSON.parse(readFileSync(new URL('./fixtures/offline-video.json', import.meta.url), 'utf8')) as {
  cases: { name: string, runTimeTicks: number, source: DownloadSource, outcome: string }[]
}
const fmp4 = readFileSync(new URL('./fixtures/offline-fragmented.mp4', import.meta.url))
const reader = (buf: Uint8Array) => (offset: number, length: number) => buf.subarray(offset, offset + length)

for (const c of fixture.cases) {
  test(`outcome: ${c.name}`, () => assert.equal(downloadOutcome(c.source), c.outcome))
}

test('the download profile keeps direct play, adds one progressive MP4 and no bitrate cap', () => {
  const p = downloadProfile(buildElectronProfile(() => true), 'original', { audioCodecs: 'aac', maxAudioChannels: '2' })
  assert.equal(p.MaxStreamingBitrate, DOWNLOAD_MAX_BITRATE)
  assert.ok(p.DirectPlayProfiles.every(d => d.Type === 'Video'))
  assert.ok(p.DirectPlayProfiles.some(d => d.Container === 'mkv'), 'the desktop plays an original MKV')
  assert.deepEqual(p.TranscodingProfiles, [{
    Type: 'Video', Container: 'mp4', VideoCodec: 'h264,hevc', AudioCodec: 'aac', Protocol: 'http', Context: 'Streaming', MaxAudioChannels: '2',
  }])
  // The HEVC Main 10 profile comes along, or 10-bit HEVC re-encodes.
  assert.ok(p.CodecProfiles?.some(c => c.Codec === 'hevc'))
  assert.ok(!p.CodecProfiles?.some(c => c.Conditions.some(x => x.Property === 'Height')))
  assert.ok(p.SubtitleProfiles?.some(s => s.Format === 'subrip' && s.Method === 'External'))
  assert.ok(p.SubtitleProfiles?.some(s => s.Format === 'pgssub' && s.Method === 'Encode'))
})

test('HEVC is only asked for where the device decodes it', () => {
  const p = downloadProfile(ELECTRON_PROFILE, 'original', { audioCodecs: 'aac', maxAudioChannels: '2' })
  assert.equal(p.TranscodingProfiles[0].VideoCodec, 'h264')
})

test('a quality below original is a height condition on every codec', () => {
  for (const [q, h] of [['1080p', '1080'], ['720p', '720']] as const) {
    const cap = downloadProfile(ELECTRON_PROFILE, q, { audioCodecs: 'aac', maxAudioChannels: '2' }).CodecProfiles?.at(-1)
    assert.equal(cap?.Codec, undefined)
    assert.deepEqual(cap?.Conditions, [{ Condition: 'LessThanEqual', Property: 'Height', Value: h, IsRequired: true }])
  }
})

test('a stored quality reads back, anything else is the platform default', () => {
  assert.equal(parseVideoQuality('720p'), '720p')
  assert.equal(parseVideoQuality('4k'), 'original')
  assert.equal(parseVideoQuality(undefined, '1080p'), '1080p')
})

test('a burned-in subtitle goes into the request, none otherwise', () => {
  const p = downloadProfile(ELECTRON_PROFILE, 'original', { audioCodecs: 'aac', maxAudioChannels: '2' })
  assert.equal(downloadPlaybackInfoBody('u', p, 4).SubtitleStreamIndex, 4)
  assert.ok(!('SubtitleStreamIndex' in downloadPlaybackInfoBody('u', p, null)))
})

test('the size estimate: the source size, or the requested bitrates over the runtime', () => {
  const remux = fixture.cases.find(c => c.name === 'hevc-mkv-apple')!
  assert.equal(estimatedBytes('remux', remux.source, remux.runTimeTicks), remux.source.Size)
  const cap = fixture.cases.find(c => c.name === 'cap720-of-1080')!
  // VideoBitrate 5775999 + AudioBitrate 224001 = 6 Mbps, 750 kB/s, for 4875 s.
  assert.equal(estimatedBytes('reencode', cap.source, cap.runTimeTicks), 3_656_250_000)
  assert.equal(estimatedBytes('reencode', { TranscodingUrl: '/videos/x/stream.mp4' }, 1), null)
  assert.equal(secondsLeft(500, 1000, 100), 5)
  assert.equal(secondsLeft(500, null, 100), null)
})

test('the end of a fragmented MP4 is its last fragment, from headers only', () => {
  const end = fragmentedEndSeconds(reader(fmp4), fmp4.length)
  assert.ok(end !== null && Math.abs(end - 3.0) < 0.05, `got ${end}`)
  assert.equal(isWholeTranscode(end, 30_000_000), true)
})

test('a transcode cut off partway reads short, and is not whole', () => {
  // Cut inside the last mdat: the last whole fragment ends near 2 s.
  const cut = fmp4.subarray(0, 13_000)
  const end = fragmentedEndSeconds(reader(cut), cut.length)
  assert.ok(end !== null && end < 2.5, `got ${end}`)
  assert.equal(isWholeTranscode(end, 10 * 60 * 10_000_000), false, 'a 10 minute item that ends at 2 s')
  // Cut before the first fragment: nothing to play.
  const bare = fmp4.subarray(0, 3_800)
  assert.equal(fragmentedEndSeconds(reader(bare), bare.length), null)
  assert.equal(isWholeTranscode(null, 30_000_000), false)
  assert.equal(isWholeTranscode(null, undefined), true, 'no runtime, nothing to judge against')
})

test('a video download is judged as video', () => {
  assert.deepEqual(judgeDownload({ status: 200, expected: null, received: 10, contentType: 'video/mp4', video: true }), { ok: true, ext: 'mp4' })
  assert.deepEqual(judgeDownload({ status: 200, expected: 10, received: 10, contentDisposition: 'attachment; filename="Film.mkv"', video: true }), { ok: true, ext: 'mkv' })
  assert.equal(judgeDownload({ status: 200, expected: 10, received: 10, contentType: 'text/html', video: true }).ok, false)
  assert.equal(judgeDownload({ status: 200, expected: 10, received: 10, contentType: 'video/mp4' }).ok, false, 'music stays music')
  assert.equal(contentTypeForFile('media/x.mkv'), 'video/x-matroska')
  assert.equal(contentTypeForFile('subs/x.2.vtt'), 'text/vtt')
})

test('watched means 90 percent in, as Jellyfin counts it', () => {
  assert.equal(isWatchedPosition(90, 100), true)
  assert.equal(isWatchedPosition(89, 100), false)
  assert.equal(isWatchedPosition(90, undefined), false)
})

// ── The series follow and remove-watched ──

const ep = (Id: string, over: Partial<JfItem> = {}): JfItem => ({ Id, Name: Id, Type: 'Episode', SeriesId: 'show', SeasonId: 's1', ...over })
const series: JfItem = { Id: 'show', Name: 'Show', Type: 'Series' }
const t0 = new Date('2026-10-01T00:00:00Z')
const later = (ms: number) => new Date(t0.getTime() + ms)

test('a followed series fetches episodes added after the follow, not old or watched ones', () => {
  const index = emptyIndex()
  addCollection(index, series, [ep('e1'), ep('e2')])
  assert.deepEqual(newEpisodes(index, 'show', [ep('e3', { DateCreated: later(1000).toISOString() })]), [], 'not followed')
  setFollow(index, 'show', true, t0)
  const server = [
    ep('e1', { DateCreated: later(5000).toISOString() }),
    ep('old', { DateCreated: later(-1000).toISOString() }),
    ep('seen', { DateCreated: later(5000).toISOString(), UserData: { Played: true } }),
    ep('e3', { DateCreated: later(5000).toISOString() }),
  ]
  assert.deepEqual(newEpisodes(index, 'show', server).map(e => e.Id), ['e3'])
  addToCollection(index, 'show', [server[3]])
  assert.deepEqual(collectionOf(index, 'show')?.trackIds, ['e1', 'e2', 'e3'])
  setFollow(index, 'show', false, t0)
  assert.equal(collectionOf(index, 'show')?.follow, undefined)
})

test('remove-watched never comes back through the follow', () => {
  const index = emptyIndex()
  const fresh = later(5000).toISOString()
  addCollection(index, series, [ep('e1', { DateCreated: fresh })])
  setFollow(index, 'show', true, t0)
  markReady(index, 'e1', 'media/e1.mp4', 10, later(6000))
  markWatched(index, 'e1', later(7000))
  assert.deepEqual(watchedToRemove(index, later(7000 + REMOVE_WATCHED_AFTER_MS - 1)), [], 'not a day yet')
  assert.deepEqual(watchedToRemove(index, later(7000 + REMOVE_WATCHED_AFTER_MS)), ['e1'])
  assert.deepEqual(removeTracks(index, ['e1']), ['media/e1.mp4'])
  // The series stays, empty, waiting for new episodes; the server still says
  // e1 is unwatched (the play has not reached it yet), and it is not fetched.
  assert.deepEqual(collectionOf(index, 'show')?.trackIds, [])
  assert.deepEqual(newEpisodes(index, 'show', [ep('e1', { DateCreated: fresh }), ep('e2', { DateCreated: fresh })]).map(e => e.Id), ['e2'])
  // And it all survives a write and a read.
  const back = parseIndex(JSON.parse(JSON.stringify(index)))
  assert.deepEqual(collectionOf(back, 'show')?.skip, ['e1'])
  assert.equal(collectionOf(back, 'show')?.follow, t0.toISOString())
})

test('watched on the server counts only after the download, and movies are kept', () => {
  const index = emptyIndex()
  addCollection(index, { Id: 's1', Type: 'Season', Name: 'S1' }, [
    ep('before', { UserData: { Played: true, LastPlayedDate: later(-5000).toISOString() } }),
    ep('after', { UserData: { Played: true, LastPlayedDate: later(5000).toISOString() } }),
  ])
  addCollection(index, { Id: 'film', Type: 'Movie', Name: 'Film' }, [{ Id: 'film', Type: 'Movie', Name: 'Film' }])
  for (const id of ['before', 'after', 'film']) markReady(index, id, `media/${id}.mp4`, 10, t0)
  markWatched(index, 'film', t0)
  assert.deepEqual(watchedToRemove(index, later(REMOVE_WATCHED_AFTER_MS * 2)), ['after'])
  // A season emptied by removals goes; nothing follows it.
  removeTracks(index, ['before', 'after'])
  assert.equal(collectionOf(index, 's1'), undefined)
  assert.ok(collectionOf(index, 'film'))
})

test('the new track fields survive a write and a read, and nonsense does not', () => {
  const index = emptyIndex()
  addCollection(index, { Id: 'film', Type: 'Movie', Name: 'Film' }, [{ Id: 'film', Type: 'Movie', Name: 'Film' }])
  markReady(index, 'film', 'media/film.mp4', 10, t0)
  index.tracks.film.outcome = 'remux'
  index.tracks.film.burnIn = 3
  const back = parseIndex(JSON.parse(JSON.stringify(index)))
  assert.equal(back.tracks.film.readyAt, t0.toISOString())
  assert.equal(back.tracks.film.outcome, 'remux')
  assert.equal(back.tracks.film.burnIn, 3)
  const raw = JSON.parse(JSON.stringify(index))
  Object.assign(raw.tracks.film, { outcome: 'magic', burnIn: -1, watchedAt: 'yesterday' })
  const bad = parseIndex(raw)
  assert.equal(bad.tracks.film.outcome, undefined)
  assert.equal(bad.tracks.film.burnIn, undefined)
  assert.equal(bad.tracks.film.watchedAt, undefined)
})

// ── Placement ──

test('placement asks once per album or show, and takes the stored library among the ancestors', () => {
  const index = emptyIndex()
  setLibraries(index, [
    { Id: 'libmusic', Name: 'Music', CollectionType: 'music' },
    { Id: 'libtv', Name: 'TV Shows', CollectionType: 'tvshows' },
  ])
  addCollection(index, { Id: 'album', Type: 'MusicAlbum', Name: 'A' }, [
    { Id: 't1', Type: 'Audio', AlbumId: 'album' }, { Id: 't2', Type: 'Audio', AlbumId: 'album' }])
  addCollection(index, series, [ep('e1'), ep('e2')])
  addCollection(index, { Id: 'film', Type: 'Movie', Name: 'Film' }, [{ Id: 'film', Type: 'Movie', Name: 'Film' }])
  const groups = placementGroups(index, unplacedTrackIds(index))
  assert.deepEqual([...groups.entries()].sort(), [['album', ['t1', 't2']], ['film', ['film']], ['show', ['e1', 'e2']]])
  // As jellyfin12 answered for an episode: season, show, library, root.
  const ancestors = [
    { Id: 's3', Type: 'Season' }, { Id: 'show', Type: 'Series' },
    { Id: 'libtv', Type: 'CollectionFolder', CollectionType: 'tvshows' }, { Id: 'root', Type: 'UserRootFolder' }]
  assert.equal(libraryFromAncestors(index, ancestors), 'libtv')
  assert.equal(libraryFromAncestors(index, [{ Id: 'root' }]), null)
  assert.equal(libraryFromAncestors(index, { Items: [] }), null)
})
