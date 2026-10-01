import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  emptyIndex, addCollection, markReady, removeCollection, reconcile, pendingTrackIds, collectionProgress,
  totalBytes, collectionBytes, readyFile, indexedFiles, addPlay, dropsPlay, isSafeId, isSafeMediaPath, isSafeArtPath,
  parseIndex, slimItem, fileExtensionFor, judgeDownload, MAX_QUEUED_PLAYS, collectionOf, parseByteRange, contentTypeForFile,
} from '../src/core/offline-index.ts'
import type { JfItem } from '../src/core/types.ts'

const track = (Id: string, over: Partial<JfItem> = {}): JfItem => ({ Id, Name: Id, Type: 'Audio', ...over })
const album = (Id: string): JfItem => ({ Id, Name: Id, Type: 'MusicAlbum' })
const playlist = (Id: string): JfItem => ({ Id, Name: Id, Type: 'Playlist' })

test('a shared track outlives the first collection removed', () => {
  const index = emptyIndex()
  addCollection(index, album('a'), [track('1'), track('2')])
  addCollection(index, playlist('p'), [track('2'), track('3')])
  for (const id of ['1', '2', '3']) markReady(index, id, `media/${id}.flac`, 10)
  assert.equal(totalBytes(index), 30)

  assert.deepEqual(removeCollection(index, 'a'), ['media/1.flac'])
  assert.equal(readyFile(index, '2'), 'media/2.flac')
  assert.deepEqual(removeCollection(index, 'p'), ['media/2.flac', 'media/3.flac'])
  assert.deepEqual(index.tracks, {})
})

test('removing a collection that is not there deletes nothing', () => {
  const index = emptyIndex()
  addCollection(index, album('a'), [track('1')])
  markReady(index, '1', 'media/1.flac', 5)
  assert.deepEqual(removeCollection(index, 'zzz'), [])
  assert.equal(readyFile(index, '1'), 'media/1.flac')
})

test('asking again keeps what is on disk and puts the collection first', () => {
  const index = emptyIndex()
  addCollection(index, album('a'), [track('1')])
  markReady(index, '1', 'media/1.m4a', 5)
  addCollection(index, album('b'), [track('9')])
  addCollection(index, album('a'), [track('1'), track('2')])
  assert.deepEqual(index.collections.map(c => c.item.Id), ['a', 'b'])
  assert.equal(readyFile(index, '1'), 'media/1.m4a')
  assert.deepEqual(pendingTrackIds(index), ['9', '2'], 'oldest request first')
  assert.deepEqual(collectionProgress(index, 'a'), { done: 1, total: 2 })
})

test('pending lists a shared track once', () => {
  const index = emptyIndex()
  addCollection(index, album('a'), [track('1'), track('2')])
  addCollection(index, album('b'), [track('2'), track('3')])
  assert.deepEqual(pendingTrackIds(index), ['1', '2', '3'])
})

test('only music is kept, and only ids that can be file names', () => {
  const index = emptyIndex()
  addCollection(index, playlist('p'), [track('1'), { Id: '2', Type: 'Video' }, track('../x'), track('a.b'), { Id: '' }])
  assert.deepEqual(collectionOf(index, 'p')?.trackIds, ['1'])
})

test('reconcile requeues missing files and reports strays', () => {
  const index = emptyIndex()
  addCollection(index, album('a'), [track('1'), track('2')])
  markReady(index, '1', 'media/1.flac', 10)
  markReady(index, '2', 'media/2.flac', 10)
  const strays = reconcile(index, ['media/2.flac', 'media/old.flac'])
  assert.deepEqual(strays, ['media/old.flac'])
  assert.equal(readyFile(index, '1'), null)
  assert.deepEqual(pendingTrackIds(index), ['1'])
  assert.equal(totalBytes(index), 10)
  assert.deepEqual([...indexedFiles(index)], ['media/2.flac'])
})

test('collectionBytes counts a collection\'s ready tracks', () => {
  const index = emptyIndex()
  addCollection(index, album('a'), [track('1'), track('2')])
  markReady(index, '1', 'media/1.flac', 7)
  assert.equal(collectionBytes(index, 'a'), 7)
  assert.equal(collectionBytes(index, 'nope'), 0)
})

test('queued plays are capped, newest kept', () => {
  const index = emptyIndex()
  for (let i = 0; i < MAX_QUEUED_PLAYS + 3; i++) addPlay(index, { itemId: `t${i}`, userId: 'u', date: '2026-01-01T00:00:00.000Z' })
  assert.equal(index.plays.length, MAX_QUEUED_PLAYS)
  assert.equal(index.plays[0].itemId, 't3')
})

test('a refused play is dropped only when retrying cannot help', () => {
  assert.ok(dropsPlay(404)); assert.ok(dropsPlay(400))
  for (const keep of [0, 401, 403, 500, 502, 503]) assert.ok(!dropsPlay(keep), String(keep))
})

test('only plain ids and plain paths are safe', () => {
  assert.ok(isSafeId('4489a27fb2adcc74f790cb3d3d977ef7'))
  for (const bad of ['', '../x', 'a/b', 'a.b', 'é', 'a'.repeat(65), 5, null, undefined]) assert.ok(!isSafeId(bad), String(bad))
  assert.ok(isSafeMediaPath('media/abc.flac'))
  for (const bad of ['/etc/passwd', 'media/', 'media/.hidden', 'media/a/b.flac', 'art/1.jpg', 'media/../x', 'media/a..b', '', 5]) {
    assert.ok(!isSafeMediaPath(bad), String(bad))
  }
  assert.ok(isSafeArtPath('art/abc123.jpg'))
  for (const bad of ['art/../x.jpg', 'art/a.png', 'media/a.jpg', 'art/.jpg']) assert.ok(!isSafeArtPath(bad), bad)
})

test('parseIndex drops paths that leave the folder and survives garbage', () => {
  const index = emptyIndex()
  addCollection(index, album('a'), [track('1'), track('2')])
  markReady(index, '1', 'media/../../Documents/x', 1)
  markReady(index, '2', 'media/2.flac', 1)
  const back = parseIndex(JSON.parse(JSON.stringify(index)))
  assert.equal(readyFile(back, '1'), null)
  assert.equal(back.tracks['1'].bytes, 0)
  assert.equal(readyFile(back, '2'), 'media/2.flac')
  for (const junk of [null, undefined, 'not json', 5, [], { tracks: 'x', collections: 3, plays: {} }]) {
    assert.deepEqual(parseIndex(junk), emptyIndex(), String(junk))
  }
})

test('parseIndex drops tracks no collection holds, bad plays and mismatched ids', () => {
  const raw = {
    tracks: {
      '1': { item: { Id: '1' }, file: 'media/1.flac', bytes: 3 },
      '2': { item: { Id: '2' }, file: null, bytes: 0 },
      '3': { item: { Id: 'other' }, file: null, bytes: 0 },
      '../4': { item: { Id: '../4' }, file: null, bytes: 0 },
    },
    collections: [{ item: { Id: 'a' }, trackIds: ['1', '3', '../4', 7] }, { item: { Id: 'a' }, trackIds: ['2'] }, { item: { Id: '' }, trackIds: [] }],
    plays: [
      { itemId: '1', userId: 'u-1', date: '2026-02-03T04:05:06Z' },
      { itemId: '../x', userId: 'u', date: '2026-02-03T04:05:06Z' },
      { itemId: '1', userId: 'u', date: 'nope' },
      { itemId: '1', userId: 5, date: '2026-02-03T04:05:06Z' },
    ],
  }
  const back = parseIndex(raw)
  assert.deepEqual(Object.keys(back.tracks), ['1'])
  assert.deepEqual(back.collections.map(c => c.trackIds), [['1']], 'a repeated collection id is kept once')
  assert.deepEqual(back.plays, [{ itemId: '1', userId: 'u-1', date: '2026-02-03T04:05:06.000Z' }])
})

test('slimItem keeps what a row needs and nothing heavy', () => {
  const slim = slimItem({
    Id: '1', Name: 'Song', Type: 'Audio', Album: 'A', AlbumId: 'x', Artists: ['Me'], RunTimeTicks: 5,
    ImageTags: { Primary: 'tag' }, UserData: { PlayCount: 4 }, MediaStreams: [{ Type: 'Audio' }],
  } as JfItem)
  assert.deepEqual(slim, { Id: '1', Name: 'Song', Type: 'Audio', Album: 'A', AlbumId: 'x', Artists: ['Me'], RunTimeTicks: 5, ImageTags: { Primary: 'tag' } })
})

test('the extension comes from the file name, then the MIME type', () => {
  assert.equal(fileExtensionFor('attachment; filename="01 - Song.FLAC"', 'audio/flac'), 'flac')
  assert.equal(fileExtensionFor("attachment; filename*=UTF-8''Song.m4a", null), 'm4a')
  assert.equal(fileExtensionFor(null, 'audio/mpeg'), 'mp3')
  assert.equal(fileExtensionFor('attachment', 'audio/mp4; codecs=mp4a'), 'm4a')
  assert.equal(fileExtensionFor('attachment; filename="x.a b"', 'text/html'), null)
  assert.equal(fileExtensionFor(null, null), null)
  assert.equal(fileExtensionFor('attachment; filename="no-extension"', 'application/octet-stream'), null)
})

test('only a whole audio response becomes a track', () => {
  const flac = { contentDisposition: 'attachment; filename="01 Song.flac"', contentType: 'audio/flac' }
  const refused = judgeDownload({ status: 403, expected: null, received: 10, ...flac })
  assert.ok(!refused.ok && /admin/.test(refused.message), 'a 403 page was kept')
  assert.ok(!judgeDownload({ status: 404, expected: 10, received: 10, ...flac }).ok)
  assert.ok(!judgeDownload({ status: 199, expected: 10, received: 10, ...flac }).ok)
  const short = judgeDownload({ status: 200, expected: 99, received: 10, ...flac })
  assert.ok(!short.ok && /cut short/.test(short.message), 'a short file was kept')
  assert.ok(!judgeDownload({ status: 200, expected: 10, received: 11, ...flac }).ok, 'a long file is not the file announced')
  assert.ok(!judgeDownload({ status: 200, expected: null, received: 0, ...flac }).ok, 'an empty file was kept')
  const html = judgeDownload({ status: 200, expected: 10, received: 10, contentType: 'text/html' })
  assert.ok(!html.ok && /not a music file/.test(html.message), 'a proxy login page was kept')
  assert.deepEqual(judgeDownload({ status: 200, expected: 10, received: 10, ...flac }), { ok: true, ext: 'flac' })
  assert.deepEqual(judgeDownload({ status: 206, expected: null, received: 10, ...flac }), { ok: true, ext: 'flac' }, 'no announced length: nothing to compare')
})

test('parseByteRange: the ranges a media element asks for', () => {
  assert.deepEqual(parseByteRange('bytes=0-9', 100), { start: 0, end: 9 })
  assert.deepEqual(parseByteRange('bytes=90-', 100), { start: 90, end: 99 }, 'open-ended, what a seek sends')
  assert.deepEqual(parseByteRange('bytes=0-', 100), { start: 0, end: 99 })
  assert.deepEqual(parseByteRange('bytes=50-5000', 100), { start: 50, end: 99 }, 'an end past the file is clamped')
  assert.deepEqual(parseByteRange('bytes=-10', 100), { start: 90, end: 99 }, 'the last ten bytes')
  assert.deepEqual(parseByteRange('bytes=-500', 100), { start: 0, end: 99 }, 'a suffix longer than the file is all of it')
  assert.deepEqual(parseByteRange(' bytes=5-5 ', 100), { start: 5, end: 5 })
})

test('parseByteRange: nothing usable means the whole file, nothing satisfiable means 416', () => {
  for (const none of [null, undefined, '', 'bytes=', 'bytes=-', 'items=0-5', 'bytes=0-5,10-15', 'bytes=a-b', 'garbage']) {
    assert.equal(parseByteRange(none, 100), null, String(none))
  }
  for (const bad of ['bytes=100-', 'bytes=100-200', 'bytes=10-5', 'bytes=-0']) assert.equal(parseByteRange(bad, 100), 'unsatisfiable', bad)
  assert.equal(parseByteRange('bytes=0-9', 0), 'unsatisfiable', 'an empty file has no bytes to give')
})

test('contentTypeForFile names what a stored file is', () => {
  assert.equal(contentTypeForFile('media/x.flac'), 'audio/flac')
  assert.equal(contentTypeForFile('media/x.M4A'), 'audio/mp4')
  assert.equal(contentTypeForFile('art/x.jpg'), 'image/jpeg')
  assert.equal(contentTypeForFile('media/x.zzz'), 'application/octet-stream')
})
