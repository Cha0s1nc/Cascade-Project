import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  fileId, albumId, artistId, genreId, seriesId, seasonId, playlistFileId, normRel,
  kindByExtension, classify, isSidecar, codecName, probeFromMetadata, parseProbe, playability, containerOf,
  parseNameYear, parseEpisode, parseMovie, parseTrackFileName, lyricsSidecar, subtitleSidecars, srtToVtt, parseM3u,
  parseLocalPlaylists, buildCatalog, LOCAL_LIBRARIES, LOCAL_USER_ID, rootKeys, folderName,
  type LocalFile, type LocalBuildInput,
} from '../src/core/local-scan.ts'
import { applyLocalChange, parseLocalChange, parseUserData, setLocalUserData } from '../src/core/local-user-data.ts'
import { isSafeId, parseIndex } from '../src/core/offline-index.ts'
import { offlineQuery } from '../src/core/offline-query.ts'
import { ELECTRON_PROFILE, buildElectronProfile } from '../src/core/profiles/electron.ts'

// ── Ids ──

test('ids are stable, safe and kept apart by kind', () => {
  const a = fileId('Music/Artist/Album/01 Song.mp3')
  assert.equal(a, fileId('Music/Artist/Album/01 Song.mp3'))
  assert.equal(a, fileId('Music\\Artist\\Album\\01 Song.mp3'), 'Windows separators read the same')
  assert.equal(a, fileId('/Music/Artist/Album/01 Song.mp3'))
  assert.notEqual(a, fileId('Music/Artist/Album/02 Song.mp3'))
  assert.equal(fileId('Bjo\u0308rk/Song.mp3'), fileId('Bj\u00f6rk/Song.mp3'), 'macOS decomposed names match composed ones')
  for (const id of [a, albumId('A', 'B'), artistId('A'), genreId('Rock'), seriesId('Show'), seasonId('Show', 1), playlistFileId('x.m3u')]) {
    assert.match(id, /^[0-9a-f]{32}$/)
    assert.equal(isSafeId(id), true)
  }
  assert.equal(artistId('Daft  Punk '), artistId('daft punk'), 'names compare without case or doubled spaces')
  assert.notEqual(artistId('Rock'), genreId('Rock'), 'an artist and a genre of one name are not one item')
  assert.equal(albumId('Artist A', 'Album One'), albumId('artist a', 'ALBUM ONE'))
  assert.notEqual(albumId('Artist A', 'Greatest Hits'), albumId('Artist B', 'Greatest Hits'))
  assert.notEqual(seasonId('Show', 1), seasonId('Show', 2))
  assert.equal(normRel('\\a\\b.mp3'), 'a/b.mp3')
})

// ── What a file is ──

test('the extension decides, and the streams decide an ambiguous container', () => {
  assert.equal(kindByExtension('a/b.MP3'), 'audio')
  assert.equal(kindByExtension('a/b.flac'), 'audio')
  assert.equal(kindByExtension('a/b.avi'), 'video')
  assert.equal(kindByExtension('a/b.mp4'), 'ambiguous')
  assert.equal(kindByExtension('a/b.mkv'), 'ambiguous')
  assert.equal(kindByExtension('a/b.txt'), null)
  assert.equal(kindByExtension('a/.mp3'), null, 'a dot-file has no extension')
  assert.equal(classify('x/Audio Only.mp4', { hasVideo: false }), 'audio')
  assert.equal(classify('x/Film.mp4', { hasVideo: true }), 'video')
  assert.equal(classify('x/Film.mp4', null), 'video', 'unreadable: taken as what the container usually is')
  assert.equal(classify('x/Album.mka', null), 'audio')
  assert.equal(classify('x/notes.txt', null), null)
  assert.equal(isSidecar('a/01 Song.lrc'), true)
  assert.equal(isSidecar('a/Film.en.srt'), true)
  assert.equal(isSidecar('a/cover.JPG'), true)
  assert.equal(isSidecar('a/list.m3u8'), true)
  assert.equal(isSidecar('a/readme.md'), false)
})

test('codecs are named as Jellyfin names them', () => {
  const cases: [string, string | undefined][] = [
    ['V_MPEG4/ISO/AVC', 'h264'], ['<avc1>', 'h264'], ['MPEG4/ISO/AVC', 'h264'],
    ['V_MPEGH/ISO/HEVC', 'hevc'], ['hvc1', 'hevc'], ['hev1', 'hevc'], ['MPEGH/ISO/HEVC', 'hevc'],
    ['VP9', 'vp9'], ['V_VP8', 'vp8'], ['av01', 'av1'], ['V_MPEG2', 'mpeg2video'],
    ['MPEG-4/AAC', 'aac'], ['A_AAC/MPEG4/LC', 'aac'], ['mp4a', 'aac'],
    ['MPEG 1 Layer 3', 'mp3'], ['MPEG 2.5 Layer 3', 'mp3'], ['A_MPEG/L3', 'mp3'],
    ['FLAC', 'flac'], ['OPUS', 'opus'], ['Vorbis I', 'vorbis'], ['A_EAC3', 'eac3'], ['ec-3', 'eac3'],
    ['A_AC3', 'ac3'], ['ac-3', 'ac3'], ['A_DTS', 'dts'], ['A_TRUEHD', 'truehd'], ['ALAC', 'alac'],
    ['PCM', 'pcm'], ['A_PCM/INT/LIT', 'pcm'], ['', undefined], ['S_TEXT/UTF8', undefined],
  ]
  for (const [raw, want] of cases) assert.equal(codecName(raw), want, raw)
  assert.equal(codecName(undefined), undefined)
})

// Shapes copied from music-metadata 12's output for files ffmpeg made.
const MM = {
  mp3: { format: { container: 'MPEG', codec: 'MPEG 1 Layer 3', hasVideo: false, duration: 8.0457, trackInfo: [{ type: 2, audio: { channels: 1 }, codecName: 'MPEG 1 Layer 3' }] },
    common: { title: 'First Song', artists: ['Artist A'], artist: 'Artist A', albumartist: 'Artist A', album: 'Album One', track: { no: 1, of: null }, disk: { no: null, of: null }, year: 2019, genre: ['Rock'] } },
  flac: { format: { codec: 'FLAC', hasVideo: false, duration: 8, trackInfo: [{ type: 2, audio: { channels: 1 }, codecName: 'FLAC' }] },
    common: { title: 'Second Song', artists: ['Artist A feat. C'], albumartist: 'Artist A', album: 'Album One', track: { no: 2 }, disk: { no: null }, genre: ['Rock; Indie'], replaygain_track_gain: { dB: -6.5, ratio: 0.22 } } },
  alac: { format: { container: 'M4A/isom/iso2', codec: 'ALAC', hasVideo: false, duration: 8, trackInfo: [{ id: 1, type: 2, codecId: 'alac', codecName: 'ALAC', audio: { channels: 1 } }] },
    common: { title: 'Alac Song', artists: ['Artist B'], album: 'Second', track: { no: 2 }, disk: { no: null } } },
  audioMp4: { format: { container: 'isom/iso2/mp41', codec: 'MPEG-4/AAC', hasVideo: false, duration: 8.02, trackInfo: [{ type: 2, codecId: 'mp4a', codecName: 'MPEG-4/AAC', audio: { channels: 1 } }] }, common: { track: { no: null }, disk: { no: null } } },
  hevcMkv: { format: { container: 'EBML/matroska', codec: 'AAC', hasVideo: true, duration: 4.023, trackInfo: [
    { id: 1, codecId: 'V_MPEGH/ISO/HEVC', codecName: 'MPEGH/ISO/HEVC', type: 1, video: { pixelWidth: 320, pixelHeight: 240 } },
    { id: 2, codecId: 'A_AAC', codecName: 'AAC', type: 2, audio: { channels: 1 } }] }, common: {} },
  h264Mp4: { format: { container: 'isom/iso2/avc1/mp41', codec: 'MPEG-4/AAC', hasVideo: true, duration: 4.02, trackInfo: [
    { id: 1, type: 1, codecId: 'avc1', codecName: '<avc1>', video: { displayWidth: 320, displayHeight: 240, pixelWidth: 320, pixelHeight: 240 } },
    { id: 2, type: 2, codecId: 'mp4a', codecName: 'MPEG-4/AAC', audio: { channels: 1 } }] }, common: {} },
  dtsMkv: { format: { hasVideo: true, duration: 60, trackInfo: [
    { type: 1, codecId: 'V_MPEG4/ISO/AVC', video: {} },
    { type: 2, codecId: 'A_DTS', audio: { channels: 6 } },
    { type: 2, codecId: 'A_AAC', audio: { channels: 2 } }] }, common: {} },
  dtsDefaultSecond: { format: { hasVideo: true, trackInfo: [
    { type: 1, codecId: 'V_MPEG4/ISO/AVC', video: {} },
    { type: 2, codecId: 'A_AAC', audio: {} },
    { type: 2, codecId: 'A_DTS', flagDefault: true, audio: {} }] }, common: {} },
}

test('tags become one probe, values checked', () => {
  assert.deepEqual(probeFromMetadata(MM.mp3), {
    title: 'First Song', albumArtist: 'Artist A', album: 'Album One', audioCodec: 'mp3',
    track: 1, year: 2019, durationSec: 8.0457, channels: 1, artists: ['Artist A'], genres: ['Rock'], hasVideo: false,
  })
  const flac = probeFromMetadata(MM.flac)!
  assert.equal(flac.trackGainDb, -6.5, 'ReplayGain becomes the normalization gain')
  assert.deepEqual(flac.genres, ['Rock', 'Indie'], 'a joined genre tag is split as Jellyfin splits it')
  const joined = probeFromMetadata({ format: {}, common: { artists: ['All Time Low; Demi Lovato; blackbear', 'AC/DC'] } })!
  assert.deepEqual(joined.artists, ['All Time Low', 'Demi Lovato', 'blackbear', 'AC/DC'], 'a joined artist tag is split on ";" only')
  assert.equal(flac.disc, undefined, 'a missing disc number is not 0')
  assert.equal(probeFromMetadata(MM.alac)!.audioCodec, 'alac')
  assert.equal(probeFromMetadata(MM.audioMp4)!.hasVideo, false)
  const hevc = probeFromMetadata(MM.hevcMkv)!
  assert.equal(hevc.videoCodec, 'hevc')
  assert.equal(hevc.audioCodec, 'aac')
  assert.equal(hevc.width, 320)
  assert.equal(probeFromMetadata(MM.h264Mp4)!.videoCodec, 'h264')
  assert.equal(probeFromMetadata(MM.dtsMkv)!.audioCodec, 'dts', 'Chromium plays the first audio track')
  assert.equal(probeFromMetadata(MM.dtsDefaultSecond)!.audioCodec, 'dts', 'or the one marked default')
  assert.equal(probeFromMetadata(null), null)
  assert.deepEqual(parseProbe({ title: '  T\u0000 ', track: 'x', year: NaN, artists: ['A', 'a', 3], embeddedArt: 'yes' }), { title: 'T', artists: ['A'] })
})

test('only what Chromium plays as it is gets indexed', () => {
  const p = ELECTRON_PROFILE
  const ok = (rel: string, probe: object | null, profile = p) => playability(profile, rel.endsWith('mp4') || rel.endsWith('mkv') || rel.endsWith('webm') || rel.endsWith('avi') ? (probe && (probe as { videoCodec?: string }).videoCodec ? 'video' : 'audio') : 'audio', rel, probe).ok
  assert.equal(ok('a.mp3', { audioCodec: 'mp3' }), true)
  assert.equal(ok('a.flac', null), true, 'a container with no codec list plays whatever it holds')
  assert.equal(ok('a.m4a', { audioCodec: 'aac' }), true)
  assert.equal(ok('a.m4a', { audioCodec: 'alac' }), false, 'ALAC shares the container and Chromium has no decoder')
  assert.equal(ok('a.m4a', null), false)
  assert.equal(ok('a.mp4', { audioCodec: 'aac' }), true, 'an audio-only mp4')
  assert.equal(ok('a.wma', {}), false)
  assert.equal(ok('a.ape', {}), false)
  assert.equal(ok('f.mkv', { videoCodec: 'h264', audioCodec: 'aac' }), true)
  assert.equal(ok('f.webm', { videoCodec: 'vp9', audioCodec: 'opus' }), true)
  assert.equal(ok('f.mkv', { videoCodec: 'hevc', audioCodec: 'aac' }), false, 'HEVC never plays from Matroska')
  assert.equal(ok('f.mp4', { videoCodec: 'hevc', audioCodec: 'aac' }), false, 'nor from mp4 when the host has no decoder')
  const hevcHost = buildElectronProfile(m => m.includes('hvc1') || m.includes('hev1'))
  assert.equal(ok('f.mp4', { videoCodec: 'hevc', audioCodec: 'aac' }, hevcHost), true)
  assert.equal(ok('f.mkv', { videoCodec: 'hevc', audioCodec: 'aac' }, hevcHost), false)
  assert.equal(ok('f.mkv', { videoCodec: 'h264', audioCodec: 'dts' }), false)
  assert.equal(ok('f.mkv', { videoCodec: 'h264', audioCodec: 'ac3' }), false)
  assert.equal(ok('f.mkv', { videoCodec: 'h264', audioCodec: 'ac3' }, buildElectronProfile(m => m.includes('ac-3'))), true)
  assert.equal(ok('f.mkv', { videoCodec: 'h264' }), true, 'a film with no sound plays')
  assert.equal(ok('f.avi', { videoCodec: 'mpeg4', audioCodec: 'mp3' }), false)
  const r = playability(p, 'video', 'f.mkv', { videoCodec: 'hevc', audioCodec: 'aac' })
  assert.equal(r.ok, false)
  assert.match((r as { reason: string }).reason, /HEVC/)
  assert.match((playability(p, 'video', 'f.mkv', null) as { reason: string }).reason, /couldn't read/)
  assert.equal(containerOf('a.M4V'), 'mp4')
  assert.equal(containerOf('a.oga'), 'ogg')
})

// ── Names ──

test('names and years come out of folder and file names', () => {
  assert.deepEqual(parseNameYear('Test Movie (2010)'), { name: 'Test Movie', year: 2010 })
  assert.deepEqual(parseNameYear('Blade Runner 2049 (2017)'), { name: 'Blade Runner 2049', year: 2017 })
  assert.deepEqual(parseNameYear('The.Matrix.1999.1080p.BluRay.x264'), { name: 'The Matrix', year: 1999 })
  assert.deepEqual(parseNameYear('1917 (2019)'), { name: '1917', year: 2019 })
  assert.deepEqual(parseNameYear('Inception [2010]'), { name: 'Inception', year: 2010 })
  assert.deepEqual(parseNameYear('Some.Film.720p.WEB-DL'), { name: 'Some Film' })
  assert.deepEqual(parseNameYear('Mr. Robot'), { name: 'Mr. Robot' })
  assert.deepEqual(parseNameYear('2001'), { name: '2001' }, 'a year on its own is the name')
  assert.deepEqual(parseNameYear('Extended'), { name: 'Extended' }, 'a name that is only a release tag keeps it')
  assert.deepEqual(parseMovie('Movies/Test Movie (2010)/Test Movie (2010).mkv'), { name: 'Test Movie', year: 2010 })
  assert.deepEqual(parseMovie('Movies/Test Movie (2010)/movie.mkv'), { name: 'Test Movie', year: 2010 }, 'the folder names the film')
  assert.deepEqual(parseMovie('Movies/The.Matrix.1999.1080p.mkv'), { name: 'The Matrix', year: 1999 })
  assert.deepEqual(parseMovie('Loose Film.mp4'), { name: 'Loose Film' })
  assert.deepEqual(parseTrackFileName('01 First Song'), { track: 1, title: 'First Song' })
  assert.deepEqual(parseTrackFileName('1-03 Third'), { disc: 1, track: 3, title: 'Third' })
  assert.deepEqual(parseTrackFileName('07. Seventh'), { track: 7, title: 'Seventh' })
  assert.deepEqual(parseTrackFileName('Just A Title'), { title: 'Just A Title' })
  assert.deepEqual(parseTrackFileName('1999'), { title: '1999' }, 'a number alone is a title, not a track')
})

test('episodes follow Jellyfin naming', () => {
  assert.deepEqual(parseEpisode('Shows/Show/Season 01/Show S01E01.mkv'), { series: 'Show', season: 1, episode: 1, title: 'Episode 1' })
  assert.deepEqual(parseEpisode('Shows/Test Show/Season 01/Test Show S01E02 The Second.webm'), { series: 'Test Show', season: 1, episode: 2, title: 'The Second' })
  assert.deepEqual(parseEpisode('TV/Show (2019)/Season 2/E05 - Name.mp4'), { series: 'Show', season: 2, episode: 5, title: 'Name' })
  assert.deepEqual(parseEpisode('TV/Show/Season 03/04 - Name.mp4'), { series: 'Show', season: 3, episode: 4, title: 'Name' })
  assert.deepEqual(parseEpisode('TV/Show/Specials/Show S00E01.mkv')?.season, 0)
  assert.deepEqual(parseEpisode('TV/Show/Show 1x02.mkv'), { series: 'Show', season: 1, episode: 2, title: 'Episode 2' })
  assert.deepEqual(parseEpisode('TV/Great.Show.S02E03.720p.WEB.mkv'), { series: 'Great Show', season: 2, episode: 3, title: 'Episode 3' },
    'a category folder the file name does not start with is not the show')
  assert.deepEqual(parseEpisode('TV/Great Show/Great.Show.S02E03.Pilot.mkv'), { series: 'Great Show', season: 2, episode: 3, title: 'Pilot' })
  assert.equal(parseEpisode('Season 01/x.mkv')?.series, 'Unknown Show', 'a season folder at the root names no show')
  assert.equal(parseEpisode('Movies/Movie (2010)/Movie (2010).mkv'), null)
  assert.equal(parseEpisode('Movies/1920x1080 Demo.mkv'), null, 'a resolution is not 1x02')
})

// ── Sidecars ──

test('lyrics and subtitles are found beside their file', () => {
  const sidecars = ['M/A/01 Song.LRC', 'M/A/02 Other.lrc', 'M/B/01 Song.lrc', 'V/Film.srt', 'V/Film.en.srt', 'V/Film.pt-br.forced.vtt', 'V/Film 2.srt', 'V/cover.jpg']
  assert.equal(lyricsSidecar('M/A/01 Song.mp3', sidecars), 'M/A/01 Song.LRC')
  assert.equal(lyricsSidecar('M/A/03 None.mp3', sidecars), undefined)
  assert.deepEqual(subtitleSidecars('V/Film.mkv', sidecars), [
    { rel: 'V/Film.en.srt', language: 'en' },
    { rel: 'V/Film.pt-br.forced.vtt', language: 'pt-br', forced: true },
    { rel: 'V/Film.srt' },
  ])
})

test('SubRip becomes WebVTT', () => {
  const srt = '\uFEFF1\r\n00:00:00,500 --> 00:00:02,000\r\nHello <i>there</i>\r\n{\\an8}<font color="#fff">Top</font>\r\n\r\n2\r\n0:00:02,5 --> 00:00:04,000 X1:10\r\nSecond\r\n\r\n\r\nbroken block\r\n'
  assert.equal(srtToVtt(srt), 'WEBVTT\n\n1\n00:00:00.500 --> 00:00:02.000\nHello <i>there</i>\nTop\n\n2\n00:00:02.500 --> 00:00:04.000 X1:10\nSecond\n')
  assert.equal(srtToVtt(''), 'WEBVTT\n\n\n')
})

test('an m3u lists library files, relative or absolute, never outside the root', () => {
  const text = [
    '#EXTM3U', '#EXTINF:8,Artist A - First Song',
    'Music/Artist A/01 First Song.mp3',
    '../Music/B.flac',
    '/home/me/Library/Music/C.mp3',
    '/home/me/Other/D.mp3',
    'file:///home/me/Library/Music/E%20F.mp3',
    'https://example.com/stream.mp3',
    '../../escape.mp3',
    '',
  ].join('\r\n')
  assert.deepEqual(parseM3u(text, 'Lists/Road Trip.m3u8', '/home/me/Library'), [
    'Lists/Music/Artist A/01 First Song.mp3', 'Music/B.flac', 'Music/C.mp3', 'Music/E F.mp3',
  ])
  assert.deepEqual(parseM3u('Music\\x.mp3\r\nC:\\Users\\Me\\Lib\\y.mp3\r\nc:/users/me/lib/z.mp3', 'p.m3u', 'C:\\Users\\Me\\Lib'), ['Music/x.mp3', 'y.mp3', 'z.mp3'])
})

// ── User data ──

test('favorites, plays and positions are kept as the server would keep them', () => {
  const now = new Date('2026-10-19T12:00:00Z')
  let ud = applyLocalChange(undefined, { kind: 'play' }, now)
  assert.deepEqual(ud, { Played: true, PlayCount: 1, LastPlayedDate: '2026-10-19T12:00:00.000Z' })
  ud = applyLocalChange(ud, { kind: 'play' }, now)
  assert.equal(ud.PlayCount, 2)
  ud = applyLocalChange(ud, { kind: 'favorite', favorite: true }, now)
  assert.equal(ud.IsFavorite, true)
  ud = applyLocalChange(ud, { kind: 'position', ticks: 5_000_000 }, now)
  assert.equal(ud.PlaybackPositionTicks, 5_000_000)
  ud = applyLocalChange(ud, { kind: 'played', played: false }, now)
  assert.equal(ud.Played, false)
  assert.equal(ud.PlaybackPositionTicks, 0)
  assert.equal(ud.PlayCount, 2, 'unmarking keeps the count, as Jellyfin does')
  assert.deepEqual(parseLocalChange({ kind: 'position', ticks: 1.6 }), { kind: 'position', ticks: 2 })
  assert.equal(parseLocalChange({ kind: 'position', ticks: -1 }), null)
  assert.equal(parseLocalChange({ kind: 'favorite' }), null)
  assert.equal(parseLocalChange('play'), null)
  const id = fileId('a.mp3')
  assert.deepEqual(parseUserData({ [id]: { IsFavorite: true, PlayCount: -2, LastPlayedDate: 'nope' }, '../x': { IsFavorite: true } }), { [id]: { IsFavorite: true } })
  assert.deepEqual(parseLocalPlaylists([{ Id: id, Name: ' Mix ', trackIds: [id, '../bad'], createdAt: '2026-01-01' }, { Id: id, Name: 'dupe' }, { Id: 'x/y', Name: 'bad' }]),
    [{ Id: id, Name: 'Mix', trackIds: [id], createdAt: '2026-01-01T00:00:00.000Z' }])
})

// ── The catalog ──

const ADDED = '2026-10-01T00:00:00.000Z'
const f = (rel: string, probe: object | null, size = 1000): LocalFile => ({ rel, size, added: ADDED, probe: probe as LocalFile['probe'] })

function library(over: Partial<LocalBuildInput> = {}): LocalBuildInput {
  return {
    files: [
      f('Music/Artist A/Album One (2019)/01 First Song.mp3', probeFromMetadata(MM.mp3)),
      f('Music/Artist A/Album One (2019)/02 Second Song.flac', probeFromMetadata(MM.flac)),
      f('Music/Artist B/Second/01 Aac Song.m4a', { title: 'Aac Song', artists: ['Artist B'], album: 'Second', track: 1, audioCodec: 'aac', hasVideo: false, genres: ['Jazz'] }),
      f('Music/Artist B/Second/02 Alac Song.m4a', probeFromMetadata(MM.alac)),
      f('Music/Artist B/Second/03 Audio Only.mp4', probeFromMetadata(MM.audioMp4)),
      f('Music/Compilation/01 One.mp3', { title: 'One', artists: ['X'], album: 'Hits', audioCodec: 'mp3', embeddedArt: true }),
      f('Music/Compilation/02 Two.mp3', { title: 'Two', artists: ['Y'], album: 'Hits', audioCodec: 'mp3' }),
      f('Music/Untagged Artist/Untagged Album/03 Loose.mp3', null),
      f('Movies/Test Movie (2010)/Test Movie (2010).mkv', { hasVideo: true, videoCodec: 'h264', audioCodec: 'aac', durationSec: 6 }),
      f('Movies/Hevc Film (2021)/Hevc Film (2021).mkv', probeFromMetadata(MM.hevcMkv)),
      f('Shows/Test Show/Season 01/Test Show S01E01.mp4', probeFromMetadata(MM.h264Mp4)),
      f('Shows/Test Show/Season 01/Test Show S01E02 The Second.webm', { hasVideo: true, videoCodec: 'vp9', audioCodec: 'opus' }),
    ],
    sidecars: [
      'Music/Artist A/Album One (2019)/cover.jpg', 'Music/Artist A/Album One (2019)/01 First Song.lrc',
      'Movies/Test Movie (2010)/Test Movie (2010).en.srt', 'Movies/Test Movie (2010)/poster.jpg',
      'Shows/Test Show/folder.jpg', 'Road Trip.m3u8',
    ],
    m3u: [{ rel: 'Road Trip.m3u8', entries: ['Music/Artist A/Album One (2019)/01 First Song.mp3', 'music/artist b/second/01 aac song.m4a', 'missing.mp3'] }],
    playlists: [],
    userData: {},
    art: new Set(),
    ...over,
  }
}

test('folder keys: from the name, so a moved folder keeps its ids; two of one name stay two', () => {
  const [a] = rootKeys(['/Users/me/Music/Aiben'])
  assert.equal(rootKeys(['/Volumes/Drive/Aiben/'])[0], a)
  assert.match(a, /^[0-9a-f]{12}$/)
  const [x, y] = rootKeys(['/a/Music', '/b/Music'])
  assert.notEqual(x, y)
  assert.equal(folderName('C:\\Users\\me\\Music\\'), 'Music')
})

test('several folders: each is its own library, named after it, kept apart', () => {
  const [ka, kb] = rootKeys(['/Users/me/Aiben', '/Users/me/WhiteGirl'])
  const song = { title: 'Song', artists: ['Shared Artist'], album: 'Same Album', audioCodec: 'mp3' }
  const cat = buildCatalog({
    files: [
      f(`${ka}/Shared Artist/Same Album/01 Song.mp3`, song),
      f(`${kb}/Shared Artist/Same Album/01 Song.mp3`, song),
      f(`${kb}/Loose.mp3`, null),
      f(`${kb}/Film (2020)/Film (2020).mkv`, probeFromMetadata(MM.hevcMkv)),
    ],
    sidecars: [], m3u: [], playlists: [], userData: {}, art: new Set(),
    roots: [{ key: ka, name: 'Aiben' }, { key: kb, name: 'WhiteGirl' }],
  })
  const q = offlineQuery(parseIndex(JSON.parse(JSON.stringify(cat.index))))
  const views = q.answer('/UserViews').body as { Items: { Id: string, Name: string, CollectionType: string }[] }
  assert.deepEqual(views.Items.map(v => [v.Name, v.CollectionType]), [['Aiben', 'music'], ['WhiteGirl', 'music']])
  const [la, lb] = views.Items.map(v => v.Id)
  const songsIn = (lib: string) => (q.answer('/Items', { ParentId: lib, IncludeItemTypes: 'Audio', Recursive: true }).body as { Items: { Name: string }[] }).Items.map(s => s.Name).sort()
  assert.deepEqual(songsIn(la), ['Song'])
  assert.deepEqual(songsIn(lb), ['Loose', 'Song'])
  const albums = (q.answer('/Items', { IncludeItemTypes: 'MusicAlbum', Recursive: true }).body as { Items: { Name: string }[] }).Items
  assert.equal(albums.filter(a => a.Name === 'Same Album').length, 2, 'one album in two folders is two, as in two Jellyfin libraries')
  const artists = (q.answer('/Artists', { ParentId: la }).body as { Items: { Name: string }[] }).Items.map(a => a.Name)
  assert.deepEqual(artists, ['Shared Artist'])
  const loose = (q.answer('/Items', { IncludeItemTypes: 'Audio', SearchTerm: 'loose' }).body as { Items: { Album: string }[] }).Items[0]
  assert.equal(loose.Album, 'Unknown Album', "a file at a folder's top is not named after its key")
  assert.deepEqual(cat.unplayable.map(u => u.rel), ['WhiteGirl/Film (2020)/Film (2020).mkv'], 'a path shown names its folder, not its key')

  const one = buildCatalog({ files: [f(`${ka}/A/B/01 Song.mp3`, song)], sidecars: [], m3u: [], playlists: [], userData: {}, art: new Set(), roots: [{ key: ka, name: 'Aiben' }] })
  assert.deepEqual(one.index.libraries.map(l => l.Name), ['Music'], 'one folder keeps the plain name')
})

test('a folder becomes the catalog Offline Mode answers from', () => {
  const cat = buildCatalog(library())
  const ids = Object.keys(cat.paths)
  assert.equal(ids.length, 10, 'two files cannot play here')
  assert.deepEqual(cat.unplayable.map(u => u.rel), ['Movies/Hevc Film (2021)/Hevc Film (2021).mkv', 'Music/Artist B/Second/02 Alac Song.m4a'])
  // What reaches the renderer is JSON, validated there like a download catalog.
  const index = parseIndex(JSON.parse(JSON.stringify(cat.index)))
  assert.deepEqual(Object.keys(index.tracks).sort(), ids.sort(), 'nothing is dropped by the renderer\'s validation')
  for (const t of Object.values(index.tracks)) assert.match(t.file!, /^media\/[0-9a-f]{32}\.\w+$/, 'the real path never leaves main')
  const q = offlineQuery(index)

  const songs = q.answer('/Items', { IncludeItemTypes: 'Audio', Recursive: true, SortBy: 'SortName' }).body as { Items: { Name: string }[] }
  assert.deepEqual(songs.Items.map(s => s.Name), ['Aac Song', 'Audio Only', 'First Song', 'Loose', 'One', 'Second Song', 'Two'])

  const albums = q.answer('/Items', { IncludeItemTypes: 'MusicAlbum', Recursive: true }).body as { Items: { Name: string, AlbumArtist: string, ProductionYear?: number, ChildCount: number }[] }
  assert.deepEqual(albums.Items.map(a => [a.Name, a.AlbumArtist, a.ChildCount]), [
    ['Album One', 'Artist A', 2], ['Hits', 'Various Artists', 2], ['Second', 'Artist B', 2], ['Untagged Album', 'Untagged Artist', 1],
  ], 'a compilation is one album; untagged files take their folders')
  assert.equal(albums.Items[0].ProductionYear, 2019)

  const artists = q.answer('/Artists', {}).body as { Items: { Name: string }[] }
  assert.deepEqual(artists.Items.map(a => a.Name).sort(), ['Artist A', 'Artist A feat. C', 'Artist B', 'Untagged Artist', 'Various Artists', 'X', 'Y'])
  const genres = q.answer('/MusicGenres', {}).body as { Items: { Name: string }[] }
  assert.deepEqual(genres.Items.map(g => g.Name), ['Indie', 'Jazz', 'Rock'])

  const albumOne = albumId('Artist A', 'Album One')
  const tracks = q.answer('/Items', { ParentId: albumOne }).body as { Items: { Name: string, IndexNumber: number, NormalizationGain?: number }[] }
  assert.deepEqual(tracks.Items.map(t => [t.IndexNumber, t.Name]), [[1, 'First Song'], [2, 'Second Song']])
  assert.equal(tracks.Items[1].NormalizationGain, -6.5)
  const loose = q.answer('/Items', { IncludeItemTypes: 'Audio', SearchTerm: 'loose' }).body as { Items: { IndexNumber: number, Artists: string[] }[] }
  assert.equal(loose.Items[0].IndexNumber, 3, 'the file name numbers an untagged track')
  assert.deepEqual(loose.Items[0].Artists, ['Untagged Artist'])

  const views = q.answer('/UserViews').body as { Items: { Id: string, CollectionType: string }[] }
  assert.deepEqual(views.Items.map(v => v.Id), [LOCAL_LIBRARIES.music.Id, LOCAL_LIBRARIES.movies.Id, LOCAL_LIBRARIES.tvshows.Id])
  const movies = q.answer('/Items', { ParentId: LOCAL_LIBRARIES.movies.Id, IncludeItemTypes: 'Movie', Recursive: true }).body as { Items: { Name: string, ProductionYear: number, MediaStreams: { Type: string }[] }[] }
  assert.deepEqual(movies.Items.map(m => [m.Name, m.ProductionYear]), [['Test Movie', 2010]])
  assert.deepEqual(movies.Items[0].MediaStreams.map(s => s.Type), ['Video', 'Audio', 'Subtitle'])

  const show = seriesId('Test Show')
  const eps = q.answer(`/Shows/${show}/Episodes`, {}).body as { Items: { Name: string, IndexNumber: number, ParentIndexNumber: number, SeasonId: string }[] }
  assert.deepEqual(eps.Items.map(e => [e.ParentIndexNumber, e.IndexNumber, e.Name]), [[1, 1, 'Episode 1'], [1, 2, 'The Second']])
  assert.equal(eps.Items[0].SeasonId, seasonId('Test Show', 1))
  const seasons = q.answer(`/Shows/${show}/Seasons`, {}).body as { Items: { Name: string }[] }
  assert.deepEqual(seasons.Items.map(s => s.Name), ['Season 1'])
  assert.equal((q.answer(`/Users/${LOCAL_USER_ID}`).body as { Id: string }).Id, LOCAL_USER_ID)

  const playlists = q.answer('/Items', { IncludeItemTypes: 'Playlist', Recursive: true }).body as { Items: { Id: string, Name: string, ChildCount: number }[] }
  assert.deepEqual(playlists.Items.map(p => [p.Name, p.ChildCount]), [['Road Trip', 2]], 'an m3u entry is matched without case; a missing file is skipped')
  const pl = q.answer(`/Playlists/${playlists.Items[0].Id}/Items`, {}).body as { Items: { Name: string }[] }
  assert.deepEqual(pl.Items.map(t => t.Name), ['First Song', 'Aac Song'], 'in the playlist\'s order')

  // Sidecars, kept in main.
  const firstSong = fileId('Music/Artist A/Album One (2019)/01 First Song.mp3')
  assert.equal(cat.lyrics[firstSong], 'Music/Artist A/Album One (2019)/01 First Song.lrc')
  const film = fileId('Movies/Test Movie (2010)/Test Movie (2010).mkv')
  assert.deepEqual(cat.subs[film], [{ index: 2, rel: 'Movies/Test Movie (2010)/Test Movie (2010).en.srt' }])
  assert.deepEqual(index.tracks[film].subs, [{ index: 2, file: `subs/${film}.2.vtt`, language: 'en', title: 'EN', isDefault: false, isForced: false }])
  assert.deepEqual(cat.artSources[albumOne], { file: 'Music/Artist A/Album One (2019)/cover.jpg' })
  assert.deepEqual(cat.artSources[albumId('Various Artists', 'Hits')], { embedded: 'Music/Compilation/01 One.mp3' })
  assert.deepEqual(cat.artSources[film], { file: 'Movies/Test Movie (2010)/poster.jpg' })
  assert.deepEqual(cat.artSources[show], { file: 'Shows/Test Show/folder.jpg' })
})

test('art shows once it is on disk, and user data survives a rescan', () => {
  const albumOne = albumId('Artist A', 'Album One')
  const song = fileId('Music/Artist A/Album One (2019)/01 First Song.mp3')
  const now = new Date('2026-10-19T12:00:00Z')
  const userData = { [song]: applyLocalChange(applyLocalChange(undefined, { kind: 'play' }, now), { kind: 'favorite', favorite: true }, now), [albumOne]: { IsFavorite: true } }
  const index = parseIndex(JSON.parse(JSON.stringify(buildCatalog(library({ art: new Set([albumOne]), userData })).index)))
  const q = offlineQuery(index)
  const album = q.answer(`/Items/${albumOne}`).body as { ImageTags?: { Primary: string }, UserData?: { IsFavorite: boolean } }
  assert.equal(album.ImageTags?.Primary, 'local')
  assert.equal(album.UserData?.IsFavorite, true)
  const favs = q.answer('/Items', { IncludeItemTypes: 'Audio', Filters: 'IsFavorite' }).body as { Items: { Id: string, AlbumPrimaryImageTag?: string }[] }
  assert.deepEqual(favs.Items.map(i => i.Id), [song])
  assert.equal(favs.Items[0].AlbumPrimaryImageTag, 'local')
  const history = q.answer('/Items', { IncludeItemTypes: 'Audio', SortBy: 'DatePlayed', SortOrder: 'Descending', Filters: 'IsPlayed' }).body as { Items: { Id: string }[] }
  assert.deepEqual(history.Items.map(i => i.Id), [song])

  // The renderer patches its copy rather than fetch the whole catalog again.
  setLocalUserData(index, albumOne, { IsFavorite: false })
  setLocalUserData(index, song, applyLocalChange(index.tracks[song].item.UserData, { kind: 'favorite', favorite: false }, now))
  const after = offlineQuery(index)
  assert.equal((after.answer(`/Items/${albumOne}`).body as { UserData: { IsFavorite: boolean } }).UserData.IsFavorite, false)
  assert.deepEqual((after.answer('/Items', { IncludeItemTypes: 'Audio', Filters: 'IsFavorite' }).body as { Items: unknown[] }).Items, [])
  assert.equal(index.tracks[song].item.UserData?.PlayCount, 1, 'the rest of its user data stays')
  const pid = playlistFileId('Road Trip.m3u8')
  setLocalUserData(index, pid, { IsFavorite: true })
  assert.equal(index.collections.find(c => c.item.Id === pid)?.item.UserData?.IsFavorite, true)
})

test('a playlist made in Cascade lists what is still there, in its order', () => {
  const a = fileId('Music/Compilation/02 Two.mp3')
  const b = fileId('Music/Compilation/01 One.mp3')
  const gone = fileId('Music/Deleted.mp3')
  const pid = 'c0ffee00c0ffee00c0ffee00c0ffee00'
  const index = parseIndex(JSON.parse(JSON.stringify(buildCatalog(library({ playlists: [{ Id: pid, Name: 'Mine', trackIds: [a, gone, b, a], createdAt: ADDED }] })).index)))
  const q = offlineQuery(index)
  const items = q.answer(`/Playlists/${pid}/Items`, {}).body as { Items: { Id: string }[] }
  assert.deepEqual(items.Items.map(i => i.Id), [a, b, a], 'a track twice stays twice; a missing one drops out')
})

test('the same files give the same catalog in any order', () => {
  const one = buildCatalog(library())
  const input = library()
  const two = buildCatalog({ ...input, files: [...input.files].reverse(), sidecars: [...input.sidecars].reverse() })
  assert.deepEqual(JSON.parse(JSON.stringify(two)), JSON.parse(JSON.stringify(one)))
})
