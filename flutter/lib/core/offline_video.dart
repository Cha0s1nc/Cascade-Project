// Video downloads: which file to ask the server for, what it will do to make
// it, and whether what arrived is the whole film. Pure. Ported from
// desktop/src/core/offline-video.ts; the outcome cases are shared in
// shared/fixtures/offline-video.json.
//
// A progressive transcode in Streaming context is a fragmented MP4, kept as it
// arrives. It has no Content-Length, so length cannot tell a finished transcode
// from one that died partway; the last fragment's time can (fragmentedEndSeconds).
// Device profiles and download sources are the JSON Maps Jellyfin takes and gives.
import 'dart:math';
import 'dart:typed_data';

const videoQualities = ['original', '1080p', '720p'];

/// A stored setting, read back: anything unknown is [fallback].
String parseVideoQuality(Object? stored, [String fallback = 'original']) => videoQualities.contains(stored) ? stored as String : fallback;

const _qualityHeight = {'original': null, '1080p': 1080, '720p': 720};

/// No bitrate limit of its own: a download is not a stream. Jellyfin reads it as an int32.
const downloadMaxBitrate = 400000000;

const _textSubtitles = ['vtt', 'webvtt', 'srt', 'subrip', 'ass', 'ssa', 'ttml', 'mov_text'];
const _imageSubtitles = ['pgssub', 'dvdsub', 'dvbsub'];

/// Text subtitles come as external WebVTT; picture subtitles only exist burned in (a re-encode).
final downloadSubtitleProfiles = [
  for (final f in _textSubtitles) {'Format': f, 'Method': 'External'},
  for (final f in _imageSubtitles) {'Format': f, 'Method': 'Encode'},
];

/// The profile a download is negotiated with: the device's own video direct-play entries, and one progressive MP4 the server makes with the video copied where it can be. The quality is a height condition with no codec. [device] is a device profile Map.
Map<String, Object?> downloadProfile(Map<String, dynamic> device, String quality, {required String audioCodecs, required String maxAudioChannels}) {
  final direct = [
    for (final p in (device['DirectPlayProfiles'] as List? ?? const []).whereType<Map>())
      if (p['Type'] == 'Video') p,
  ];
  final codecs = {for (final p in direct) ...((p['VideoCodec'] as String? ?? '').split(',').map((c) => c.trim().toLowerCase()))};
  // Only what an MP4 can carry and this device decodes. HEVC only where the device claims it.
  final videoCodec = ['h264', 'hevc'].where((c) => c == 'h264' || codecs.contains(c)).join(',');
  final transcode = {
    'Type': 'Video',
    'Container': 'mp4',
    'VideoCodec': videoCodec,
    'AudioCodec': audioCodecs,
    'Protocol': 'http',
    'Context': 'Streaming',
    'MaxAudioChannels': maxAudioChannels,
  };
  final height = _qualityHeight[quality];
  final cap = height == null
      ? <Object?>[]
      : [
          {
            'Type': 'Video',
            'Conditions': [
              {'Condition': 'LessThanEqual', 'Property': 'Height', 'Value': '$height', 'IsRequired': true},
            ],
          },
        ];
  return {
    'Name': '${device['Name'] ?? 'Cascade'} Download',
    'MaxStreamingBitrate': downloadMaxBitrate,
    'DirectPlayProfiles': direct,
    'TranscodingProfiles': [transcode],
    'ContainerProfiles': [],
    'CodecProfiles': [...(device['CodecProfiles'] as List? ?? const []).whereType<Map>().where((p) => p['Type'] == 'Video'), ...cap],
    'SubtitleProfiles': downloadSubtitleProfiles,
  };
}

/// The PlaybackInfo request body for a download. [burnIn] is a picture subtitle's stream index, which the server can only burn in.
Map<String, Object?> downloadPlaybackInfoBody(String userId, Map<String, Object?> profile, int? burnIn) => {
  'UserId': userId,
  'MaxStreamingBitrate': profile['MaxStreamingBitrate'],
  'DeviceProfile': profile,
  'AutoOpenLiveStream': false,
  'SubtitleStreamIndex': ?burnIn,
};

/// A download source: a media source Map with TranscodingUrl, MediaStreams, Size.
typedef DownloadSource = Map<String, dynamic>;

Map<String, String> _queryOf(String url) {
  final parts = url.split('?');
  final q = <String, String>{};
  if (parts.length > 1) {
    try {
      Uri.splitQueryString(parts[1]).forEach((k, v) => q[k.toLowerCase()] = v);
    } catch (_) {}
  }
  return q;
}

/// What the server will do for this download: 'direct' (the original), 'remux' (the server's MP4 with the video copied) or 'reencode' (the video itself is encoded again). Compares the source with what the transcoding URL allows, as the server's CanStreamCopyVideo does.
String downloadOutcome(DownloadSource source) {
  final url = source['TranscodingUrl'];
  if (url is! String || url.isEmpty) return 'direct';
  final q = _queryOf(url);
  if ((q['subtitlemethod'] ?? '').toLowerCase() == 'encode') return 'reencode';
  Map? video;
  for (final s in (source['MediaStreams'] as List? ?? const []).whereType<Map>()) {
    if (s['Type'] == 'Video') {
      video = s;
      break;
    }
  }
  if (video == null) return 'remux';
  final codec = ((video['Codec'] as String?) ?? '').toLowerCase();
  final allowed = (q['videocodec'] ?? '').toLowerCase().split(',').map((c) => c.trim()).toList();
  if (!allowed.contains(codec)) return 'reencode';
  bool over(String key, Object? value) {
    final limit = double.tryParse((q[key] ?? '').trim()) ?? ((q[key] ?? 'x').trim().isEmpty && q.containsKey(key) ? 0.0 : double.nan);
    return q.containsKey(key) && limit.isFinite && value is num && value > limit;
  }

  if (over('maxheight', video['Height']) || over('maxwidth', video['Width']) || over('videobitrate', video['BitRate'])) return 'reencode';
  if (over('$codec-videobitdepth', video['BitDepth'])) return 'reencode';
  final profiles = q['$codec-profile'];
  if (profiles != null &&
      profiles.isNotEmpty &&
      video['Profile'] is String &&
      !profiles.toLowerCase().split(RegExp(r'[,|]')).contains((video['Profile'] as String).toLowerCase())) {
    return 'reencode';
  }
  return 'remux';
}

/// Played this far, a video counts as watched: Jellyfin's own default (MaxResumePct 90).
const watchedRatio = 0.9;

/// Whether [positionTicks] is far enough in to count as watched.
bool isWatchedPosition(num positionTicks, num? runTimeTicks) => runTimeTicks != null && runTimeTicks > 0 && positionTicks >= runTimeTicks * watchedRatio;

/// What the person is told a download is doing.
String outcomeLabel(String outcome) =>
    outcome == 'reencode' ? 'Converting on the server' : (outcome == 'remux' ? 'Downloading (repackaged by the server)' : 'Downloading');

/// Roughly how big the file will be: the source's size for the original or a remux, the requested bitrates times the runtime for a re-encode. Null when there is nothing to go on.
int? estimatedBytes(String outcome, DownloadSource source, num? runTimeTicks) {
  if (outcome != 'reencode') {
    final s = source['Size'];
    return s is num && s > 0 ? s.toInt() : null;
  }
  final url = source['TranscodingUrl'];
  if (url is! String || url.isEmpty || runTimeTicks == null || runTimeTicks == 0) return null;
  final q = _queryOf(url);
  final bps = (double.tryParse(q['videobitrate'] ?? '') ?? 0) + (double.tryParse(q['audiobitrate'] ?? '') ?? 0);
  return bps > 0 ? (bps / 8 * runTimeTicks / 10000000).round() : null;
}

/// Seconds left at the current rate, or null when it cannot be guessed.
int? secondsLeft(num received, num? estimate, num bytesPerSecond) {
  if (estimate == null || estimate == 0 || bytesPerSecond <= 0 || received >= estimate) return null;
  return ((estimate - received) / bytesPerSecond).round();
}

// Is the whole film there? --------------------------------------------------

/// Reads [length] bytes at [offset] (fewer at the end of the file).
typedef ByteReader = Uint8List Function(int offset, int length);

int _u32(Uint8List b, int i) => (b[i] << 24) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];
int _u64(Uint8List b, int i) => _u32(b, i) * 4294967296 + _u32(b, i + 4);
String _type(Uint8List b, int i) => String.fromCharCodes([b[i], b[i + 1], b[i + 2], b[i + 3]]);

/// Boxes directly inside b[start, end): (type, payload start, box end).
List<(String, int, int)> _children(Uint8List b, int start, int end) {
  final out = <(String, int, int)>[];
  var i = start;
  while (i + 8 <= end) {
    var size = _u32(b, i);
    var header = 8;
    if (size == 1 && i + 16 <= end) {
      size = _u64(b, i + 8);
      header = 16;
    }
    if (size < header || i + size > end) break;
    out.add((_type(b, i + 4), i + header, i + size));
    i += size;
  }
  return out;
}

/// Every whole top-level box's (type, offset, size), reading headers only. A box that runs past the end of the file was cut off and ends the list.
List<(String, int, int)> _topLevel(ByteReader read, int fileSize) {
  final out = <(String, int, int)>[];
  var i = 0;
  while (i + 8 <= fileSize) {
    final h = read(i, 16);
    if (h.length < 8) break;
    var size = _u32(h, 0);
    if (size == 1 && h.length >= 16) {
      size = _u64(h, 8);
    } else if (size == 0) {
      size = fileSize - i;
    }
    if (size < 8 || i + size > fileSize) break;
    out.add((_type(h, 4), i, size));
    i += size;
  }
  return out;
}

/// Where a fragmented MP4's last fragment ends, in seconds, or null when the file is not one (no moov with timescales, or no fragment). A transcode cut off partway reads as that much shorter. Only box headers and the small moov and moof boxes are read, never the media.
double? fragmentedEndSeconds(ByteReader read, int fileSize) {
  final boxes = _topLevel(read, fileSize);
  (String, int, int)? moovBox;
  for (final b in boxes) {
    if (b.$1 == 'moov') {
      moovBox = b;
      break;
    }
  }
  // A fragment counts once its samples (the mdat after it) are all there.
  final moofs = [
    for (var i = 0; i < boxes.length; i++)
      if (boxes[i].$1 == 'moof' && i + 1 < boxes.length && boxes[i + 1].$1 == 'mdat') boxes[i],
  ];
  if (moovBox == null || moofs.isEmpty) return null;
  final moov = read(moovBox.$2, moovBox.$3);
  final timescale = <int, int>{};
  final defaultDuration = <int, int>{};
  for (final (t, s, e) in _children(moov, 8, moov.length)) {
    if (t == 'trak') {
      var id = 0, scale = 0;
      for (final (tt, ts, te) in _children(moov, s, e)) {
        if (tt == 'tkhd') id = moov[ts] == 1 ? _u32(moov, ts + 20) : _u32(moov, ts + 12);
        if (tt == 'mdia') {
          for (final (mt, ms, _) in _children(moov, ts, te)) {
            if (mt == 'mdhd') scale = moov[ms] == 1 ? _u32(moov, ms + 20) : _u32(moov, ms + 12);
          }
        }
      }
      if (id != 0 && scale != 0) timescale[id] = scale;
    }
    if (t == 'mvex') {
      for (final (xt, xs, _) in _children(moov, s, e)) {
        if (xt == 'trex') defaultDuration[_u32(moov, xs + 4)] = _u32(moov, xs + 12);
      }
    }
  }
  final (_, off, size) = moofs.last;
  final moof = read(off, size);
  double? end;
  for (final (t, s, e) in _children(moof, 8, moof.length)) {
    if (t != 'traf') continue;
    var track = 0, base = 0, dflt = 0, total = 0;
    for (final (ft, fs, _) in _children(moof, s, e)) {
      if (ft == 'tfhd') {
        final flags = _u32(moof, fs) & 0xffffff;
        track = _u32(moof, fs + 4);
        dflt = defaultDuration[track] ?? 0;
        var p = fs + 8;
        if (flags & 0x01 != 0) p += 8;
        if (flags & 0x02 != 0) p += 4;
        if (flags & 0x08 != 0) dflt = _u32(moof, p);
      } else if (ft == 'tfdt') {
        base = moof[fs] == 1 ? _u64(moof, fs + 4) : _u32(moof, fs + 4);
      } else if (ft == 'trun') {
        final flags = _u32(moof, fs) & 0xffffff;
        final count = _u32(moof, fs + 4);
        var p = fs + 8 + (flags & 0x01 != 0 ? 4 : 0) + (flags & 0x04 != 0 ? 4 : 0);
        final per = [0x100, 0x200, 0x400, 0x800].where((f) => flags & f != 0).length * 4;
        if (flags & 0x100 != 0) {
          for (var i = 0; i < count; i++, p += per) {
            total += _u32(moof, p);
          }
        } else {
          total += count * dflt;
        }
      }
    }
    final scale = timescale[track];
    if (scale != null) end = max(end ?? 0, (base + total) / scale);
  }
  return end;
}

/// How far short of the runtime a transcode may end and still be whole (seconds).
const truncationToleranceSeconds = 15;

/// Whether a transcode that ended at [endSeconds] holds the whole item. An unknown runtime is not judged; no fragment at all is a stream cut off before its first one.
bool isWholeTranscode(double? endSeconds, num? runTimeTicks) {
  if (runTimeTicks == null || runTimeTicks == 0) return true;
  if (endSeconds == null) return false;
  return endSeconds >= runTimeTicks / 10000000 - truncationToleranceSeconds;
}
