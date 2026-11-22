// SpicyLyrics API response to Cascade's lyric lines, the credit the API's
// terms require, and the pure parts of asking it directly (key and id checks,
// URLs, cache freshness, backoff). Ported from desktop/src/core/spicy-lyrics.ts.
// Every API time is seconds as a float; Cascade keeps ticks (1 s = 10,000,000).
import 'dart:io' show HttpDate;
import 'dart:math';

import 'lyrics.dart';

const _ticksPerSec = 10000000;

/// A person credited on a community sync.
typedef SpicyContributor = ({String name, String? url});

/// What the lyrics UI must show next to SpicyLyrics lyrics. [provider] always; uploader and maker only for a community sync.
typedef SpicyCredit = ({String provider, SpicyContributor? uploader, SpicyContributor? maker});

/// Converted lines plus their credit.
typedef SpicyConversion = ({List<LyricLine> lines, SpicyCredit credit});

const _providerLabel = {
  'spicy_lyrics': 'Spicy Lyrics',
  'apple_music': 'Apple Music via Spicy Lyrics',
  'spotify': 'Spotify via Spicy Lyrics',
  'unknown': 'Spicy Lyrics',
};

List _arr(Object? v) => v is List ? v : const [];
String _str(Object? v) => v is String ? v : '';

int? _ticks(Object? sec) => sec is num && sec.isFinite && sec >= 0 ? (sec * _ticksPerSec).round() : null;

/// Only an https link is ever handed to the OS: it came from a third party.
String? safeCreditUrl(Object? url) {
  if (url is! String) return null;
  final u = Uri.tryParse(url);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty ? u.toString() : null;
}

SpicyContributor? _contributor(Object? v) {
  if (v is! Map) return null;
  final name = _str(v['username']).trim();
  return name.isEmpty ? null : (name: name, url: safeCreditUrl(v['url']));
}

/// The credit for a response body. Uploader and maker are read only for a community sync.
SpicyCredit spicyCredit(Object? body) {
  final b = body is Map ? body : const {};
  final source = _providerLabel.containsKey(_str(b['source'])) ? _str(b['source']) : 'unknown';
  final attr = source == 'spicy_lyrics' && b['UploadAttribution'] is Map ? b['UploadAttribution'] as Map : null;
  return (
    provider: _providerLabel[source]!,
    uploader: attr == null ? null : _contributor(attr['Uploader']),
    maker: attr == null ? null : _contributor(attr['Maker']),
  );
}

List<LyricWord> _groupWords(Object? group) {
  final out = <LyricWord>[];
  final syls = group is Map ? _arr(group['Syllables']) : const [];
  int? prevEnd = group is Map ? _ticks(group['StartTime']) : null;
  for (var i = 0; i < syls.length; i++) {
    final s = syls[i];
    if (s is! Map) continue;
    final text = _str(s['Text']);
    if (text.isEmpty) continue;
    final start = _ticks(s['StartTime']) ?? prevEnd;
    if (start == null) continue;
    final end = _ticks(s['EndTime']);
    final last = i == syls.length - 1;
    out.add(LyricWord(start, end, text + (s['IsPartOfWord'] == true || last ? '' : ' ')));
    prevEnd = end ?? start;
  }
  return out;
}

List<LyricLine> _syllableLines(List content) {
  final lines = <LyricLine>[];
  for (final c in content) {
    if (c is! Map) continue;
    final words = _groupWords(c['Lead']);
    final background = <LyricWord>[];
    for (final bg in _arr(c['Background'])) {
      final bw = _groupWords(bg);
      if (bw.isEmpty) continue;
      if (background.isNotEmpty) background.last.text = '${background.last.text.trimRight()} ';
      background.addAll(bw);
    }
    if (words.isEmpty) continue;
    final lead = c['Lead'] is Map ? c['Lead'] as Map : const {};
    final start = _ticks(lead['StartTime']) ?? words.first.start;
    final end = _ticks(lead['EndTime']) ?? words.last.end;
    final text = words.map((w) => w.text).join().trim();
    if (text.isNotEmpty) {
      lines.add(LyricLine(start, end, text, words, background: background.isEmpty ? null : background, opposite: c['OppositeAligned'] == true));
    }
  }
  return lines;
}

List<LyricLine> _lineLines(List content) {
  final lines = <LyricLine>[];
  for (final c in content) {
    if (c is! Map) continue;
    final text = _str(c['Text']).trim();
    final start = _ticks(c['StartTime']);
    if (text.isNotEmpty && start != null) lines.add(LyricLine(start, _ticks(c['EndTime']), text, null, opposite: c['OppositeAligned'] == true));
  }
  return lines;
}

/// Untimed lines have a null start, the same shape LRCLIB's plain lyrics use.
List<LyricLine> _staticLines(List list) => [
  for (final l in list)
    if (l is Map && _str(l['Text']).trim().isNotEmpty) LyricLine(null, null, _str(l['Text']).trim(), null),
];

/// How far past the end of the file a sync may run before it is another version (seconds).
const spicyEndToleranceSec = 1.5;

/// Whether a sync can belong to the file being played: a sync whose EndTime runs past the file's length is for a longer version. Passes when there is nothing to judge.
bool spicyFitsTrack(Object? raw, double durationSec) {
  final body = raw is Map && raw['Body'] is Map ? raw['Body'] : raw;
  final end = body is Map ? body['EndTime'] : null;
  if (end is! num || !end.isFinite || !(durationSec > 0)) return true;
  return end <= durationSec + spicyEndToleranceSec;
}

/// Converts a SpicyLyrics response (the envelope or just its Body) into lines and credit. Null when nothing is usable.
SpicyConversion? convertSpicyLyrics(Object? raw) {
  final body = raw is Map && raw['Body'] is Map ? raw['Body'] : raw;
  if (body is! Map) return null;
  final List<LyricLine> lines;
  switch (body['Type']) {
    case 'Syllable':
      lines = _syllableLines(_arr(body['Content']));
    case 'Line':
      lines = _lineLines(_arr(body['Content']));
    case 'Static':
      lines = _staticLines(_arr(body['Lines']));
    default:
      return null;
  }
  return lines.isEmpty ? null : (lines: lines, credit: spicyCredit(body));
}

final _bareId = RegExp(r'^[A-Za-z0-9]{22}$');
final _uriId = RegExp(r'^spotify:track:([A-Za-z0-9]{22})$');
final _linkId = RegExp(r'^(?:https?://)?open\.spotify\.com/(?:intl-[a-z-]+/)?(?:embed/)?track/([A-Za-z0-9]{22})(?:[/?#].*)?$', caseSensitive: false);

/// The Spotify track id in a pasted share link, spotify:track: URI or bare id. Null otherwise.
String? parseSpotifyTrackId(Object? input) {
  if (input is! String) return null;
  final s = input.trim();
  if (_bareId.hasMatch(s)) return s;
  return _uriId.firstMatch(s)?[1] ?? _linkId.firstMatch(s)?[1];
}

final _spicyKey = RegExp(r'^sl_(sk|pk)_[A-Za-z0-9_-]{8,256}$');

/// A SpicyLyrics key as the dashboard hands it out: secret or public.
bool isSpicyKey(Object? v) => v is String && _spicyKey.hasMatch(v.trim());

/// A Spotify track id: 22 base62 characters.
bool isSpotifyTrackId(Object? v) => v is String && _bareId.hasMatch(v);

/// Ids tried per song, most likely first.
const maxSpicyCandidates = 3;

/// How long a SpicyLyrics miss stops the same track being asked again.
const spicyMissMs = 24 * 60 * 60 * 1000;

/// How long a SpicyLyrics answer is kept (25 days, under the terms' 30).
const spicyCacheMs = 25 * 24 * 60 * 60 * 1000;

/// Whether an answer saved at [savedAtMs] is still kept. A future date is not trusted.
bool spicyCacheFresh(Object? savedAtMs, int nowMs) => savedAtMs is num && savedAtMs.isFinite && savedAtMs <= nowMs && nowMs - savedAtMs < spicyCacheMs;

/// The lyrics URL for a Spotify id.
String spicyLyricsUrl(String spotifyId) => 'https://api.spicylyrics.org/v1/lyrics/${Uri.encodeComponent(spotifyId)}';

/// How long to leave a service alone after it answered [status], from Retry-After (seconds or a date) or X-RateLimit-Reset-In. 60 s for a bare 429, else 0. Capped at a day.
int backoffMs(int status, {String? retryAfter, String? resetIn, required int nowMs}) {
  int cap(num ms) => max(0, min(ms, 24 * 60 * 60 * 1000)).toInt();
  final ra = (retryAfter ?? '').trim();
  if (ra.isNotEmpty) {
    if (RegExp(r'^\d+$').hasMatch(ra)) return cap(int.parse(ra) * 1000);
    DateTime? at;
    try {
      at = HttpDate.parse(ra);
    } catch (_) {
      at = DateTime.tryParse(ra);
    }
    if (at != null) return cap(at.millisecondsSinceEpoch - nowMs);
  }
  final reset = double.tryParse((resetIn ?? '').trim());
  if (status == 429 && resetIn != null && resetIn.isNotEmpty && reset != null && reset.isFinite) return cap(reset * 1000);
  return status == 429 ? 60000 : 0;
}
