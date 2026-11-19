// Downloads can be stopped and taken back: removing one still coming in stops
// its transfer and leaves no file, and removing an album keeps the songs a
// downloaded playlist still holds.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/downloads.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/offline_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const id = '0123456789abcdef0123456789abcdef';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('cascade-dl'));
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> media() => [for (final f in Directory('${dir.path}/media').listSync()) f.uri.pathSegments.last];

  test('cancelling a download partway stops it and leaves no file', () async {
    final body = StreamController<List<int>>();
    final d = Downloads(
      dir: dir,
      client: MockClient.streaming((req, _) async {
        if (req.url.path.endsWith('/Download')) return http.StreamedResponse(body.stream, 200, contentLength: 100);
        return http.StreamedResponse(const Stream.empty(), 404);
      }),
    );
    await d.load();
    final jf = Jellyfin(
      'https://jf.test',
      'D',
      token: 't',
      userId: 'u',
      client: MockClient((req) async {
        if (req.url.path == '/Items') {
          return http.Response(jsonEncode({'Items': [{'Id': id, 'Name': 'Song', 'Type': 'Audio', 'MediaSources': [{'Container': 'flac'}]}]}), 200);
        }
        return http.Response('[]', 200);
      }),
    );
    await d.add(jf, [Song('Song', 'A', 'B', 2020, 100, artFor(id), id: id)]);
    body.add(List.filled(10, 1));
    for (var i = 0; i < 50 && d.current == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(d.current, id, reason: 'coming in');
    await d.cancelAll();
    body.add(List.filled(10, 2));
    await body.close();
    for (var i = 0; i < 100 && d.current != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(d.current, isNull, reason: 'the loop stopped');
    expect(d.has(id) || d.waiting(id), isFalse);
    expect(media(), isEmpty, reason: 'no part file, no finished file');
  });

  test('removing an album keeps its songs a downloaded playlist still holds', () async {
    final d = Downloads(dir: dir, client: MockClient((_) async => http.Response('', 404)));
    await d.load();
    Map<String, dynamic> it(String id, String type) => {'Id': id, 'Name': id, 'Type': type};
    addCollection(d.index, it('album', 'MusicAlbum'), [it('s1', 'Audio'), it('s2', 'Audio')]);
    addCollection(d.index, it('list', 'Playlist'), [it('s2', 'Audio')]);
    for (final s in ['s1', 's2']) {
      File('${dir.path}/media/$s.flac').writeAsStringSync('x');
      markReady(d.index, s, 'media/$s.flac', 1);
    }
    expect(d.downloadOf('album'), (done: 2, total: 2));
    await d.removeCollections(['album']);
    expect(d.downloadOf('album'), isNull);
    expect(d.has('s1'), isFalse);
    expect(d.has('s2'), isTrue, reason: 'still in the playlist');
    expect(media(), ['s2.flac']);
  });
}
