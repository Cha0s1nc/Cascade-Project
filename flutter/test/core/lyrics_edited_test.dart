// Lyrics made with Cascade Server's editor: the plugin answers them ahead of
// SpicyLyrics (with ttml=true), as the person's own copy or TTML saved for
// everyone. They are drawn like SpicyLyrics but are not theirs: no credit.
import 'dart:convert';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/lyrics_fetch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _song = Song('Song', 'Artist', 'Album', 2020, 200, inRainbows, id: 's1');

final _ttml = {
  'type': 'ttml',
  'source': 'cascade',
  'owner': 'mine',
  'lyrics': {
    'Type': 'Syllable',
    'StartTime': 1.0,
    'EndTime': 2.4,
    'Content': [
      {
        'Type': 'Vocal',
        'OppositeAligned': false,
        'Lead': {
          'StartTime': 1.0,
          'EndTime': 2.4,
          'Syllables': [
            {'Text': 'Hel', 'StartTime': 1.0, 'EndTime': 1.3, 'IsPartOfWord': true},
            {'Text': 'lo', 'StartTime': 1.3, 'EndTime': 1.6, 'IsPartOfWord': false},
            {'Text': 'world', 'StartTime': 1.6, 'EndTime': 2.4, 'IsPartOfWord': false},
          ],
        },
        'Background': [],
      },
    ],
  },
};

LyricsFetcher _fetcher(Map answer, List<Uri> asked) => LyricsFetcher(
  Jellyfin('https://jf.test', 'D', token: 't'),
  client: MockClient((req) async {
    asked.add(req.url);
    if (req.url.path == '/CascadeServer/Info') return http.Response('{"capabilities":["ttml-lyrics"]}', 200);
    if (req.url.path == '/CascadeServer/Lyrics/s1') return http.Response(jsonEncode(answer), 200);
    return http.Response('', 404);
  }),
);

void main() {
  test("the person's own TTML comes first, swells, and is not credited to SpicyLyrics", () async {
    final asked = <Uri>[];
    final l = await _fetcher(_ttml, asked).fetch(_song);
    expect(l?.lines.single.text, 'Hello world');
    expect(l?.source, 'Your lyrics');
    expect(l?.credit, isNull);
    expect(l?.held, isTrue);
    expect(asked.firstWhere((u) => u.path == '/CascadeServer/Lyrics/s1').queryParameters['ttml'], 'true');
  });

  test('TTML saved for everyone, and a word-level copy of their own', () async {
    final everyone = await _fetcher({..._ttml, 'owner': 'everyone'}, []).fetch(_song);
    expect(everyone?.source, 'Cascade');
    final mine = await _fetcher({'type': 'karaoke', 'owner': 'mine', 'lrc': '[00:01.00]<00:01.00>Hi <00:02.00>there'}, []).fetch(_song);
    expect(mine?.source, 'Your lyrics');
    expect(mine?.lines.single.words?.length, 2);
  });
}
