// Playback rules, ported from the desktop's src/core: reporting
// (playback-reporting.ts), stream negotiation (playback.ts), normalization
// (normalization.ts), the EQ (eq-profile.ts) and the saved queue (queue.ts).
// Pure Dart; engine/player.dart does the playing.
import 'dart:math';

import 'package:cascade/core/jellyfin.dart';

// Reporting -----------------------------------------------------------------

/// How often to check in while playing. Jellyfin's own clients use ~10 s.
const progressInterval = Duration(seconds: 10);

/// The body shared by the start and progress reports. VolumeLevel and
/// IsMuted are what a remote controller binds its volume to.
Map<String, Object> playbackReport({
  required String itemId,
  required double positionSec,
  required bool paused,
  required double volume,
  String? playSessionId,
  String? mediaSourceId,
  String playMethod = 'DirectPlay',
  String mediaType = 'Audio',
}) => {
  'ItemId': itemId,
  'PositionTicks': ticks(positionSec),
  'IsPaused': paused,
  'IsMuted': volume <= 0,
  'VolumeLevel': (volume * 100).round().clamp(0, 100),
  'CanSeek': true,
  'PlayMethod': playMethod,
  'MediaType': mediaType,
  'QueueableMediaTypes': [mediaType],
  'PlaySessionId': ?playSessionId,
  'MediaSourceId': ?mediaSourceId,
};

int ticks(double sec) => max(0, (sec * 1e7).round());

// Streams -------------------------------------------------------------------

/// The server only transcodes to certain bitrates, so quality is a list.
const qualitySteps = [
  (bitrate: 140000000, label: 'Original'),
  (bitrate: 320000, label: '320 kbps'),
  (bitrate: 192000, label: '192 kbps'),
  (bitrate: 128000, label: '128 kbps'),
  (bitrate: 96000, label: '96 kbps'),
];
const defaultMaxBitrate = 140000000;

/// What this client can play, for PlaybackInfo. mpv decodes nearly every
/// audio format, so any container direct plays and the server only
/// transcodes to fit a bitrate cap. To a plain MP3 stream, not the desktop's
/// AAC over HLS: mpv failed to recognize the HLS stream Jellyfin 12 sent
/// ("Failed to recognize file format"), and a progressive file also plays on
/// a deck like any other.
Map<String, Object> mpvProfile(int maxBitrate) => {
  'Name': 'Cascade Flutter',
  'MaxStreamingBitrate': maxBitrate,
  'MusicStreamingTranscodingBitrate': min(maxBitrate, 320000),
  'DirectPlayProfiles': [
    {'Type': 'Audio'},
  ],
  'TranscodingProfiles': [
    {'Container': 'mp3', 'Type': 'Audio', 'AudioCodec': 'mp3', 'Protocol': 'http', 'Context': 'Streaming', 'MaxAudioChannels': '2'},
  ],
  'ContainerProfiles': const [],
  'CodecProfiles': const [],
  'SubtitleProfiles': const [],
};

typedef ResolvedStream = ({String url, String? playSessionId, String? mediaSourceId, bool direct, String? liveStreamId});

/// Ask the server how to play [itemId]. Never throws: on any failure it falls
/// back to the universal URL, so playback degrades instead of dying.
Future<ResolvedStream> resolveStream(Jellyfin jf, String itemId, int maxBitrate) async {
  try {
    final info = await jf.post(
      '/Items/$itemId/PlaybackInfo',
      {'UserId': jf.userId, 'MaxStreamingBitrate': maxBitrate, 'DeviceProfile': mpvProfile(maxBitrate), 'AutoOpenLiveStream': true},
      {'UserId': jf.userId},
    );
    final sources = (info as Map)['MediaSources'] as List?;
    if (sources == null || sources.isEmpty) throw StateError('PlaybackInfo gave no media source');
    final source = sources.first as Map;
    final session = info['PlaySessionId'] as String?;
    final sourceId = source['Id'] as String?;
    final transcode = source['TranscodingUrl'] as String?;
    if (transcode != null) return (url: '${jf.server}$transcode', playSessionId: session, mediaSourceId: sourceId, direct: false, liveStreamId: null);
    // The container extension matters: without it some servers re-probe the
    // file on every request.
    final container = (source['Container'] as String?)?.split(',').first;
    final q = {'static': 'true', 'mediaSourceId': ?sourceId, 'PlaySessionId': ?session};
    final url = Uri.parse('${jf.server}/Audio/$itemId/stream${container == null ? '' : '.$container'}').replace(queryParameters: q);
    return (url: '$url', playSessionId: session, mediaSourceId: sourceId, direct: true, liveStreamId: null);
  } catch (_) {
    return (url: universalStreamUrl(jf, itemId, maxBitrate), playSessionId: null, mediaSourceId: null, direct: false, liveStreamId: null);
  }
}

/// The fallback that needs no negotiation. No ApiKey: the token rides in the
/// Authorization header, which Jellyfin 12 requires.
String universalStreamUrl(Jellyfin jf, String itemId, int maxBitrate) =>
    '${jf.server}/Audio/$itemId/universal?UserId=${jf.userId}&DeviceId=${jf.deviceId}'
    '&Container=opus,mp3,aac,flac,wav,ogg&TranscodingContainer=mp3&AudioCodec=mp3&MaxStreamingBitrate=$maxBitrate';

/// The song's quality for Now Playing, as (label, value) pairs: what is in
/// the file, or what the server converts it to when the stream is not the
/// file itself (an MP3 at the streaming cap, at most 320 kbps).
List<(String, String)> qualityOf(Map? item, {bool converted = false, int maxBitrate = defaultMaxBitrate}) {
  final ms = (item?['MediaSources'] as List?)?.firstOrNull as Map?;
  if (ms == null) return const [];
  final a = ((ms['MediaStreams'] as List?) ?? const []).whereType<Map>().where((s) => s['Type'] == 'Audio').firstOrNull;
  final codec = (a?['Codec'] as String? ?? (ms['Container'] as String?)?.split(',').first ?? '').toUpperCase();
  if (converted) return [('Format', 'MP3'), ('Bitrate', '${min(maxBitrate, 320000) ~/ 1000} kbps'), if (codec.isNotEmpty) ('From', codec)];
  final depth = a?['BitDepth'] as num?, rate = a?['SampleRate'] as num?, bits = (a?['BitRate'] ?? ms['Bitrate']) as num?;
  return [
    if (codec.isNotEmpty) ('Format', codec),
    if (depth != null && depth > 0) ('Bit depth', '$depth-bit'),
    if (rate != null && rate > 0) ('Sample rate', '${(rate / 1000).toStringAsFixed(rate % 1000 == 0 ? 0 : 1)} kHz'),
    if (bits != null && bits > 0) ('Bitrate', '${(bits / 1000).round()} kbps'),
  ];
}

// Normalization ---------------------------------------------------------------

/// A whisper-quiet album scanned at +34 dB would be a ~50x boost; past
/// +12 dB a normal mix clips, so a boost is capped there.
const normalizationMaxBoostDb = 12.0;

/// Server data crossing a trust boundary: a wild value is clamped too.
const normalizationMaxCutDb = 24.0;

double dbToGain(double db) => pow(10, db / 20).toDouble();

/// Linear gain for Jellyfin's NormalizationGain (dB); 1 when missing or bad.
double normalizationGainLinear(Object? db) => db is num && db.isFinite ? dbToGain(db.toDouble().clamp(-normalizationMaxCutDb, normalizationMaxBoostDb)) : 1;

// EQ -------------------------------------------------------------------------

const eqBands = [60, 250, 1000, 4000, 12000];
const eqGainLimit = 12.0;

/// The desktop's peaking width: ~1.4 octaves at Q 1.
const eqFilterQ = 1.0;

const Map<String, List<double>> eqPresets = {
  'Flat': [0.0, 0, 0, 0, 0],
  'Bass Boost': [7.0, 4, 0, -1, -1],
  'Vocal': [-3.0, -1, 4, 3, -1],
  'Treble': [-2.0, -1, 0, 4, 6],
  'Loudness': [6.0, 2, -2, 2, 6],
};

typedef EqProfile = ({bool enabled, double? preamp, List<double> bands});

double clampGain(double n) => n.clamp(-eqGainLimit, eqGainLimit);

/// Headroom for the loudest boost, so boosting never clips.
double autoPreamp(List<double> bands) {
  final maxBoost = bands.fold(0.0, (m, b) => b.isFinite ? max(m, b) : m);
  return maxBoost == 0 ? 0 : -maxBoost;
}

/// A stored profile made safe: five clamped bands, preamp null for "auto",
/// on unless explicitly off.
EqProfile normalizeProfile(Object? raw) {
  final r = raw is Map ? raw : const {};
  final rawBands = r['bands'] is List ? r['bands'] as List : const [];
  return (
    enabled: r['enabled'] != false,
    preamp: r['preamp'] is num && (r['preamp'] as num).isFinite ? clampGain((r['preamp'] as num).toDouble()) : null,
    bands: [
      for (var i = 0; i < eqBands.length; i++)
        i < rawBands.length && rawBands[i] is num && (rawBands[i] as num).isFinite ? clampGain((rawBands[i] as num).toDouble()) : 0,
    ],
  );
}

Map<String, Object?> profileJson(EqProfile p) => {'enabled': p.enabled, 'preamp': p.preamp, 'bands': p.bands};

/// The profile as an mpv audio filter: the desktop's Web Audio graph (a low
/// shelf, three peaks, a high shelf) as lavfi filters, with the preamp as a
/// volume stage. Empty when it would do nothing.
String eqFilter(EqProfile p) {
  if (!p.enabled || p.bands.every((b) => b == 0)) return '';
  final pre = p.preamp ?? autoPreamp(p.bands);
  String band(int i) {
    final f = eqBands[i], g = p.bands[i];
    if (i == 0) return 'lowshelf=f=$f:g=$g';
    if (i == eqBands.length - 1) return 'highshelf=f=$f:g=$g';
    return 'equalizer=f=$f:t=q:w=$eqFilterQ:g=$g';
  }

  return 'lavfi=[${[if (pre != 0) 'volume=${pre}dB', for (var i = 0; i < eqBands.length; i++) band(i)].join(',')}]';
}

// The saved queue --------------------------------------------------------------

const savedQueueMax = 2000;

/// What to store for "play where I left off": ids, where, and the order before
/// a shuffle. Past the cap, a window that holds the current track. Null for an
/// empty queue.
Map<String, Object>? savedQueueOf(List<String> ids, int index, double positionSec, List<String> unshuffled) {
  if (index < 0 || index >= ids.length) return null;
  final start = ids.length > savedQueueMax ? max(0, min(index - 100, ids.length - savedQueueMax)) : 0;
  return {
    'ids': ids.sublist(start, min(ids.length, start + savedQueueMax)),
    'index': index - start,
    'positionSec': max(0, (positionSec * 10).round() / 10),
    if (unshuffled.isNotEmpty) 'unshuffledIds': unshuffled.take(savedQueueMax).toList(),
  };
}

final _idPattern = RegExp(r'^[0-9a-f-]{32,36}$', caseSensitive: false);
List<String> _idList(Object? v) => v is List ? v.whereType<String>().where(_idPattern.hasMatch).take(savedQueueMax).toList() : const [];

/// Every id a stored queue needs fetched. Stored data is untrusted.
List<String> savedQueueIds(Object? saved) => saved is Map ? {..._idList(saved['ids']), ..._idList(saved['unshuffledIds'])}.toList() : const [];

/// A stored queue rebuilt from freshly fetched items (any order). If the
/// current track is gone, the next one still there becomes current, from 0.
({List<T> queue, int index, double positionSec, List<T> unshuffled})? restoreQueue<T>(Object? saved, Map<String, T> byId) {
  if (saved is! Map) return null;
  final ids = _idList(saved['ids']);
  final queue = [for (final id in ids) ?byId[id]];
  if (queue.isEmpty) return null;
  final savedIndex = saved['index'] is int ? (saved['index'] as int).clamp(0, ids.length - 1) : 0;
  final pos = saved['positionSec'] is num && (saved['positionSec'] as num).isFinite ? max(0.0, (saved['positionSec'] as num).toDouble()) : 0.0;
  final stillThere = byId.containsKey(ids[savedIndex]);
  final before = ids.take(savedIndex).where(byId.containsKey).length;
  return (
    queue: queue,
    index: min(before, queue.length - 1),
    positionSec: stillThere ? pos : 0,
    unshuffled: [for (final id in _idList(saved['unshuffledIds'])) ?byId[id]],
  );
}

/// Tell the server to stop converting for a play session. A skipped transcode
/// otherwise keeps ffmpeg encoding a file nobody hears. Best effort.
Future<void> stopActiveEncoding(Jellyfin jf, String? playSessionId) async {
  if (playSessionId == null) return;
  await jf.del('/Videos/ActiveEncodings', {'deviceId': jf.deviceId, 'playSessionId': playSessionId});
}

/// A converted stream cannot be seeked, so it starts where asked instead: the
/// server begins converting at StartTimeTicks. Reuses the stream already
/// negotiated, so a seek costs no extra round trip.
String withStartTicks(String url, double sec) {
  final t = ticks(sec);
  if (t <= 0) return url;
  final u = Uri.parse(url);
  return '${u.replace(queryParameters: {...u.queryParameters, 'StartTimeTicks': '$t'})}';
}

// Radio (the desktop's radio.ts) ------------------------------------------------

/// A Live TV channel's stream. PlaybackInfo opens a live stream on the
/// server (a tuner, or a remote stream), which [closeRadioStream] must close.
/// Throws when the server gives nothing to play: a channel has no fallback.
Future<ResolvedStream> resolveRadioStream(Jellyfin jf, String channelId, int maxBitrate) async {
  final info = await jf.post(
    '/Items/$channelId/PlaybackInfo',
    {'UserId': jf.userId, 'MaxStreamingBitrate': maxBitrate, 'DeviceProfile': mpvProfile(maxBitrate), 'AutoOpenLiveStream': true},
    {'UserId': jf.userId},
  );
  final sources = (info as Map)['MediaSources'] as List?;
  if (sources == null || sources.isEmpty) throw StateError('PlaybackInfo gave no media source for this channel');
  final source = sources.first as Map;
  final session = info['PlaySessionId'] as String?;
  final sourceId = source['Id'] as String?, live = source['LiveStreamId'] as String?;
  final container = (source['Container'] as String?)?.split(',').first;
  final q = {'mediaSourceId': ?sourceId, 'LiveStreamId': ?live, 'PlaySessionId': ?session};
  final url = Uri.parse('${jf.server}/Audio/$channelId/stream${container == null ? '' : '.$container'}').replace(queryParameters: q.isEmpty ? null : q);
  return (url: '$url', playSessionId: session, mediaSourceId: sourceId, direct: true, liveStreamId: live);
}

/// Close what [resolveRadioStream] opened, or the tuner stays busy. Best effort.
Future<void> closeRadioStream(Jellyfin jf, String? liveStreamId) async {
  if (liveStreamId == null) return;
  try {
    await jf.post('/LiveStreams/Close', null, {'liveStreamId': liveStreamId});
  } catch (_) {}
}
