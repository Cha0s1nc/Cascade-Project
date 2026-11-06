import 'dart:convert';

import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/playback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const a = '0123456789abcdef0123456789abcdef', b = '1123456789abcdef0123456789abcdef', c = '2123456789abcdef0123456789abcdef';

  test('the report carries position in ticks, volume 0-100, and the session', () {
    final r = playbackReport(itemId: 'x', positionSec: 12.5, paused: true, volume: 0.7, playSessionId: 'S');
    expect(r['PositionTicks'], 125000000);
    expect(r['VolumeLevel'], 70);
    expect(r['IsPaused'], isTrue);
    expect(r['IsMuted'], isFalse);
    expect(r['PlaySessionId'], 'S');
    expect(r.containsKey('MediaSourceId'), isFalse);
    expect(playbackReport(itemId: 'x', positionSec: -3, paused: false, volume: 0)['PositionTicks'], 0);
  });

  Jellyfin server(Object? Function(http.Request) reply) => Jellyfin(
    'https://jf.test',
    'DEV',
    token: 'T',
    userId: 'U',
    client: MockClient((req) async {
      final body = reply(req);
      return body == null ? http.Response('no', 500) : http.Response(jsonEncode(body), 200);
    }),
  );

  test('resolveStream: direct play gets the original file, with its container and session', () async {
    final s = await resolveStream(
      server(
        (_) => {
          'PlaySessionId': 'P',
          'MediaSources': [
            {'Id': 'M', 'Container': 'flac'},
          ],
        },
      ),
      'item',
      defaultMaxBitrate,
    );
    expect(s.direct, isTrue);
    expect(s.url, 'https://jf.test/Audio/item/stream.flac?static=true&mediaSourceId=M&PlaySessionId=P');
    expect(s.playSessionId, 'P');
  });

  test('resolveStream: a transcode uses the server URL, and failure falls back to universal', () async {
    final t = await resolveStream(
      server(
        (_) => {
          'MediaSources': [
            {'Id': 'M', 'TranscodingUrl': '/Audio/item/main.m3u8?x=1'},
          ],
        },
      ),
      'item',
      128000,
    );
    expect(t.direct, isFalse);
    expect(t.url, 'https://jf.test/Audio/item/main.m3u8?x=1');
    final f = await resolveStream(server((_) => null), 'item', 128000);
    expect(f.url, contains('/Audio/item/universal?'));
    expect(f.url, contains('MaxStreamingBitrate=128000'));
    expect(f.url, isNot(contains('ApiKey')));
  });

  test('normalization: clamped to +12 / -24 dB, unity when missing', () {
    expect(normalizationGainLinear(null), 1);
    expect(normalizationGainLinear(double.nan), 1);
    expect(normalizationGainLinear(34), closeTo(dbToGain(12), 1e-9));
    expect(normalizationGainLinear(-40), closeTo(dbToGain(-24), 1e-9));
    expect(normalizationGainLinear(-6), closeTo(0.501, 1e-3));
  });

  test('EQ: auto preamp leaves headroom for the biggest boost', () {
    expect(autoPreamp([0, 0, 0, 0, 0]), 0);
    expect(autoPreamp([7, 4, 0, -1, -1]), -7);
    expect(autoPreamp([-3, -1, -4, -2, -1]), 0);
  });

  test('EQ: a stored profile is clamped, padded, and on unless off', () {
    final p = normalizeProfile({
      'bands': [30, -30, 'x'],
      'preamp': 99,
    });
    expect(p.bands, [12, -12, 0, 0, 0]);
    expect(p.preamp, 12);
    expect(p.enabled, isTrue);
    expect(normalizeProfile({'enabled': false}).enabled, isFalse);
    expect(normalizeProfile(null).preamp, isNull);
  });

  test('EQ: the mpv filter is shelves around three peaks, with the preamp first', () {
    expect(eqFilter((enabled: true, preamp: null, bands: [0, 0, 0, 0, 0])), '');
    expect(eqFilter((enabled: false, preamp: null, bands: [7, 4, 0, -1, -1])), '');
    expect(
      eqFilter((enabled: true, preamp: null, bands: [7, 4, 0, -1, -1])),
      'lavfi=[volume=-7.0dB,lowshelf=f=60:g=7.0,equalizer=f=250:t=q:w=1.0:g=4.0,equalizer=f=1000:t=q:w=1.0:g=0.0,'
      'equalizer=f=4000:t=q:w=1.0:g=-1.0,highshelf=f=12000:g=-1.0]',
    );
  });

  test('saved queue: round trip, and a vanished current track hands over to the next', () {
    final saved = savedQueueOf([a, b, c], 1, 42.37, const []);
    expect(saved, {
      'ids': [a, b, c],
      'index': 1,
      'positionSec': 42.4,
    });
    final all = restoreQueue(saved, {a: 'A', b: 'B', c: 'C'})!;
    expect(all.queue, ['A', 'B', 'C']);
    expect(all.index, 1);
    expect(all.positionSec, 42.4);
    final gone = restoreQueue(saved, {a: 'A', c: 'C'})!;
    expect(gone.queue, ['A', 'C']);
    expect(gone.index, 1);
    expect(gone.positionSec, 0);
  });

  test('saved queue: untrusted data is ignored, not trusted', () {
    expect(restoreQueue('nope', {a: 'A'}), isNull);
    expect(
      restoreQueue(
        {
          'ids': ['not-an-id', 5],
        },
        {a: 'A'},
      ),
      isNull,
    );
    expect(
      savedQueueIds({
        'ids': [a, a, 'x'],
        'unshuffledIds': [b],
      }),
      [a, b],
    );
    expect(savedQueueOf(const [], 0, 0, const []), isNull);
  });

  test('withStartTicks: sets or replaces StartTimeTicks, and leaves 0 alone', () {
    expect(withStartTicks('https://jf.test/Audio/x/stream.mp3?a=1', 0), 'https://jf.test/Audio/x/stream.mp3?a=1');
    expect(withStartTicks('https://jf.test/Audio/x/stream.mp3?a=1', 12.5), 'https://jf.test/Audio/x/stream.mp3?a=1&StartTimeTicks=125000000');
    expect(withStartTicks('https://jf.test/a?StartTimeTicks=5', 1), 'https://jf.test/a?StartTimeTicks=10000000');
  });

  test('qualityOf: the file, or what the server converts it to', () {
    final flac = {
      'MediaSources': [
        {
          'Container': 'flac',
          'Bitrate': 2304000,
          'MediaStreams': [
            {'Type': 'Audio', 'Codec': 'flac', 'BitDepth': 24, 'SampleRate': 96000},
          ],
        },
      ],
    };
    expect(qualityOf(flac), [('Format', 'FLAC'), ('Bit depth', '24-bit'), ('Sample rate', '96 kHz'), ('Bitrate', '2304 kbps')]);
    expect(qualityOf(flac, converted: true, maxBitrate: 192000), [('Format', 'MP3'), ('Bitrate', '192 kbps'), ('From', 'FLAC')]);
    expect(qualityOf(flac, converted: true), [('Format', 'MP3'), ('Bitrate', '320 kbps'), ('From', 'FLAC')]);
    expect(
      qualityOf({
        'MediaSources': [
          {
            'Container': 'mp3',
            'MediaStreams': [
              {'Type': 'Audio', 'SampleRate': 44100},
            ],
          },
        ],
      }),
      [('Format', 'MP3'), ('Sample rate', '44.1 kHz')],
    );
    expect(qualityOf(null), isEmpty);
  });
}
