// Ported from desktop/test/offline-video.test.ts: the shared outcome cases, the
// profile, the estimate and the truncation check. The catalog's follow and
// remove-watched rules are covered in offline_index_test.dart. The desktop's own
// device profile (profiles/electron.ts) is not ported, so these use a small
// hand-made profile.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cascade/core/offline_index.dart';
import 'package:cascade/core/offline_video.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> device({bool hevc = true}) => {
  'Name': 'Test',
  'DirectPlayProfiles': [
    {'Container': 'mp4,m4v', 'Type': 'Video', 'VideoCodec': hevc ? 'h264,hevc' : 'h264', 'AudioCodec': 'aac'},
    {'Container': 'mkv', 'Type': 'Video', 'VideoCodec': 'h264', 'AudioCodec': 'aac'},
    {'Container': 'mp3', 'Type': 'Audio'},
  ],
  'CodecProfiles': [
    {'Type': 'Video', 'Codec': 'hevc', 'Conditions': []},
    {'Type': 'Audio', 'Codec': 'aac', 'Conditions': []},
  ],
};

ByteReader reader(Uint8List buf) =>
    (offset, length) => buf.sublist(offset.clamp(0, buf.length), (offset + length).clamp(0, buf.length));

void main() {
  final fixture = jsonDecode(File('../shared/fixtures/offline-video.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
  final fmp4 = File('../shared/fixtures/offline-fragmented.mp4').readAsBytesSync();

  for (final c in cases) {
    test('outcome: ${c['name']}', () => expect(downloadOutcome((c['source'] as Map).cast<String, dynamic>()), c['outcome']));
  }

  test('the download profile keeps direct play, adds one progressive MP4 and no bitrate cap', () {
    final p = downloadProfile(device(), 'original', audioCodecs: 'aac', maxAudioChannels: '2');
    expect(p['MaxStreamingBitrate'], downloadMaxBitrate);
    final direct = p['DirectPlayProfiles'] as List;
    expect(direct.every((d) => d['Type'] == 'Video'), isTrue);
    expect(direct.any((d) => d['Container'] == 'mkv'), isTrue);
    expect(p['TranscodingProfiles'], [
      {
        'Type': 'Video',
        'Container': 'mp4',
        'VideoCodec': 'h264,hevc',
        'AudioCodec': 'aac',
        'Protocol': 'http',
        'Context': 'Streaming',
        'MaxAudioChannels': '2',
      },
    ]);
    final codecs = p['CodecProfiles'] as List;
    expect(codecs.any((c) => c['Codec'] == 'hevc'), isTrue);
    expect(codecs.any((c) => c['Type'] == 'Audio'), isFalse);
    expect(codecs.any((c) => (c['Conditions'] as List).any((x) => x['Property'] == 'Height')), isFalse);
    final subs = p['SubtitleProfiles'] as List;
    expect(subs.any((s) => s['Format'] == 'subrip' && s['Method'] == 'External'), isTrue);
    expect(subs.any((s) => s['Format'] == 'pgssub' && s['Method'] == 'Encode'), isTrue);
  });

  test('HEVC is only asked for where the device decodes it', () {
    final p = downloadProfile(device(hevc: false), 'original', audioCodecs: 'aac', maxAudioChannels: '2');
    expect((p['TranscodingProfiles'] as List)[0]['VideoCodec'], 'h264');
  });

  test('a quality below original is a height condition on every codec', () {
    for (final (q, h) in [('1080p', '1080'), ('720p', '720')]) {
      final cap = (downloadProfile(device(hevc: false), q, audioCodecs: 'aac', maxAudioChannels: '2')['CodecProfiles'] as List).last as Map;
      expect(cap['Codec'], isNull);
      expect(cap['Conditions'], [
        {'Condition': 'LessThanEqual', 'Property': 'Height', 'Value': h, 'IsRequired': true},
      ]);
    }
  });

  test('a stored quality reads back, anything else is the platform default', () {
    expect(parseVideoQuality('720p'), '720p');
    expect(parseVideoQuality('4k'), 'original');
    expect(parseVideoQuality(null, '1080p'), '1080p');
  });

  test('a burned-in subtitle goes into the request, none otherwise', () {
    final p = downloadProfile(device(hevc: false), 'original', audioCodecs: 'aac', maxAudioChannels: '2');
    expect(downloadPlaybackInfoBody('u', p, 4)['SubtitleStreamIndex'], 4);
    expect(downloadPlaybackInfoBody('u', p, null).containsKey('SubtitleStreamIndex'), isFalse);
  });

  test('the size estimate: the source size, or the requested bitrates over the runtime', () {
    final remux = cases.firstWhere((c) => c['name'] == 'hevc-mkv-apple');
    expect(estimatedBytes('remux', (remux['source'] as Map).cast<String, dynamic>(), remux['runTimeTicks'] as num), (remux['source'] as Map)['Size']);
    final cap = cases.firstWhere((c) => c['name'] == 'cap720-of-1080');
    expect(estimatedBytes('reencode', (cap['source'] as Map).cast<String, dynamic>(), cap['runTimeTicks'] as num), 3656250000);
    expect(estimatedBytes('reencode', {'TranscodingUrl': '/videos/x/stream.mp4'}, 1), isNull);
    expect(secondsLeft(500, 1000, 100), 5);
    expect(secondsLeft(500, null, 100), isNull);
  });

  test('the end of a fragmented MP4 is its last fragment, from headers only', () {
    final end = fragmentedEndSeconds(reader(fmp4), fmp4.length);
    expect(end, isNotNull);
    expect((end! - 3.0).abs() < 0.05, isTrue, reason: 'got $end');
    expect(isWholeTranscode(end, 30000000), isTrue);
  });

  test('a transcode cut off partway reads short, and is not whole', () {
    final cut = fmp4.sublist(0, 13000);
    final end = fragmentedEndSeconds(reader(cut), cut.length);
    expect(end != null && end < 2.5, isTrue, reason: 'got $end');
    expect(isWholeTranscode(end, 10 * 60 * 10000000), isFalse);
    final bare = fmp4.sublist(0, 3800);
    expect(fragmentedEndSeconds(reader(bare), bare.length), isNull);
    expect(isWholeTranscode(null, 30000000), isFalse);
    expect(isWholeTranscode(null, null), isTrue);
  });

  test('a video download is judged as video', () {
    expect(judgeDownload(status: 200, expected: null, received: 10, contentType: 'video/mp4', video: true), (ok: true, ext: 'mp4', message: null));
    expect(judgeDownload(status: 200, expected: 10, received: 10, contentDisposition: 'attachment; filename="Film.mkv"', video: true).ext, 'mkv');
    expect(judgeDownload(status: 200, expected: 10, received: 10, contentType: 'text/html', video: true).ok, isFalse);
    expect(judgeDownload(status: 200, expected: 10, received: 10, contentType: 'video/mp4').ok, isFalse);
    expect(contentTypeForFile('media/x.mkv'), 'video/x-matroska');
    expect(contentTypeForFile('subs/x.2.vtt'), 'text/vtt');
  });

  test('watched means 90 percent in, as Jellyfin counts it, and outcomes have labels', () {
    expect(isWatchedPosition(90, 100), isTrue);
    expect(isWatchedPosition(89, 100), isFalse);
    expect(isWatchedPosition(90, null), isFalse);
    expect(outcomeLabel('direct'), 'Downloading');
    expect(outcomeLabel('remux'), 'Downloading (repackaged by the server)');
    expect(outcomeLabel('reencode'), 'Converting on the server');
  });

  test('the catalog stores a download outcome and burn-in, and drops nonsense on read', () {
    final index = emptyIndex();
    addCollection(
      index,
      {'Id': 'film', 'Type': 'Movie', 'Name': 'Film'},
      [
        {'Id': 'film', 'Type': 'Movie', 'Name': 'Film'},
      ],
    );
    markReady(index, 'film', 'media/film.mp4', 10, DateTime.parse('2026-10-01T00:00:00Z'));
    setOutcome(index, 'film', 'remux');
    setBurnIn(index, 'film', 3);
    final raw = jsonDecode(jsonEncode(index.toJson())) as Map;
    final back = parseIndex(raw);
    expect(back.tracks['film']!.readyAt, '2026-10-01T00:00:00.000Z');
    expect(back.tracks['film']!.outcome, 'remux');
    expect(back.tracks['film']!.burnIn, 3);
    (raw['tracks'] as Map)['film'].addAll({'outcome': 'magic', 'burnIn': -1, 'watchedAt': 'yesterday'});
    final bad = parseIndex(raw);
    expect(bad.tracks['film']!.outcome, isNull);
    expect(bad.tracks['film']!.burnIn, isNull);
    expect(bad.tracks['film']!.watchedAt, isNull);
  });
}
