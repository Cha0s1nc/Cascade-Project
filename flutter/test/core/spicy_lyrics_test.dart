// Ported from desktop/test/spicy-lyrics.test.ts.
import 'package:cascade/core/spicy_lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> syllableBody() => {
      'Type': 'Syllable', 'id': '1QV6tiMFM6fSOKOGLMHYYg', 'source': 'spicy_lyrics',
      'UploadAttribution': {
        'Uploader': {'id': '1', 'username': 'spikerko', 'url': 'https://spicylyrics.org/uid/1'},
        'Maker': {'id': '2', 'username': 'gc', 'url': 'https://spicylyrics.org/uid/2'},
      },
      'Content': [
        {
          'Type': 'Vocal',
          'Lead': {
            'StartTime': 7.357, 'EndTime': 9.5,
            'Syllables': [
              {'Text': 'Hel', 'StartTime': 7.357, 'EndTime': 7.6, 'IsPartOfWord': true},
              {'Text': 'lo', 'StartTime': 7.6, 'EndTime': 7.9},
              {'Text': 'world', 'StartTime': 8.2, 'EndTime': 9.5},
            ],
          },
          'Background': [
            {'Syllables': [{'Text': 'oh', 'StartTime': 8.5, 'EndTime': 9.0}]}
          ],
        },
      ],
    };

void main() {
  test('syllable sync: seconds become ticks, IsPartOfWord joins, gaps survive', () {
    final out = convertSpicyLyrics({'Body': syllableBody(), 'Status': 200, 'Type': 'object'})!;
    final line = out.lines.first;
    expect(line.start, 73570000);
    expect(line.end, 95000000);
    expect(line.text, 'Hello world');
    expect(line.words!.map((w) => w.text), ['Hel', 'lo ', 'world']);
    expect(line.background!.map((w) => (w.text, w.start)), [('oh', 85000000)]);
    expect(line.words![1].end, 79000000);
    expect(line.words![2].start, 82000000);
  });

  test('also accepts the bare Body', () {
    expect(convertSpicyLyrics(syllableBody())?.lines.length, 1);
  });

  test('a syllable with no time borrows the previous end, and a group with no times at all is dropped', () {
    final out = convertSpicyLyrics({
      'Type': 'Syllable', 'source': 'spicy_lyrics',
      'Content': [
        {'Lead': {'Syllables': [{'Text': 'a', 'StartTime': 1, 'EndTime': 2}, {'Text': 'b'}]}},
        {'Lead': {'Syllables': [{'Text': 'lost'}]}},
      ],
    })!;
    expect(out.lines.length, 1);
    expect(out.lines[0].words![1].start, 20000000);
  });

  test('line sync keeps timed lines and drops untimed ones', () {
    final out = convertSpicyLyrics({
      'Type': 'Line', 'source': 'apple_music',
      'Content': [{'Type': 'Vocal', 'Text': 'first (echo)', 'StartTime': 1.5, 'EndTime': 3}, {'Text': 'no time'}],
    })!;
    expect(out.lines.length, 1);
    expect(out.lines[0].start, 15000000);
    expect(out.lines[0].end, 30000000);
    expect(out.lines[0].text, 'first (echo)');
    expect(out.lines[0].words, isNull);
  });

  test('static sync reads Lines, not Content, and has no times', () {
    final out = convertSpicyLyrics({'Type': 'Static', 'source': 'spotify', 'Lines': [{'Text': 'one'}, {'Text': '  '}, {'Text': 'two'}]})!;
    expect(out.lines.map((l) => (l.start, l.text)), [(null, 'one'), (null, 'two')]);
  });

  test('nothing usable is null, so the waterfall falls through', () {
    for (final junk in [null, 'x', <String, Object?>{}, {'Type': 'Karaoke'}, {'Type': 'Syllable', 'Content': []}, {'Body': {'Type': 'Static', 'Lines': []}}]) {
      expect(convertSpicyLyrics(junk), isNull);
    }
  });

  test('credit: community sync names uploader and maker', () {
    final c = spicyCredit(syllableBody());
    expect(c.provider, 'Spicy Lyrics');
    expect(c.uploader, (name: 'spikerko', url: 'https://spicylyrics.org/uid/1'));
    expect(c.maker, (name: 'gc', url: 'https://spicylyrics.org/uid/2'));
  });

  test('credit: maker absent means no maker, not an empty one', () {
    final body = syllableBody();
    body['UploadAttribution'] = {'Uploader': (body['UploadAttribution'] as Map)['Uploader']};
    expect(spicyCredit(body).maker, isNull);
  });

  test('credit: a commercial source shows only the provider, even if attribution is sent', () {
    final c = spicyCredit({...syllableBody(), 'source': 'apple_music'});
    expect(c.provider, 'Apple Music via Spicy Lyrics');
    expect(c.uploader, isNull);
    expect(c.maker, isNull);
    expect(spicyCredit({'source': 'something-new'}).provider, 'Spicy Lyrics');
  });

  test('credit links are https only', () {
    expect(safeCreditUrl('https://spicylyrics.org/uid/1'), 'https://spicylyrics.org/uid/1');
    for (final bad in ['http://x.org', 'javascript:alert(1)', 'file:///etc/passwd', 'not a url', 42, null]) {
      expect(safeCreditUrl(bad), isNull);
    }
    final c = spicyCredit({'source': 'spicy_lyrics', 'UploadAttribution': {'Uploader': {'username': 'x', 'url': 'javascript:alert(1)'}}});
    expect(c.uploader, (name: 'x', url: null));
  });

  test('fits track: a sync running past the end of the file is another version', () {
    expect(spicyFitsTrack({'Body': {'EndTime': 190.73}}, 186.6), isFalse);
    expect(spicyFitsTrack({'EndTime': 185}, 186.6), isTrue);
    expect(spicyFitsTrack({'EndTime': 187.5}, 186.6), isTrue);
  });

  test('fits track: nothing to judge means it passes', () {
    expect(spicyFitsTrack({'Body': {}}, 186.6), isTrue);
    expect(spicyFitsTrack({'Body': {'EndTime': 999}}, 0), isTrue);
    expect(spicyFitsTrack(null, 186.6), isTrue);
  });

  test('Spotify track ids come out of links, URIs and bare ids, and nothing else does', () {
    const id = '2VOomzT6VavJOGBeySqaMc';
    for (final ok in [id, ' $id ', 'spotify:track:$id', 'https://open.spotify.com/track/$id', 'https://open.spotify.com/track/$id?si=abc123', 'open.spotify.com/intl-de/track/$id', 'https://open.spotify.com/embed/track/$id']) {
      expect(parseSpotifyTrackId(ok), id, reason: ok);
    }
    for (final bad in ['', 'nope', 'https://open.spotify.com/album/$id', 'https://open.spotify.com/playlist/$id', 'https://evil.example/open.spotify.com/track/$id', '${id}x', 'spotify:track:short', null, 42]) {
      expect(parseSpotifyTrackId(bad), isNull, reason: '$bad');
    }
  });

  test('a duet keeps which voice sings each line (OppositeAligned)', () {
    Map<String, Object?> vocal(String text, num t, bool opposite) => {
          'Type': 'Vocal', 'OppositeAligned': opposite,
          'Lead': {'StartTime': t, 'EndTime': t + 1, 'Syllables': [{'Text': text, 'StartTime': t, 'EndTime': t + 1}]},
        };
    final out = convertSpicyLyrics({'Type': 'Syllable', 'source': 'spicy_lyrics', 'Content': [vocal('Tame', 1, false), vocal('Jennie', 3, true)]})!;
    expect(out.lines[0].opposite, isFalse);
    expect(out.lines[1].opposite, isTrue);
    final lineSync = convertSpicyLyrics({
      'Type': 'Line', 'source': 'spicy_lyrics',
      'Content': [{'Text': 'first voice', 'StartTime': 1, 'EndTime': 2, 'OppositeAligned': false}, {'Text': 'second voice', 'StartTime': 3, 'EndTime': 4, 'OppositeAligned': true}],
    })!;
    expect(lineSync.lines.map((l) => l.opposite), [false, true]);
  });

  test("the person's own key is taken, secret or public", () {
    expect(isSpicyKey('sl_sk_abcDEF123456'), isTrue);
    expect(isSpicyKey('sl_pk_abcDEF123_-xyz'), isTrue);
    expect(isSpicyKey('  sl_pk_abcDEF123_-xyz  '), isTrue);
    expect(isSpicyKey('sl_xx_abcDEF123456'), isFalse);
    expect(isSpicyKey('sl_pk_short'), isFalse);
    expect(isSpicyKey('sl_pk_has space inside'), isFalse);
    expect(isSpicyKey(null), isFalse);
  });

  test('answers are kept 25 days (Offline Mode keeps SpicyLyrics the same), and no longer', () {
    expect(spicyCacheMs, 25 * 86400000);
    final now = DateTime.parse('2026-10-19T12:00:00Z').millisecondsSinceEpoch;
    expect(spicyCacheFresh(now - 1000, now), isTrue);
    expect(spicyCacheFresh(now - spicyCacheMs + 1, now), isTrue);
    expect(spicyCacheFresh(now - spicyCacheMs, now), isFalse);
    expect(spicyCacheFresh(now + 60000, now), isFalse);
    expect(spicyCacheFresh('x', now), isFalse);
  });

  test('ListenBrainz is asked as the plugin asks it, and read the same way', () {
    expect(listenBrainzUrl('A & B', '', 'Song/Two'), 'https://labs.api.listenbrainz.org/spotify-id-from-metadata/json?artist_name=A+%26+B&release_name=&track_name=Song%2FTwo');
    const a = '4uLU6hMCjMI75M1A2tKUQC', b = '7GhIk7Il098yCjg4BQjzvb';
    expect(spotifyIdsFromListenBrainz([{'spotify_track_ids': [a, 'nope', b, a]}, {'spotify_track_ids': ['x']}]), [a, b]);
    expect(spotifyIdsFromListenBrainz([]), isEmpty);
    expect(spotifyIdsFromListenBrainz({'error': 'x'}), isEmpty);
    expect(isSpotifyTrackId(a), isTrue);
    expect(isSpotifyTrackId('../etc/passwd/aaaaaaaaaa'), isFalse);
    expect(spicyLyricsUrl(a), 'https://api.spicylyrics.org/v1/lyrics/$a');
  });

  test('a rate limit is waited out, never for good', () {
    final now = DateTime.parse('2026-10-19T12:00:00Z').millisecondsSinceEpoch;
    expect(backoffMs(429, retryAfter: '30', nowMs: now), 30000);
    expect(backoffMs(429, retryAfter: 'Mon, 19 Oct 2026 12:02:00 GMT', nowMs: now), 120000);
    expect(backoffMs(429, resetIn: '12', nowMs: now), 12000);
    expect(backoffMs(429, nowMs: now), 60000);
    expect(backoffMs(503, retryAfter: '5', nowMs: now), 5000);
    expect(backoffMs(404, nowMs: now), 0);
    expect(backoffMs(429, retryAfter: '99999999', nowMs: now), 86400000);
    expect(backoffMs(429, retryAfter: 'Mon, 19 Oct 2026 11:00:00 GMT', nowMs: now), 0);
  });
}
