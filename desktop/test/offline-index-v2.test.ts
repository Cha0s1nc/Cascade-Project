// Catalog version 2: what it adds to version 1 (docs/offline-mode-plan.md,
// section 1). Version 1's own rules stay in offline-index.test.ts.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  INDEX_VERSION, emptyIndex, parseIndex, addCollection, markReady, removeCollection, reconcile, readyFile,
  libraryOf, librariesInUse, setLibraries, assignLibrary, unplacedTrackIds, PLACEHOLDER_LIBRARIES,
  setLyrics, lyricsOf, expiredLyricsTrackIds, dropLyrics, SPICY_LYRICS_DAYS, setSubtitles, setSegments, setExplicit,
  setUser, setHistory, historyEntriesOf, MAX_HISTORY_ENTRIES, indexedFiles, isSafeSubtitlePath, collectionOf, refreshItems,
  lyricsSourceKey, lyricsSourceLabel,
} from '../src/core/offline-index.ts'
import type { JfItem } from '../src/core/types.ts'

const v1 = JSON.parse(readFileSync(new URL('./fixtures/offline-index-v1.json', import.meta.url), 'utf8'))
const TRACK_1 = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
const TRACK_2 = 'b2c3d4e5f60718293a4b5c6d7e8f90a1'
const ALBUM = '0aa1bb2cc3dd4ee5ff60718293a4b5c6'

const track = (Id: string, over: Partial<JfItem> = {}): JfItem => ({ Id, Name: Id, Type: 'Audio', ...over })
const episode = (Id: string, SeasonId: string, SeriesId = 'show'): JfItem => ({ Id, Name: Id, Type: 'Episode', SeasonId, SeriesId })
const views: JfItem[] = [
  { Id: 'libmusic', Name: 'Music', CollectionType: 'music' },
  { Id: 'libmovies', Name: 'Films', CollectionType: 'movies' },
  { Id: 'libbooks', Name: 'Books', CollectionType: 'books' },
  { Id: '../x', Name: 'Bad', CollectionType: 'music' },
]

test('a real version 1 file reads into version 2 with nothing lost', () => {
  const index = parseIndex(v1)
  assert.equal(index.version, INDEX_VERSION)
  assert.deepEqual(Object.keys(index.tracks).sort(), [TRACK_1, TRACK_2])
  assert.equal(readyFile(index, TRACK_1), `media/${TRACK_1}.flac`)
  assert.equal(index.tracks[TRACK_1].bytes, 21456789)
  assert.equal(index.tracks[TRACK_1].item.NormalizationGain, -6.2)
  assert.deepEqual(collectionOf(index, ALBUM)?.trackIds, [TRACK_1, TRACK_2])
  assert.equal(index.plays.length, 1)
  assert.deepEqual(index.libraries, [])
  assert.equal(index.user, null)
  assert.equal(index.history, null)
  // Saved and read again, it is the same index.
  assert.deepEqual(parseIndex(JSON.parse(JSON.stringify(index))), index)
})

test('version 1 items fall into the placeholder library until placed', () => {
  const index = parseIndex(v1)
  assert.equal(libraryOf(index, TRACK_1), PLACEHOLDER_LIBRARIES.Audio.Id)
  assert.deepEqual(librariesInUse(index), [PLACEHOLDER_LIBRARIES.Audio])
  assert.deepEqual(unplacedTrackIds(index), [TRACK_1, TRACK_2])

  setLibraries(index, views)
  assert.deepEqual(index.libraries.map(l => l.Id), ['libmusic', 'libmovies'], 'books and bad ids are not kept')
  assignLibrary(index, [TRACK_1], 'libmusic')
  assignLibrary(index, [TRACK_2], 'nowhere')
  assert.equal(libraryOf(index, TRACK_1), 'libmusic')
  assert.equal(libraryOf(index, TRACK_2), PLACEHOLDER_LIBRARIES.Audio.Id, 'a library not in the list is refused')
  assert.deepEqual(librariesInUse(index).map(l => l.Id), ['libmusic', PLACEHOLDER_LIBRARIES.Audio.Id])
  assert.deepEqual(unplacedTrackIds(index), [TRACK_2])

  // A library that leaves the server's list sends its items back to the placeholder.
  setLibraries(index, views.filter(v => v.Id !== 'libmusic'))
  assert.equal(libraryOf(index, TRACK_1), PLACEHOLDER_LIBRARIES.Audio.Id)
})

test('each kind has its own placeholder', () => {
  const index = emptyIndex()
  addCollection(index, { Id: 'm1', Type: 'Movie' }, [{ Id: 'm1', Type: 'Movie' }])
  addCollection(index, { Id: 's1', Type: 'Season' }, [episode('e1', 's1')])
  assert.equal(libraryOf(index, 'm1'), PLACEHOLDER_LIBRARIES.Movie.Id)
  assert.equal(libraryOf(index, 'e1'), PLACEHOLDER_LIBRARIES.Episode.Id)
  assert.equal(libraryOf(index, 'nope'), null)
})

test('a placeholder id stored on a track is not trusted', () => {
  const raw = JSON.parse(JSON.stringify(v1))
  raw.tracks[TRACK_1].library = PLACEHOLDER_LIBRARIES.Movie.Id
  assert.equal(parseIndex(raw).tracks[TRACK_1].library, undefined)
})

test('a season keeps its show; removing the last episode of a show forgets both', () => {
  const index = emptyIndex()
  const show = { Id: 'show', Name: 'Show', Type: 'Series' }
  const s1 = { Id: 's1', Name: 'Season 1', Type: 'Season', SeriesId: 'show' }
  const s2 = { Id: 's2', Name: 'Season 2', Type: 'Season', SeriesId: 'show' }
  addCollection(index, s1, [episode('e1', 's1'), episode('e2', 's1')], [show, s1, { Id: 'x', Type: 'Folder' }])
  addCollection(index, s2, [episode('e3', 's2')], [show, s2])
  assert.deepEqual(Object.keys(index.containers).sort(), ['s1', 's2', 'show'], 'only series and seasons are containers')

  removeCollection(index, 's1')
  assert.deepEqual(Object.keys(index.containers).sort(), ['s2', 'show'])
  removeCollection(index, 's2')
  assert.deepEqual(index.containers, {})
})

test('a movie is its own collection', () => {
  const index = emptyIndex()
  const movie = { Id: 'm1', Name: 'Film', Type: 'Movie' }
  addCollection(index, movie, [movie, { Id: 'v', Type: 'Video' }])
  assert.deepEqual(collectionOf(index, 'm1')?.trackIds, ['m1'], 'a plain Video is not one of the kinds kept')
})

test('subtitles are files: removed with their item, forgotten when missing, strays reported', () => {
  const index = emptyIndex()
  addCollection(index, { Id: 'm1', Type: 'Movie' }, [{ Id: 'm1', Type: 'Movie' }])
  markReady(index, 'm1', 'media/m1.mp4', 100)
  setSubtitles(index, 'm1', [
    { index: 3, file: 'subs/m1.3.vtt', language: 'eng' },
    { index: 4, file: 'subs/m1.4.vtt' },
    { index: 4, file: 'subs/m1.4.vtt' },
    { index: 5, file: 'subs/../../x.vtt' },
    { index: -1, file: 'subs/m1.1.vtt' },
  ])
  assert.deepEqual(index.tracks.m1.subs?.map(s => s.index), [3, 4])
  assert.deepEqual([...indexedFiles(index)].sort(), ['media/m1.mp4', 'subs/m1.3.vtt', 'subs/m1.4.vtt'])

  assert.deepEqual(reconcile(index, ['media/m1.mp4', 'subs/m1.3.vtt', 'subs/old.2.vtt']), ['subs/old.2.vtt'])
  assert.deepEqual(index.tracks.m1.subs?.map(s => s.index), [3])
  assert.deepEqual(removeCollection(index, 'm1'), ['media/m1.mp4', 'subs/m1.3.vtt'])
})

test('only plain subtitle paths are safe', () => {
  assert.ok(isSafeSubtitlePath('subs/abc123.12.vtt'))
  for (const bad of ['subs/abc.vtt', 'subs/a/b.1.vtt', 'media/a.1.vtt', 'subs/a.1.srt', '../subs/a.1.vtt', 5]) {
    assert.equal(isSafeSubtitlePath(bad), false, String(bad))
  }
})

test('SpicyLyrics expire after the plugin\'s 25 days; other sources never do', () => {
  const index = emptyIndex()
  addCollection(index, { Id: 'a', Type: 'MusicAlbum' }, [track('t1'), track('t2')])
  const saved = new Date('2026-10-01T00:00:00Z')
  const lines = [{ Start: 0, End: 10, Text: 'la', Words: null }, { Start: 'x', Text: 'bad' }] as never
  setLyrics(index, 't1', { source: 'spicy', synced: true, lines }, saved)
  setLyrics(index, 't2', { source: 'lrclib', synced: true, lines }, saved)
  assert.deepEqual(index.tracks.t1.lyrics?.lines, [{ Start: 0, End: 10, Text: 'la', Words: null }])

  const day = 86_400_000
  const before = new Date(saved.getTime() + (SPICY_LYRICS_DAYS - 1) * day)
  const after = new Date(saved.getTime() + SPICY_LYRICS_DAYS * day)
  assert.ok(lyricsOf(index, 't1', before))
  assert.equal(lyricsOf(index, 't1', after), null)
  assert.ok(lyricsOf(index, 't2', new Date(saved.getTime() + 3650 * day)))
  assert.deepEqual(expiredLyricsTrackIds(index, after), ['t1'])
  dropLyrics(index, 't1')
  assert.deepEqual(expiredLyricsTrackIds(index, after), [])
  assert.equal(index.tracks.t1.lyrics, undefined, 'the expired lines are gone from the catalog')
  assert.ok(index.tracks.t2.lyrics, 'a source that never expires is kept')
})

test('SpicyLyrics with an unreadable expiry are treated as expired, not kept', () => {
  const index = emptyIndex()
  addCollection(index, { Id: 'a', Type: 'MusicAlbum' }, [track('t1')])
  const raw = JSON.parse(JSON.stringify(index))
  raw.tracks.t1.lyrics = { source: 'spicy', synced: true, lines: [{ Start: 0, Text: 'x' }], savedAt: '2026-10-01T00:00:00Z', expiresAt: 'later' }
  assert.equal(lyricsOf(parseIndex(raw), 't1', new Date('2026-10-02T00:00:00Z')), null)
})

test('segments, explicit, user and history survive a save and are validated', () => {
  const index = emptyIndex()
  addCollection(index, { Id: 'm1', Type: 'Movie' }, [{ Id: 'm1', Type: 'Movie' }])
  setSegments(index, 'm1', [
    { Type: 'Intro', StartTicks: 0, EndTicks: 900 },
    { Type: 'Outro', StartTicks: 50, EndTicks: 10 },
  ])
  setExplicit(index, 'm1', true)
  setUser(index, { Id: 'u-1', Name: 'Kai', Policy: { IsAdministrator: false, EnableContentDownloading: true, EnableContentDeletionFromFolders: ['f', 3], Secret: 'x' } })
  setHistory(index, [
    { Id: 'm1', UserData: { LastPlayedDate: '2026-10-01T10:00:00Z', PlayCount: 2 } },
    { Id: '../bad' },
    { Id: 't9' },
  ], new Date('2026-10-02T00:00:00Z'))

  const back = parseIndex(JSON.parse(JSON.stringify(index)))
  assert.deepEqual(back.tracks.m1.segments, [{ Type: 'Intro', StartTicks: 0, EndTicks: 900 }])
  assert.equal(back.tracks.m1.explicit, true)
  assert.deepEqual(back.user, { Id: 'u-1', Name: 'Kai', Policy: { IsAdministrator: false, EnableContentDownloading: true, EnableContentDeletionFromFolders: ['f'] } })
  assert.deepEqual(back.history, {
    takenAt: '2026-10-02T00:00:00.000Z',
    entries: [
      { Id: 'm1', LastPlayedDate: '2026-10-01T10:00:00Z', PlayCount: 2 },
      { Id: 't9', LastPlayedDate: null, PlayCount: 0 },
    ],
  })
  assert.equal(parseIndex({ ...JSON.parse(JSON.stringify(index)), user: { Id: '../u', Name: 'x' } }).user, null)
})

test('the history snapshot is capped', () => {
  const items = Array.from({ length: MAX_HISTORY_ENTRIES + 20 }, (_, i) => ({ Id: `t${i}` }))
  assert.equal(historyEntriesOf(items).length, MAX_HISTORY_ENTRIES)
})

test('a collection of an unknown kind is not read back', () => {
  const raw = JSON.parse(JSON.stringify(v1))
  raw.collections.push({ item: { Id: 'f1', Type: 'Folder' }, trackIds: [TRACK_1] })
  assert.equal(collectionOf(parseIndex(raw), 'f1'), undefined)
})

test('a refresh fills in what version 1 never kept and keeps what the copy lacks', () => {
  const index = parseIndex(v1)
  refreshItems(index, [
    { Id: TRACK_1, Name: 'Intro', ArtistItems: [{ Id: 'art1', Name: 'The Lanterns' }], UserData: { PlayCount: 3 } },
    { Id: 'not-downloaded', Name: 'x' },
  ])
  const item = index.tracks[TRACK_1].item
  assert.deepEqual(item.ArtistItems, [{ Id: 'art1', Name: 'The Lanterns' }])
  assert.equal(item.UserData?.PlayCount, 3)
  assert.equal(item.NormalizationGain, -6.2, 'a list copy has no gain; the stored one stays')
  assert.equal(index.tracks['not-downloaded'], undefined)
})

test('SpicyLyrics keep their credit; sources are stored by key and shown by name', () => {
  const index = emptyIndex()
  addCollection(index, { Id: 'a', Type: 'MusicAlbum' }, [track('t1')])
  const credit = { provider: 'Spicy Lyrics', uploader: { name: 'kai', url: 'https://x' }, maker: null, extra: 1 }
  setLyrics(index, 't1', { source: lyricsSourceKey('Spicy Lyrics', true), synced: true, lines: [{ Start: 0, End: 1, Text: 'la', Words: null }], credit } as never, new Date())
  const back = parseIndex(JSON.parse(JSON.stringify(index)))
  assert.deepEqual(back.tracks.t1.lyrics?.credit, { provider: 'Spicy Lyrics', uploader: { name: 'kai', url: 'https://x' }, maker: null })
  assert.equal(back.tracks.t1.lyrics?.source, 'spicy')
  assert.ok(back.tracks.t1.lyrics?.expiresAt)
  assert.equal(lyricsSourceLabel(back.tracks.t1.lyrics!), 'Spicy Lyrics')
  assert.deepEqual(['Kugou', 'LRCLIB (plain)', 'Jellyfin', 'Karaoke', 'Cascade'].map(l => lyricsSourceKey(l, false)),
    ['kugou', 'lrclib', 'jellyfin', 'cascade', 'cascade'])
})
