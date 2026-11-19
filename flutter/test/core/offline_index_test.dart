// Ported from desktop/test/offline-index.test.ts and offline-index-v2.test.ts.
// Reads the desktop's test/fixtures/offline-index-v1.json (a real version 1 file).
import 'dart:convert';
import 'dart:io';

import 'package:cascade/core/lyrics.dart';
import 'package:cascade/core/offline_index.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> track(String id, [Map<String, dynamic> over = const {}]) => {'Id': id, 'Name': id, 'Type': 'Audio', ...over};
Map<String, dynamic> album(String id) => {'Id': id, 'Name': id, 'Type': 'MusicAlbum'};
Map<String, dynamic> playlist(String id) => {'Id': id, 'Name': id, 'Type': 'Playlist'};
Map<String, dynamic> episode(String id, String season, [String series = 'show']) => {
  'Id': id,
  'Name': id,
  'Type': 'Episode',
  'SeasonId': season,
  'SeriesId': series,
};
Object? roundTrip(OfflineIndex i) => jsonDecode(jsonEncode(i.toJson()));

final v1 = jsonDecode(File('../desktop/test/fixtures/offline-index-v1.json').readAsStringSync());
const track1 = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const track2 = 'b2c3d4e5f60718293a4b5c6d7e8f90a1';
const albumId = '0aa1bb2cc3dd4ee5ff60718293a4b5c6';
final views = <Object?>[
  {'Id': 'libmusic', 'Name': 'Music', 'CollectionType': 'music'},
  {'Id': 'libmovies', 'Name': 'Films', 'CollectionType': 'movies'},
  {'Id': 'libbooks', 'Name': 'Books', 'CollectionType': 'books'},
  {'Id': '../x', 'Name': 'Bad', 'CollectionType': 'music'},
];

void main() {
  test('downloads light the sidebar section of what was downloaded, with how far they have come', () {
    final index = emptyIndex();
    expect(downloadSections(index), isEmpty);
    addCollection(index, album('a'), [track('1'), track('2')]);
    addCollection(index, track('3'), [track('3')]);
    addCollection(index, episode('e1', 's1'), [episode('e1', 's1')]);
    markReady(index, '1', 'media/1.flac', 10);
    markReady(index, '3', 'media/3.flac', 10);
    expect(downloadSections(index), {
      'albums': (done: 1, total: 2),
      'songs': (done: 1, total: 1),
      'shows': (done: 0, total: 1),
    });
    expect(downloadSections(index).containsKey('playlists'), isFalse);
  });

  test('a shared track outlives the first collection removed', () {
    final index = emptyIndex();
    addCollection(index, album('a'), [track('1'), track('2')]);
    addCollection(index, playlist('p'), [track('2'), track('3')]);
    for (final id in ['1', '2', '3']) {
      markReady(index, id, 'media/$id.flac', 10);
    }
    expect(totalBytes(index), 30);
    expect(removeCollection(index, 'a'), ['media/1.flac']);
    expect(readyFile(index, '2'), 'media/2.flac');
    expect(removeCollection(index, 'p'), ['media/2.flac', 'media/3.flac']);
    expect(index.tracks, isEmpty);
  });

  test('removing a collection that is not there deletes nothing', () {
    final index = emptyIndex();
    addCollection(index, album('a'), [track('1')]);
    markReady(index, '1', 'media/1.flac', 5);
    expect(removeCollection(index, 'zzz'), isEmpty);
    expect(readyFile(index, '1'), 'media/1.flac');
  });

  test('asking again keeps what is on disk and puts the collection first', () {
    final index = emptyIndex();
    addCollection(index, album('a'), [track('1')]);
    markReady(index, '1', 'media/1.m4a', 5);
    addCollection(index, album('b'), [track('9')]);
    addCollection(index, album('a'), [track('1'), track('2')]);
    expect(index.collections.map((c) => c.item['Id']), ['a', 'b']);
    expect(readyFile(index, '1'), 'media/1.m4a');
    expect(pendingTrackIds(index), ['9', '2']);
    final p = collectionProgress(index, 'a');
    expect((p.done, p.total), (1, 2));
  });

  test('pending lists a shared track once', () {
    final index = emptyIndex();
    addCollection(index, album('a'), [track('1'), track('2')]);
    addCollection(index, album('b'), [track('2'), track('3')]);
    expect(pendingTrackIds(index), ['1', '2', '3']);
  });

  test('only music is kept, and only ids that can be file names', () {
    final index = emptyIndex();
    addCollection(index, playlist('p'), [
      track('1'),
      {'Id': '2', 'Type': 'Video'},
      track('../x'),
      track('a.b'),
      {'Id': ''},
    ]);
    expect(collectionOf(index, 'p')?.trackIds, ['1']);
  });

  test('reconcile requeues missing files and reports strays', () {
    final index = emptyIndex();
    addCollection(index, album('a'), [track('1'), track('2')]);
    markReady(index, '1', 'media/1.flac', 10);
    markReady(index, '2', 'media/2.flac', 10);
    expect(reconcile(index, ['media/2.flac', 'media/old.flac']), ['media/old.flac']);
    expect(readyFile(index, '1'), isNull);
    expect(pendingTrackIds(index), ['1']);
    expect(totalBytes(index), 10);
    expect(indexedFiles(index), {'media/2.flac'});
  });

  test("collectionBytes counts a collection's ready tracks", () {
    final index = emptyIndex();
    addCollection(index, album('a'), [track('1'), track('2')]);
    markReady(index, '1', 'media/1.flac', 7);
    expect(collectionBytes(index, 'a'), 7);
    expect(collectionBytes(index, 'nope'), 0);
  });

  test('queued plays are capped, newest kept', () {
    final index = emptyIndex();
    for (var i = 0; i < maxQueuedPlays + 3; i++) {
      addPlay(index, {'itemId': 't$i', 'userId': 'u', 'date': '2026-01-01T00:00:00.000Z'});
    }
    expect(index.plays.length, maxQueuedPlays);
    expect(index.plays[0]['itemId'], 't3');
  });

  test('a refused play is dropped only when retrying cannot help', () {
    expect(dropsPlay(404), isTrue);
    expect(dropsPlay(400), isTrue);
    for (final keep in [0, 401, 403, 500, 502, 503]) {
      expect(dropsPlay(keep), isFalse, reason: '$keep');
    }
  });

  test('only plain ids and plain paths are safe', () {
    expect(isSafeId('4489a27fb2adcc74f790cb3d3d977ef7'), isTrue);
    for (final bad in ['', '../x', 'a/b', 'a.b', 'é', 'a' * 65, 5, null]) {
      expect(isSafeId(bad), isFalse, reason: '$bad');
    }
    expect(isSafeMediaPath('media/abc.flac'), isTrue);
    for (final bad in ['/etc/passwd', 'media/', 'media/.hidden', 'media/a/b.flac', 'art/1.jpg', 'media/../x', 'media/a..b', '', 5]) {
      expect(isSafeMediaPath(bad), isFalse, reason: '$bad');
    }
    expect(isSafeArtPath('art/abc123.jpg'), isTrue);
    for (final bad in ['art/../x.jpg', 'art/a.png', 'media/a.jpg', 'art/.jpg']) {
      expect(isSafeArtPath(bad), isFalse, reason: bad);
    }
    expect(isSafeSubtitlePath('subs/abc123.12.vtt'), isTrue);
    for (final bad in ['subs/abc.vtt', 'subs/a/b.1.vtt', 'media/a.1.vtt', 'subs/a.1.srt', '../subs/a.1.vtt', 5]) {
      expect(isSafeSubtitlePath(bad), isFalse, reason: '$bad');
    }
  });

  test('parseIndex drops paths that leave the folder and survives garbage', () {
    final index = emptyIndex();
    addCollection(index, album('a'), [track('1'), track('2')]);
    markReady(index, '1', 'media/../../Documents/x', 1);
    markReady(index, '2', 'media/2.flac', 1);
    final back = parseIndex(roundTrip(index));
    expect(readyFile(back, '1'), isNull);
    expect(back.tracks['1']!.bytes, 0);
    expect(readyFile(back, '2'), 'media/2.flac');
    for (final junk in [
      null,
      'not json',
      5,
      [],
      {'tracks': 'x', 'collections': 3, 'plays': {}},
    ]) {
      expect(parseIndex(junk).json, emptyIndex().json, reason: '$junk');
    }
  });

  test('parseIndex drops tracks no collection holds, bad plays and mismatched ids', () {
    final raw = {
      'tracks': {
        '1': {
          'item': {'Id': '1'},
          'file': 'media/1.flac',
          'bytes': 3,
        },
        '2': {
          'item': {'Id': '2'},
          'file': null,
          'bytes': 0,
        },
        '3': {
          'item': {'Id': 'other'},
          'file': null,
          'bytes': 0,
        },
        '../4': {
          'item': {'Id': '../4'},
          'file': null,
          'bytes': 0,
        },
      },
      'collections': [
        {
          'item': {'Id': 'a'},
          'trackIds': ['1', '3', '../4', 7],
        },
        {
          'item': {'Id': 'a'},
          'trackIds': ['2'],
        },
        {
          'item': {'Id': ''},
          'trackIds': [],
        },
      ],
      'plays': [
        {'itemId': '1', 'userId': 'u-1', 'date': '2026-02-03T04:05:06Z'},
        {'itemId': '../x', 'userId': 'u', 'date': '2026-02-03T04:05:06Z'},
        {'itemId': '1', 'userId': 'u', 'date': 'nope'},
        {'itemId': '1', 'userId': 5, 'date': '2026-02-03T04:05:06Z'},
      ],
    };
    final back = parseIndex(raw);
    expect(back.tracks.keys, ['1']);
    expect(back.collections.map((c) => c.trackIds), [
      ['1'],
    ]);
    expect(back.plays, [
      {'itemId': '1', 'userId': 'u-1', 'date': '2026-02-03T04:05:06.000Z'},
    ]);
  });

  test('slimItem keeps what the screens read, checked for type, and nothing heavy', () {
    final slim = slimItem({
      'Id': '1',
      'Name': 'Song',
      'Type': 'Audio',
      'Album': 'A',
      'AlbumId': 'x',
      'Artists': ['Me', 7],
      'RunTimeTicks': 5,
      'ImageTags': {'Primary': 'tag', 'Backdrop': 'b'},
      'UserData': {'PlayCount': 4, 'Played': true, 'Key': 'k'},
      'MediaStreams': [
        {'Type': 'Audio'},
      ],
      'Path': '/music/a.flac',
      'ProductionYear': 'nineteen',
      'ArtistItems': [
        {'Id': 'r1', 'Name': 'Me'},
        {'Name': 'no id'},
      ],
      'GenreItems': [
        {'Id': 'g1', 'Name': 'Rock'},
      ],
      'MediaSources': [
        {'Id': 's1', 'Bitrate': 900, 'Path': '/x', 'MediaStreams': []},
        {'Id': 's2'},
      ],
    });
    expect(slim, {
      'Id': '1',
      'Name': 'Song',
      'Type': 'Audio',
      'Album': 'A',
      'AlbumId': 'x',
      'Artists': ['Me'],
      'RunTimeTicks': 5,
      'ImageTags': {'Primary': 'tag'},
      'UserData': {'PlayCount': 4, 'Played': true},
      'ArtistItems': [
        {'Id': 'r1', 'Name': 'Me'},
      ],
      'GenreItems': [
        {'Id': 'g1', 'Name': 'Rock'},
      ],
      'MediaSources': [
        {'Id': 's1', 'Bitrate': 900},
      ],
    });
  });

  test("slimItem keeps a video's streams and chapters", () {
    final slim = slimItem({
      'Id': 'm',
      'Type': 'Movie',
      'MediaStreams': [
        {'Type': 'Subtitle', 'Index': 3, 'Codec': 'srt', 'IsExternal': true, 'Path': '/s.srt'},
      ],
      'Chapters': [
        {'StartPositionTicks': 0, 'Name': 'Start', 'ImageTag': 'x'},
        {'Name': 'no start'},
      ],
    });
    expect(slim['MediaStreams'], [
      {'Type': 'Subtitle', 'Codec': 'srt', 'Index': 3, 'IsExternal': true},
    ]);
    expect(slim['Chapters'], [
      {'StartPositionTicks': 0, 'Name': 'Start'},
    ]);
  });

  test('the extension comes from the file name, then the MIME type', () {
    expect(fileExtensionFor('attachment; filename="01 - Song.FLAC"', 'audio/flac'), 'flac');
    expect(fileExtensionFor("attachment; filename*=UTF-8''Song.m4a", null), 'm4a');
    expect(fileExtensionFor(null, 'audio/mpeg'), 'mp3');
    expect(fileExtensionFor('attachment', 'audio/mp4; codecs=mp4a'), 'm4a');
    expect(fileExtensionFor('attachment; filename="x.a b"', 'text/html'), isNull);
    expect(fileExtensionFor(null, null), isNull);
    expect(fileExtensionFor('attachment; filename="no-extension"', 'application/octet-stream'), isNull);
    expect(fileExtensionFor('attachment; filename="login.html"', 'text/html'), isNull);
    expect(fileExtensionFor('attachment; filename="track.ape"', 'application/octet-stream'), 'ape');
  });

  test('only a whole audio response becomes a track', () {
    const d = 'attachment; filename="01 Song.flac"', t = 'audio/flac';
    final refused = judgeDownload(status: 403, expected: null, received: 10, contentDisposition: d, contentType: t);
    expect(refused.ok, isFalse);
    expect(refused.message, contains('admin'));
    expect(judgeDownload(status: 404, expected: 10, received: 10, contentDisposition: d, contentType: t).ok, isFalse);
    expect(judgeDownload(status: 199, expected: 10, received: 10, contentDisposition: d, contentType: t).ok, isFalse);
    final short = judgeDownload(status: 200, expected: 99, received: 10, contentDisposition: d, contentType: t);
    expect(short.ok, isFalse);
    expect(short.message, contains('cut short'));
    expect(judgeDownload(status: 200, expected: 10, received: 11, contentDisposition: d, contentType: t).ok, isFalse);
    expect(judgeDownload(status: 200, expected: null, received: 0, contentDisposition: d, contentType: t).ok, isFalse);
    final html = judgeDownload(status: 200, expected: 10, received: 10, contentType: 'text/html');
    expect(html.ok, isFalse);
    expect(html.message, contains('not a music file'));
    expect(judgeDownload(status: 200, expected: 10, received: 10, contentDisposition: d, contentType: t), (ok: true, ext: 'flac', message: null));
    expect(judgeDownload(status: 206, expected: null, received: 10, contentDisposition: d, contentType: t).ext, 'flac');
  });

  test('parseByteRange: the ranges a media element asks for', () {
    void r(String h, int s, int e) {
      final x = parseByteRange(h, 100) as ByteRange;
      expect((x.start, x.end), (s, e), reason: h);
    }

    r('bytes=0-9', 0, 9);
    r('bytes=90-', 90, 99);
    r('bytes=0-', 0, 99);
    r('bytes=50-5000', 50, 99);
    r('bytes=-10', 90, 99);
    r('bytes=-500', 0, 99);
    r(' bytes=5-5 ', 5, 5);
  });

  test('parseByteRange: nothing usable means the whole file, nothing satisfiable means 416', () {
    for (final none in [null, '', 'bytes=', 'bytes=-', 'items=0-5', 'bytes=0-5,10-15', 'bytes=a-b', 'garbage']) {
      expect(parseByteRange(none, 100), isNull, reason: '$none');
    }
    for (final bad in ['bytes=100-', 'bytes=100-200', 'bytes=10-5', 'bytes=-0']) {
      expect(parseByteRange(bad, 100), 'unsatisfiable', reason: bad);
    }
    expect(parseByteRange('bytes=0-9', 0), 'unsatisfiable');
  });

  test('contentTypeForFile names what a stored file is', () {
    expect(contentTypeForFile('media/x.flac'), 'audio/flac');
    expect(contentTypeForFile('media/x.M4A'), 'audio/mp4');
    expect(contentTypeForFile('art/x.jpg'), 'image/jpeg');
    expect(contentTypeForFile('media/x.zzz'), 'application/octet-stream');
  });

  test('a user id names a folder and can never be a path', () {
    expect(isSafeUserId('4f1c2a9e8b7d4c3e9a1b2c3d4e5f6a7b'), isTrue);
    expect(isSafeUserId('4f1c2a9e-8b7d-4c3e-9a1b-2c3d4e5f6a7b'), isTrue);
    for (final bad in ['', '..', '-', '---', 'a/b', 'a\\b', '.hidden', 'x' * 65, null, 5]) {
      expect(isSafeUserId(bad), isFalse, reason: '$bad');
    }
  });

  // Version 2 ---------------------------------------------------------------

  test('a real version 1 file reads into version 2 with nothing lost', () {
    final index = parseIndex(v1);
    expect(index.version, indexVersion);
    expect(index.tracks.keys.toList()..sort(), [track1, track2]);
    expect(readyFile(index, track1), 'media/$track1.flac');
    expect(index.tracks[track1]!.bytes, 21456789);
    expect(index.tracks[track1]!.item['NormalizationGain'], -6.2);
    expect(collectionOf(index, albumId)?.trackIds, [track1, track2]);
    expect(index.plays.length, 1);
    expect(index.libraries, isEmpty);
    expect(index.user, isNull);
    expect(index.history, isNull);
    expect(parseIndex(roundTrip(index)).json, index.json);
  });

  test('version 1 items fall into the placeholder library until placed', () {
    final index = parseIndex(v1);
    final audio = placeholderLibraries['Audio']!;
    expect(libraryOf(index, track1), audio['Id']);
    expect(librariesInUse(index), [audio]);
    expect(unplacedTrackIds(index), [track1, track2]);

    setLibraries(index, views);
    expect(index.libraries.map((l) => l['Id']), ['libmusic', 'libmovies']);
    assignLibrary(index, [track1], 'libmusic');
    assignLibrary(index, [track2], 'nowhere');
    expect(libraryOf(index, track1), 'libmusic');
    expect(libraryOf(index, track2), audio['Id']);
    expect(librariesInUse(index).map((l) => l['Id']), ['libmusic', audio['Id']]);
    expect(unplacedTrackIds(index), [track2]);

    setLibraries(index, views.where((v) => (v as Map)['Id'] != 'libmusic').toList());
    expect(libraryOf(index, track1), audio['Id']);
  });

  test('each kind has its own placeholder', () {
    final index = emptyIndex();
    addCollection(
      index,
      {'Id': 'm1', 'Type': 'Movie'},
      [
        {'Id': 'm1', 'Type': 'Movie'},
      ],
    );
    addCollection(index, {'Id': 's1', 'Type': 'Season'}, [episode('e1', 's1')]);
    expect(libraryOf(index, 'm1'), placeholderLibraries['Movie']!['Id']);
    expect(libraryOf(index, 'e1'), placeholderLibraries['Episode']!['Id']);
    expect(libraryOf(index, 'nope'), isNull);
  });

  test('a placeholder id stored on a track is not trusted', () {
    final raw = jsonDecode(jsonEncode(v1));
    raw['tracks'][track1]['library'] = placeholderLibraries['Movie']!['Id'];
    expect(parseIndex(raw).tracks[track1]!.library, isNull);
  });

  test('a season keeps its show; removing the last episode of a show forgets both', () {
    final index = emptyIndex();
    final show = {'Id': 'show', 'Name': 'Show', 'Type': 'Series'};
    final s1 = {'Id': 's1', 'Name': 'Season 1', 'Type': 'Season', 'SeriesId': 'show'};
    final s2 = {'Id': 's2', 'Name': 'Season 2', 'Type': 'Season', 'SeriesId': 'show'};
    addCollection(
      index,
      s1,
      [episode('e1', 's1'), episode('e2', 's1')],
      [
        show,
        s1,
        {'Id': 'x', 'Type': 'Folder'},
      ],
    );
    addCollection(index, s2, [episode('e3', 's2')], [show, s2]);
    expect(index.containers.keys.toList()..sort(), ['s1', 's2', 'show']);
    removeCollection(index, 's1');
    expect(index.containers.keys.toList()..sort(), ['s2', 'show']);
    removeCollection(index, 's2');
    expect(index.containers, isEmpty);
  });

  test('a movie is its own collection', () {
    final index = emptyIndex();
    final movie = {'Id': 'm1', 'Name': 'Film', 'Type': 'Movie'};
    addCollection(index, movie, [
      movie,
      {'Id': 'v', 'Type': 'Video'},
    ]);
    expect(collectionOf(index, 'm1')?.trackIds, ['m1']);
  });

  test('subtitles are files: removed with their item, forgotten when missing, strays reported', () {
    final index = emptyIndex();
    addCollection(
      index,
      {'Id': 'm1', 'Type': 'Movie'},
      [
        {'Id': 'm1', 'Type': 'Movie'},
      ],
    );
    markReady(index, 'm1', 'media/m1.mp4', 100);
    setSubtitles(index, 'm1', [
      {'index': 3, 'file': 'subs/m1.3.vtt', 'language': 'eng'},
      {'index': 4, 'file': 'subs/m1.4.vtt'},
      {'index': 4, 'file': 'subs/m1.4.vtt'},
      {'index': 5, 'file': 'subs/../../x.vtt'},
      {'index': -1, 'file': 'subs/m1.1.vtt'},
    ]);
    expect(index.tracks['m1']!.subs!.map((s) => s.index), [3, 4]);
    expect(indexedFiles(index), {'media/m1.mp4', 'subs/m1.3.vtt', 'subs/m1.4.vtt'});
    expect(reconcile(index, ['media/m1.mp4', 'subs/m1.3.vtt', 'subs/old.2.vtt']), ['subs/old.2.vtt']);
    expect(index.tracks['m1']!.subs!.map((s) => s.index), [3]);
    expect(removeCollection(index, 'm1'), ['media/m1.mp4', 'subs/m1.3.vtt']);
  });

  test("SpicyLyrics expire after the plugin's 25 days; other sources never do", () {
    final index = emptyIndex();
    addCollection(index, {'Id': 'a', 'Type': 'MusicAlbum'}, [track('t1'), track('t2')]);
    final saved = DateTime.parse('2026-10-01T00:00:00Z');
    final lines = <Object?>[
      {'Start': 0, 'End': 10, 'Text': 'la', 'Words': null},
      {'Start': 'x', 'Text': 'bad'},
    ];
    setLyrics(index, 't1', saved, source: 'spicy', synced: true, lines: lines);
    setLyrics(index, 't2', saved, source: 'lrclib', synced: true, lines: lines);
    final l = index.tracks['t1']!.lyrics!.lines;
    expect(l.length, 1);
    expect((l[0].start, l[0].end, l[0].text, l[0].words), (0, 10, 'la', null));

    const day = Duration(days: 1);
    final before = saved.add(day * (spicyLyricsDays - 1));
    final after = saved.add(day * spicyLyricsDays);
    expect(lyricsOf(index, 't1', before), isNotNull);
    expect(lyricsOf(index, 't1', after), isNull);
    expect(lyricsOf(index, 't2', saved.add(day * 3650)), isNotNull);
    expect(expiredLyricsTrackIds(index, after), ['t1']);
    dropLyrics(index, 't1');
    expect(expiredLyricsTrackIds(index, after), isEmpty);
    expect(index.tracks['t1']!.lyrics, isNull);
    expect(index.tracks['t2']!.lyrics, isNotNull);
  });

  test('SpicyLyrics with an unreadable expiry are treated as expired, not kept', () {
    final index = emptyIndex();
    addCollection(index, {'Id': 'a', 'Type': 'MusicAlbum'}, [track('t1')]);
    final raw = roundTrip(index) as Map;
    (raw['tracks'] as Map)['t1']['lyrics'] = {
      'source': 'spicy',
      'synced': true,
      'lines': [
        {'Start': 0, 'Text': 'x'},
      ],
      'savedAt': '2026-10-01T00:00:00Z',
      'expiresAt': 'later',
    };
    expect(lyricsOf(parseIndex(raw), 't1', DateTime.parse('2026-10-02T00:00:00Z')), isNull);
  });

  test('segments, explicit, user and history survive a save and are validated', () {
    final index = emptyIndex();
    addCollection(
      index,
      {'Id': 'm1', 'Type': 'Movie'},
      [
        {'Id': 'm1', 'Type': 'Movie'},
      ],
    );
    setSegments(index, 'm1', [
      {'Type': 'Intro', 'StartTicks': 0, 'EndTicks': 900},
      {'Type': 'Outro', 'StartTicks': 50, 'EndTicks': 10},
    ]);
    setExplicit(index, 'm1', true);
    setUser(index, {
      'Id': 'u-1',
      'Name': 'Kai',
      'Policy': {
        'IsAdministrator': false,
        'EnableContentDownloading': true,
        'EnableContentDeletionFromFolders': ['f', 3],
        'Secret': 'x',
      },
    });
    setHistory(index, [
      {
        'Id': 'm1',
        'UserData': {'LastPlayedDate': '2026-10-01T10:00:00Z', 'PlayCount': 2},
      },
      {'Id': '../bad'},
      {'Id': 't9'},
    ], DateTime.parse('2026-10-02T00:00:00Z'));

    final back = parseIndex(roundTrip(index));
    expect(back.tracks['m1']!.segments, [
      {'Type': 'Intro', 'StartTicks': 0, 'EndTicks': 900},
    ]);
    expect(back.tracks['m1']!.explicit, true);
    expect(back.user, {
      'Id': 'u-1',
      'Name': 'Kai',
      'Policy': {
        'IsAdministrator': false,
        'EnableContentDownloading': true,
        'EnableContentDeletionFromFolders': ['f'],
      },
    });
    expect(back.history, {
      'takenAt': '2026-10-02T00:00:00.000Z',
      'entries': [
        {'Id': 'm1', 'LastPlayedDate': '2026-10-01T10:00:00Z', 'PlayCount': 2},
        {'Id': 't9', 'LastPlayedDate': null, 'PlayCount': 0},
      ],
    });
    final bad = roundTrip(index) as Map;
    bad['user'] = {'Id': '../u', 'Name': 'x'};
    expect(parseIndex(bad).user, isNull);
  });

  test('the history snapshot is capped, and keeps safe ids only', () {
    expect(historyEntriesOf(List.generate(maxHistoryEntries + 20, (i) => {'Id': 't$i'})).length, maxHistoryEntries);
    final e = historyEntriesOf([
      {
        'Id': 'abc123',
        'UserData': {'LastPlayedDate': '2026-10-15T20:00:00Z', 'PlayCount': 3},
      },
      {'Id': '../x'},
      {'Id': 'def456'},
    ]);
    expect(e, [
      {'Id': 'abc123', 'LastPlayedDate': '2026-10-15T20:00:00Z', 'PlayCount': 3},
      {'Id': 'def456', 'LastPlayedDate': null, 'PlayCount': 0},
    ]);
  });

  test('a collection of an unknown kind is not read back', () {
    final raw = jsonDecode(jsonEncode(v1));
    (raw['collections'] as List).add({
      'item': {'Id': 'f1', 'Type': 'Folder'},
      'trackIds': [track1],
    });
    expect(collectionOf(parseIndex(raw), 'f1'), isNull);
  });

  test('a refresh fills in what version 1 never kept and keeps what the copy lacks', () {
    final index = parseIndex(v1);
    refreshItems(index, [
      {
        'Id': track1,
        'Name': 'Intro',
        'ArtistItems': [
          {'Id': 'art1', 'Name': 'The Lanterns'},
        ],
        'UserData': {'PlayCount': 3},
      },
      {'Id': 'not-downloaded', 'Name': 'x'},
    ]);
    final item = index.tracks[track1]!.item;
    expect(item['ArtistItems'], [
      {'Id': 'art1', 'Name': 'The Lanterns'},
    ]);
    expect((item['UserData'] as Map)['PlayCount'], 3);
    expect(item['NormalizationGain'], -6.2);
    expect(index.tracks['not-downloaded'], isNull);
  });

  test('SpicyLyrics keep their credit; sources are stored by key and shown by name', () {
    final index = emptyIndex();
    addCollection(index, {'Id': 'a', 'Type': 'MusicAlbum'}, [track('t1')]);
    final credit = {
      'provider': 'Spicy Lyrics',
      'uploader': {'name': 'kai', 'url': 'https://x'},
      'maker': null,
      'extra': 1,
    };
    setLyrics(
      index,
      't1',
      DateTime.now(),
      source: lyricsSourceKey('Spicy Lyrics', true),
      synced: true,
      lines: [
        {'Start': 0, 'End': 1, 'Text': 'la', 'Words': null},
      ],
      credit: credit,
    );
    final back = parseIndex(roundTrip(index));
    final ly = back.tracks['t1']!.lyrics!;
    expect(ly.credit!.provider, 'Spicy Lyrics');
    expect(ly.credit!.uploader, (name: 'kai', url: 'https://x'));
    expect(ly.credit!.maker, isNull);
    expect(ly.source, 'spicy');
    expect(ly.expiresAt, isNotNull);
    expect(lyricsSourceLabel(ly), 'Spicy Lyrics');
    expect(['Kugou', 'LRCLIB (plain)', 'Jellyfin', 'Karaoke', 'Cascade'].map((l) => lyricsSourceKey(l, false)), [
      'kugou',
      'lrclib',
      'jellyfin',
      'cascade',
      'cascade',
    ]);
  });

  test('a queued change shows in the catalog at once, and over a refresh until it is sent', () {
    Map<String, dynamic> ep(String id, [Map<String, dynamic> ud = const {}]) => {'Id': id, 'Name': id, 'Type': 'Episode', 'RunTimeTicks': 1000, 'UserData': ud};
    final index = emptyIndex();
    addCollection(index, ep('e1'), [
      ep('e1', {'PlaybackPositionTicks': 0, 'Played': false}),
    ]);
    addChange(index, {'itemId': 'e1', 'userId': 'u1', 'at': '2026-10-16T10:00:00.000Z', 'kind': 'position', 'ticks': 500});
    expect((index.tracks['e1']!.item['UserData'] as Map)['PlaybackPositionTicks'], 500);
    expect((index.collections[0].item['UserData'] as Map)['PlaybackPositionTicks'], 500);
    refreshUserData(index, [
      ep('e1', {'PlaybackPositionTicks': 0, 'Played': false, 'IsFavorite': true}),
    ]);
    expect((index.tracks['e1']!.item['UserData'] as Map)['PlaybackPositionTicks'], 500);
    expect((index.tracks['e1']!.item['UserData'] as Map)['IsFavorite'], true);
    index.changes = [];
    refreshUserData(index, [
      ep('e1', {'PlaybackPositionTicks': 0}),
    ]);
    expect((index.tracks['e1']!.item['UserData'] as Map)['PlaybackPositionTicks'], 0);
    expect(userDataIds(index), ['e1']);
  });

  test('offline plays sit on top of the snapshot in the catalog', () {
    final index = emptyIndex();
    addCollection(index, {'Id': 'al', 'Name': 'al', 'Type': 'MusicAlbum'}, [track('s1'), track('s2')]);
    final hist = [
      {
        'Id': 's1',
        'UserData': {'LastPlayedDate': '2026-10-15T20:00:00.0000000Z', 'PlayCount': 4},
      },
    ];
    setHistory(index, hist, DateTime.now());
    expect(index.tracks['s1']!.item['UserData'], {'Played': true, 'PlayCount': 4, 'LastPlayedDate': '2026-10-15T20:00:00.0000000Z'});
    addPlay(index, {'itemId': 's2', 'userId': 'u1', 'date': '2026-10-16T09:00:00.000Z'});
    addPlay(index, {'itemId': 's1', 'userId': 'u1', 'date': '2026-10-16T10:00:00.000Z'});
    expect((index.tracks['s1']!.item['UserData'] as Map)['PlayCount'], 5);
    expect((index.tracks['s1']!.item['UserData'] as Map)['LastPlayedDate'], '2026-10-16T10:00:00.000Z');
    setHistory(index, hist, DateTime.now());
    expect((index.tracks['s1']!.item['UserData'] as Map)['PlayCount'], 5);
  });

  test('queued changes and the held flag survive a save, checked like the rest', () {
    Map<String, dynamic> ep(String id) => {'Id': id, 'Name': id, 'Type': 'Episode', 'UserData': {}};
    final index = emptyIndex();
    addCollection(index, ep('e1'), [ep('e1')]);
    addPlay(index, {'itemId': 'e1', 'userId': 'u1', 'date': '2026-10-16T09:00:00.000Z'});
    addChange(index, {'itemId': 'e1', 'userId': 'u1', 'at': '2026-10-16T10:00:00.000Z', 'kind': 'favorite', 'favorite': true, 'was': false});
    index.playsHeld = true;
    final raw = roundTrip(index) as Map;
    (raw['changes'] as List)
      ..add({'itemId': '../x', 'userId': 'u1', 'at': 'x', 'kind': 'position', 'ticks': 1})
      ..add({'itemId': 'e1', 'userId': 'u1', 'at': '2026-10-16T10:00:00Z', 'kind': 'nonsense'});
    final back = parseIndex(raw);
    expect(back.changes, index.changes);
    expect(back.playsHeld, true);
    expect(parseIndex({...raw, 'plays': []}).playsHeld, false);
    expect(parseIndex({'tracks': {}}).changes, isEmpty);
  });

  test('the storage limit', () {
    expect(overStorageLimit(9, 2, 10), isTrue);
    expect(overStorageLimit(8, 2, 10), isFalse);
    expect(overStorageLimit(1e12, 1e12, null), isFalse);
  });

  test('new episodes, follow and watched removal', () {
    final index = emptyIndex();
    final series = {'Id': 'sr', 'Type': 'Series'};
    Map<String, dynamic> ep(String id, {String? created, bool played = false}) => {
      'Id': id,
      'Type': 'Episode',
      'SeriesId': 'sr',
      'DateCreated': ?created,
      'UserData': {'Played': played},
    };
    addCollection(index, series, [ep('e1'), ep('e2')]);
    final now = DateTime.parse('2026-10-10T00:00:00Z');
    setFollow(index, 'sr', true, now);
    expect(collectionOf(index, 'sr')!.follow, '2026-10-10T00:00:00.000Z');
    final fresh = newEpisodes(index, 'sr', [
      ep('e1'),
      ep('e3', created: '2026-10-11T00:00:00Z'),
      ep('e4', created: '2026-10-01T00:00:00Z'),
      ep('e5', created: '2026-10-12T00:00:00Z', played: true),
    ]);
    expect(fresh.map((e) => e['Id']), ['e3']);
    // Watched episodes are removed a day later and remembered by the follow.
    markReady(index, 'e1', 'media/e1.mp4', 1, DateTime.parse('2026-10-01T00:00:00Z'));
    markWatched(index, 'e1', DateTime.parse('2026-10-05T00:00:00Z'));
    expect(watchedToRemove(index, now), ['e1']);
    expect(watchedToRemove(index, DateTime.parse('2026-10-05T12:00:00Z')), isEmpty);
    expect(removeTracks(index, ['e1']), ['media/e1.mp4']);
    expect(collectionOf(index, 'sr')!.skip, ['e1']);
    setFollow(index, 'sr', false, now);
    expect(newEpisodes(index, 'sr', [ep('e3', created: '2026-10-11T00:00:00Z')]), isEmpty);
    setBurnIn(index, 'e2', 4);
    expect(index.tracks['e2']!.burnIn, 4);
    setBurnIn(index, 'e2', null);
    expect(index.tracks['e2']!.burnIn, isNull);
    final groups = placementGroups(index, ['e2']);
    expect(groups.keys, ['sr']);
  });

  test('lyric lines keep background and duet flags through a save', () {
    final index = emptyIndex();
    addCollection(index, {'Id': 'a', 'Type': 'MusicAlbum'}, [track('t1')]);
    setLyrics(
      index,
      't1',
      DateTime.now(),
      source: 'lrclib',
      synced: true,
      lines: [
        LyricLine(0, 10, 'la', [LyricWord(0, 5, 'la')], background: [LyricWord(2, 4, 'oh')], opposite: true),
      ],
    );
    final back = parseIndex(roundTrip(index)).tracks['t1']!.lyrics!.lines.single;
    expect(back.opposite, isTrue);
    expect(back.background!.single.text, 'oh');
    expect(back.words!.single.end, 5);
  });
}
