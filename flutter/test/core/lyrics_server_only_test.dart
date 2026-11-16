// Server-only lyrics: only the Cascade Server plugin is asked, never a
// lyrics site, and a forced kind means exactly that kind of file.
import 'dart:convert';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/lyrics_fetch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _song = Song('Song', 'Artist', 'Album', 2020, 200, inRainbows, id: 's1');

({LyricsFetcher f, List<Uri> asked}) _fetcher({bool plugin = true, String type = 'karaoke'}) {
  final asked = <Uri>[];
  final client = MockClient((req) async {
    asked.add(req.url);
    if (req.url.host != 'jf.test') return http.Response('{}', 200);
    if (req.url.path == '/CascadeServer/Info') return plugin ? http.Response('{"capabilities":[]}', 200) : http.Response('', 404);
    if (req.url.path == '/CascadeLyrics/Info') return http.Response('', 404);
    if (req.url.path == '/CascadeServer/Lyrics/s1') return http.Response(jsonEncode({'type': type, 'lrc': '[00:01.00]Hello\n[00:03.00]World'}), 200);
    return http.Response('', 404);
  });
  return (f: LyricsFetcher(Jellyfin('https://jf.test', 'D', token: 't'), client: client)..serverOnly = true, asked: asked);
}

void main() {
  test('only the server is asked, and its file is used', () async {
    final t = _fetcher();
    final l = await t.f.fetch(_song);
    expect(l?.lines.map((x) => x.text), ['Hello', 'World']);
    expect(l?.source, 'Cascade');
    expect(t.asked.every((u) => u.host == 'jf.test'), isTrue, reason: '${t.asked}');
  });

  test('a forced kind takes only that kind of file', () async {
    expect(await _fetcher(type: 'synced').f.fetch(_song, forced: 'Karaoke'), isNull);
    expect((await _fetcher(type: 'synced').f.fetch(_song, forced: 'Synced'))?.source, 'Synced');
  });

  test('without the plugin there are no lyrics, and still no lyrics site is asked', () async {
    final t = _fetcher(plugin: false);
    expect(await t.f.fetch(_song), isNull);
    expect(t.asked.every((u) => u.host == 'jf.test'), isTrue, reason: '${t.asked}');
  });
}
