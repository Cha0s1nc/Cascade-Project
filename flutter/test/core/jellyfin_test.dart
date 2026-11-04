// Ported from desktop/test/jellyfin.test.ts and permissions.test.ts: the same
// cases, so the two clients agree.
import 'dart:convert';

import 'package:cascade/core/jellyfin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<Uri> calls;

  /// A client whose server answers with [reply] (null: a 500).
  Jellyfin client(Object? Function(Uri url) reply, {List<String>? libraries}) {
    calls = [];
    return Jellyfin(
      'https://jf.test',
      'DEV',
      token: 'TOK',
      userId: 'U',
      client: MockClient((req) async {
        calls.add(req.url);
        final body = reply(req.url);
        return body == null ? http.Response('boom', 500) : http.Response(jsonEncode(body), 200);
      }),
    )..libraryIds = libraries;
  }

  Map<String, Object> items(List<String> ids) => {
    'Items': [
      for (final id in ids) {'Id': id},
    ],
    'TotalRecordCount': ids.length,
  };
  List<String?> ids(List<Map> list) => [for (final i in list) i['Id'] as String?];

  test('the token rides in the Authorization header', () {
    expect(client((_) => null).headers['Authorization'], contains('Token="TOK"'));
    expect(client((_) => null).headers['Authorization'], contains('Client="Cascade Flutter"'));
  });

  test('getMerged: with no libraries selected it is a plain get', () async {
    final res = await client((_) => items(['a', 'b'])).getMerged('/Items');
    expect(calls, hasLength(1));
    expect(calls.first.queryParameters.containsKey('ParentId'), isFalse);
    expect(ids(res), ['a', 'b']);
  });

  test('getMerged: queries each library and dedupes by Id', () async {
    final res = await client(
      (u) => u.queryParameters['ParentId'] == 'L1' ? items(['a', 'shared']) : items(['shared', 'b']),
      libraries: ['L1', 'L2'],
    ).getMerged('/Items');
    expect(calls, hasLength(2));
    expect(ids(res), ['a', 'shared', 'b']);
  });

  test('getMerged: one failing library does not sink the others', () async {
    final res = await client((u) => u.queryParameters['ParentId'] == 'BAD' ? null : items(['a']), libraries: ['L1', 'BAD']).getMerged('/Items');
    expect(ids(res), ['a']);
  });

  test('getGrouped: one group per library, in order; a failing one is empty', () async {
    final groups = await client(
      (u) => switch (u.queryParameters['ParentId']) {
        'L1' => items(['a', 'shared']),
        'L2' => items(['shared', 'b']),
        _ => null,
      },
      libraries: ['L1', 'L2', 'BAD'],
    ).getGrouped('/Items');
    expect([for (final g in groups) g.libraryId], ['L1', 'L2', 'BAD']);
    expect(ids(groups[0].items), ['a', 'shared']);
    expect(ids(groups[1].items), ['shared', 'b']);
    expect(groups[2].items, isEmpty);
  });

  test('getAllPaged: keeps paging past the first page', () async {
    const all = ['a', 'b', 'c', 'd', 'e'];
    final res = await client((u) {
      final start = int.parse(u.queryParameters['StartIndex']!);
      return {
        'Items': [
          for (final id in all.skip(start).take(2)) {'Id': id},
        ],
        'TotalRecordCount': all.length,
      };
    }).getAllPaged('/Items', {'Limit': 2});
    expect(calls, hasLength(3));
    expect(ids(res), all);
  });

  test('getAllPaged: stops when the first page is everything', () async {
    await client((_) => items(['a', 'b'])).getAllPaged('/Items', {'Limit': 500});
    expect(calls, hasLength(1));
  });

  test('getMerged: asks for bitrates only for songs across libraries, and strips them after', () async {
    var n = 0;
    final c = client(
      (_) => {
        'Items': [
          {
            'Id': '${n++}',
            'Type': 'Audio',
            'Name': 'x$n',
            'MediaSources': [
              {'Bitrate': 1},
            ],
          },
        ],
      },
      libraries: ['L1', 'L2'],
    );
    final res = await c.getMerged('/Items', {'IncludeItemTypes': 'Audio', 'Fields': 'AlbumId'});
    expect(calls.first.queryParameters['Fields'], 'AlbumId,MediaSources');
    expect(res.every((i) => !i.containsKey('MediaSources')), isTrue);

    calls.clear();
    await c.getMerged('/Items', {'IncludeItemTypes': 'MusicAlbum'});
    expect(calls.first.queryParameters['Fields'], 'ChildCount');

    calls.clear();
    final own = await c.getMerged('/Items', {'IncludeItemTypes': 'Audio', 'Fields': 'MediaSources'});
    expect(own.any((i) => i.containsKey('MediaSources')), isTrue);

    final one = client((_) => items(['a']), libraries: ['L1']);
    await one.getMerged('/Items', {'IncludeItemTypes': 'Audio'});
    expect(calls.first.queryParameters.containsKey('Fields'), isFalse);
  });

  test('post: an empty 204 comes back as null; a JSON body parsed', () async {
    final empty = Jellyfin('https://jf.test', 'D', client: MockClient((_) async => http.Response('', 204)));
    expect(await empty.post('/Sessions/Capabilities/Full', {}), isNull);
    final json = Jellyfin('https://jf.test', 'D', client: MockClient((_) async => http.Response('{"Id":"x"}', 200)));
    expect(await json.post('/Items', {}), {'Id': 'x'});
  });

  test('a refused write throws with the server message and reports the status', () async {
    int? seen;
    final c = Jellyfin('https://jf.test', 'D', client: MockClient((_) async => http.Response('Access denied', 403, reasonPhrase: 'Forbidden')))
      ..onFailure = (s) => seen = s;
    await expectLater(
      c.post('/Items/x', {}),
      throwsA(isA<JellyfinError>().having((e) => e.status, 'status', 403).having((e) => e.message, 'message', 'Access denied')),
    );
    expect(seen, 403);
    expect(await c.del('/Items/x'), isFalse);
  });

  test('errorMessage: an HTML error page gives just the status', () {
    expect(errorMessage(http.Response('<html>Bad gateway</html>', 502, reasonPhrase: 'Bad Gateway')), '502 Bad Gateway');
    expect(errorMessage(http.Response('', 404, reasonPhrase: 'Not Found')), '404 Not Found');
  });

  Item song(String id, String name, String artist, int sec, [int? kbps]) => {
    'Id': id,
    'Name': name,
    'Type': 'Audio',
    'Artists': [artist],
    'RunTimeTicks': sec * 10000000,
    if (kbps != null)
      'MediaSources': [
        {'Bitrate': kbps * 1000},
      ],
  };

  test('dedupe: the same song in two libraries appears once, first library kept', () {
    final libA = [song('a1', 'Mr. Brightside', 'The Killers', 222), song('a2', 'Sober', 'Letdown.', 216)];
    final libB = [
      song('b1', 'mr brightside', 'the killers', 223),
      song('b2', 'Mr. Brightside (Live)', 'The Killers', 240),
      song('b3', 'Sober', 'Letdown.', 300),
    ];
    expect(ids(dedupe([libA, libB])), ['a1', 'a2', 'b2', 'b3']);
  });

  test('dedupe: copies inside one library are left alone', () {
    expect(
      dedupe([
        [song('1', 'Home', 'Phillip Phillips', 209), song('2', 'Home', 'Phillip Phillips', 209)],
      ]),
      hasLength(2),
    );
  });

  test('dedupe: albums match on name and album artist across libraries', () {
    Item album(String id, String name, String artist) => {'Id': id, 'Name': name, 'Type': 'MusicAlbum', 'AlbumArtist': artist};
    final res = dedupe([
      [album('a', 'A Fever You Can’t Sweat Out', 'Panic! At The Disco')],
      [album('b', "A Fever You Can't Sweat Out", 'Panic! at the Disco'), album('c', 'Pretty. Odd.', 'Panic! At The Disco')],
    ]);
    expect(ids(res), ['a', 'c']);
  });

  test('dedupe: other types only dedupe by Id', () {
    Item pl(String id) => {'Id': id, 'Name': 'Road trip', 'Type': 'Playlist'};
    expect(
      dedupe([
        [pl('1')],
        [pl('2'), pl('1')],
      ]),
      hasLength(2),
    );
  });

  test("dedupe: the higher-bitrate copy wins, in the first copy's place", () {
    final res = dedupe([
      [song('mp3', 'Idol', 'YOASOBI', 213, 320), song('x', 'Other', 'Someone', 100)],
      [song('flac', 'Idol', 'YOASOBI', 213, 1100)],
      [song('aac', 'Idol', 'YOASOBI', 213, 256)],
    ]);
    expect(ids(res), ['flac', 'x']);
  });

  test('dedupe: of two copies of an album, the one with more tracks wins', () {
    Item album(String id, int n) => {'Id': id, 'Name': 'Night Drive', 'Type': 'MusicAlbum', 'AlbumArtist': 'Aurora Lane', 'ChildCount': n};
    expect(
      ids(
        dedupe([
          [album('partial', 1)],
          [album('whole', 3)],
        ]),
      ),
      ['whole'],
    );
    expect(
      ids(
        dedupe([
          [album('whole', 3)],
          [album('partial', 1)],
        ]),
      ),
      ['whole'],
    );
  });

  test('dedupe: an artist found in two libraries appears once', () {
    Item artist(String id, String name) => {'Id': id, 'Name': name, 'Type': 'MusicArtist'};
    final res = dedupe([
      [artist('42585974', 'Aurora Lane')],
      [artist('98eed3bf', 'aurora lane'), artist('d15fdbee', 'Aurora Lane; Kite Echo')],
    ]);
    expect(ids(res), ['42585974', 'd15fdbee']);
  });

  Item lib(String id, [String? type]) => {'Id': id, 'CollectionType': ?type};

  test('splitVideoLibraryIds: sorts by CollectionType, drops ids no longer there', () {
    final s = splitVideoLibraryIds([lib('m1', 'movies'), lib('m2', 'movies'), lib('t1', 'tvshows')], ['m1', 't1', 'm2', 'gone']);
    expect(s.movieIds, ['m1', 'm2']);
    expect(s.showIds, ['t1']);
  });

  test('effectiveLibraryIds: a sole library defaults on, can be turned off and stay off', () {
    expect(effectiveLibraryIds([lib('m1')], null), ['m1']);
    expect(effectiveLibraryIds([lib('m1')], []), isEmpty);
    expect(effectiveLibraryIds([lib('m1')], ['m1']), ['m1']);
    expect(effectiveLibraryIds([lib('m1')], ['something-else']), isEmpty);
  });

  test('effectiveLibraryIds: several never chosen select nothing; saved ids win minus vanished ones', () {
    expect(effectiveLibraryIds([lib('m1'), lib('m2')], null), isEmpty);
    expect(effectiveLibraryIds([lib('m1'), lib('m2'), lib('m3')], ['m1', 'm3']), ['m1', 'm3']);
    expect(effectiveLibraryIds([lib('m1')], ['m1', 'gone']), ['m1']);
    expect(effectiveLibraryIds([], ['m1']), isEmpty);
  });

  Item ep(String id, String? series) => {'Id': id, 'Type': 'Episode', 'SeriesId': ?series};
  Item movie(String id) => {'Id': id, 'Type': 'Movie'};

  test('onePerSeries: one episode per series, movies and series-less episodes always kept', () {
    expect(ids(onePerSeries([ep('e4', 's1'), ep('e3', 's1'), ep('e1', 's1')])), ['e4']);
    expect(ids(onePerSeries([movie('m1'), ep('e1', 's1'), movie('m2'), ep('e2', 's1')])), ['m1', 'e1', 'm2']);
    expect(ids(onePerSeries([ep('a2', 'A'), ep('b2', 'B'), ep('a1', 'A'), ep('b1', 'B')])), ['a2', 'b2']);
    expect(ids(onePerSeries([ep('e1', ''), ep('e2', null), ep('e3', '')])), ['e1', 'e2', 'e3']);
  });

  test('canDeleteMedia: admin, deletion everywhere, or on one library', () {
    expect(canDeleteMedia(null), isFalse);
    expect(canDeleteMedia({}), isFalse);
    expect(canDeleteMedia({'IsAdministrator': true}), isTrue);
    expect(canDeleteMedia({'EnableContentDeletion': true}), isTrue);
    expect(
      canDeleteMedia({
        'EnableContentDeletionFromFolders': ['L1'],
      }),
      isTrue,
    );
    expect(canDeleteMedia({'EnableContentDeletionFromFolders': []}), isFalse);
  });

  test('canDownload: on unless the policy turns it off', () {
    expect(canDownload(null), isTrue);
    expect(canDownload({'EnableContentDownloading': false}), isFalse);
    expect(canDownload({'EnableContentDownloading': true}), isTrue);
  });
}
