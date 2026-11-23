// Where lyrics come from, as renderer.js fetchLyricsFrom does it: SpicyLyrics
// through the Cascade Server plugin when it has a key, else the first of
// Kugou (word timed), LRCLIB and Jellyfin's own, all asked at once. A source
// can be forced instead. Results, misses included, are kept per song.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/lyrics.dart';
import 'package:cascade/core/spicy_lyrics.dart';

/// What a fetch found: the lines and where they came from, or that the
/// song is instrumental.
class Lyrics {
  const Lyrics(this.lines, this.source, {this.credit, this.instrumental = false, bool? held}) : held = held ?? credit != null;
  final List<LyricLine> lines;
  final String source;
  final SpicyCredit? credit;
  final bool instrumental;

  /// Syllable-timed (SpicyLyrics, or Cascade's own TTML): long notes may swell.
  final bool held;

  bool get synced => lines.isNotEmpty && lines.first.start != null;
  bool get karaoke => lines.any((l) => l.words != null && l.words!.isNotEmpty);
}

/// The sources a person can force, in the menu's order.
const lyricSources = ['Kugou', 'LRCLIB', 'Jellyfin'];

/// The forced choices in server-only mode: the Cascade Server plugin's own
/// files of that kind (the desktop's cascade-karaoke and cascade-synced).
const serverLyricSources = ['Karaoke', 'Synced'];

/// Credits and "Title - " prefixes some sources put in as lines.
RegExp _meta(String title) => RegExp(
  '^${RegExp.escape(title)}\\s*-\\s*|'
  '^(composed|written|produced|arranged|performed|lyrics|music|words|publisher|作词|作曲|编曲|编词|制作人)\\s*(by)?\\s*[:：]',
  caseSensitive: false,
);

const _krcKey = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105];

/// A KRC download: skip the 'krc1' magic, XOR with the fixed key, inflate.
String decryptKrc(String base64Content) {
  final raw = base64Decode(base64Content).sublist(4);
  for (var i = 0; i < raw.length; i++) {
    raw[i] ^= _krcKey[i % 16];
  }
  return utf8.decode(zlib.decode(raw));
}

List<LyricLine> _plain(String text) => [
  for (final t in text.split('\n').map((t) => t.trim()))
    if (t.isNotEmpty) LyricLine(null, null, t, null),
];

class LyricsFetcher {
  LyricsFetcher(this.jf, {http.Client? client}) : _http = client ?? http.Client();
  final Jellyfin jf;
  final http.Client _http;
  static const _timeout = Duration(seconds: 8);
  static const _agent = {'User-Agent': 'Cascade Flutter (https://cascade.chaosinc.xyz)'};

  final _cache = <String, Lyrics?>{};

  /// Server-only mode (the desktop's serverOnlyMode): only the Cascade Server
  /// plugin is asked, so no lyrics provider outside the server hears what is
  /// playing. Changing it forgets what was found the other way.
  bool get serverOnly => _serverOnly;
  bool _serverOnly = false;
  set serverOnly(bool on) {
    if (on != _serverOnly) _cache.clear();
    _serverOnly = on;
  }

  /// The plugin: whether it answered, which routes, and what it can do.
  Future<({bool present, bool legacy, Set<String> caps})>? _plugin;

  Future<({bool present, bool legacy, Set<String> caps})> plugin() => _plugin ??= () async {
    var caps = <String>{};
    Future<int?> status(String path) async {
      try {
        final res = await _http.get(Uri.parse('${jf.server}/$path'), headers: jf.headers).timeout(_timeout);
        if (res.statusCode == 200) {
          try {
            final c = (jsonDecode(res.body) as Map)['capabilities'];
            if (c is List) caps = c.whereType<String>().toSet();
          } catch (_) {}
        }
        return res.statusCode;
      } catch (_) {
        return null;
      }
    }

    final s = await status('CascadeServer/Info');
    if (s != 404) return (present: true, legacy: false, caps: caps); // unknown counts as present
    final l = await status('CascadeLyrics/Info');
    return (present: l != 404, legacy: true, caps: caps);
  }();

  String _pluginUrl(bool legacy, String id) => legacy ? '${jf.server}/Audio/$id/CascadeLyrics' : '${jf.server}/CascadeServer/Lyrics/$id';

  /// Lyrics made with Cascade Server's editor (or saved by this person): their
  /// own copy or TTML saved for everyone, which the plugin answers ahead of
  /// SpicyLyrics. TTML comes in SpicyLyrics' syllable shape, but is not theirs:
  /// no SpicyLyrics credit, and kept like any other lyrics. Null for anything else.
  Lyrics? edited(Map d) {
    final owner = d['owner'];
    final label = owner == 'mine' ? 'Your lyrics' : 'Cascade';
    if (d['type'] == 'ttml') {
      final conv = convertSpicyLyrics(d['lyrics']);
      return conv == null ? null : Lyrics(conv.lines, label, held: true);
    }
    if (owner != 'mine' || d['lrc'] is! String) return null;
    final lines = parseLRC(d['lrc'] as String);
    return lines.isEmpty ? null : Lyrics(lines, label);
  }

  /// The song's lyrics, or null when no source has them. [forced] is one of
  /// [lyricSources]; a forced answer is not kept.
  Future<Lyrics?> fetch(Song s, {String? forced}) async {
    if (forced == null && _cache.containsKey(s.id)) return _cache[s.id];
    final meta = _meta(s.title);
    List<LyricLine> clean(List<LyricLine> l) => l.where((x) => !meta.hasMatch(x.text)).toList();

    Future<Lyrics?> kugou() async {
      final search = Uri.parse(
        'http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=${Uri.encodeComponent('${s.searchArtist} - ${s.title}')}&duration=${s.seconds * 1000}',
      );
      final sr = await _http.get(search).timeout(_timeout);
      if (sr.statusCode != 200) return null;
      final c = ((jsonDecode(sr.body) as Map)['candidates'] as List?)?.firstOrNull as Map?;
      if (c == null) return null;
      final dl = await _http
          .get(Uri.parse('http://lyrics.kugou.com/download?ver=1&client=pc&id=${c['id']}&accesskey=${c['accesskey']}&fmt=krc&charset=utf8'))
          .timeout(_timeout);
      final content = (jsonDecode(dl.body) as Map)['content'] as String?;
      if (content == null || content.isEmpty) return null;
      final lines = clean(parseKrc(decryptKrc(content)));
      // Only word-timed lyrics count; plain lines are LRCLIB's to give.
      if (lines.isEmpty || !lines.any((l) => (l.words ?? const []).isNotEmpty)) return null;
      return Lyrics(lines, 'Kugou');
    }

    Future<Lyrics?> lrclib() async {
      final q = {'artist_name': s.searchArtist, 'track_name': s.title, 'album_name': s.album, 'duration': '${s.seconds}'};
      final res = await _http.get(Uri.https('lrclib.net', '/api/get', q), headers: _agent).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final d = jsonDecode(res.body) as Map;
      if (d['instrumental'] == true) return const Lyrics([], 'LRCLIB', instrumental: true);
      final synced = d['syncedLyrics'] as String?;
      if (synced != null && synced.isNotEmpty) {
        final lines = parseLRC(synced);
        if (lines.isNotEmpty) return Lyrics(lines, 'LRCLIB');
      }
      final plain = d['plainLyrics'] as String?;
      if (plain != null && plain.isNotEmpty) return Lyrics(_plain(plain), 'LRCLIB (plain)');
      return null;
    }

    Future<Lyrics?> jellyfin() async {
      final d = await jf.get('/Audio/${s.id}/Lyrics') as Map;
      final lines = [
        for (final l in (d['Lyrics'] as List? ?? const []).cast<Map>())
          if ((l['Text'] as String? ?? '').isNotEmpty) LyricLine(l['Start'] as int?, null, l['Text'] as String, null),
      ];
      return lines.isEmpty ? null : Lyrics(lines, 'Jellyfin');
    }

    // Asked of the plugin first: the person's own edited lyrics or TTML saved for
    // everyone (with ttml=true), then SpicyLyrics.
    Future<Lyrics?> spicy() async {
      final p = await plugin();
      final ttml = p.caps.contains('ttml-lyrics');
      if (!p.present || !(p.caps.contains('syllable') || ttml)) return null;
      final res = await _http
          .get(Uri.parse('${_pluginUrl(p.legacy, s.id)}?syllable=true&spicyOnly=true${ttml ? '&ttml=true' : ''}'), headers: jf.headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final d = jsonDecode(res.body) as Map;
      if (edited(d) case final e?) return e;
      if (d['type'] != 'syllable' || !spicyFitsTrack(d['spicy'], s.seconds.toDouble())) return null;
      final conv = convertSpicyLyrics(d['spicy']);
      return conv == null ? null : Lyrics(conv.lines, conv.credit.provider, credit: conv.credit);
    }

    Future<Lyrics?> safe(Future<Lyrics?> Function() f) => f().catchError((Object _) => null);

    // The plugin alone: SpicyLyrics when it has them and they fit this file,
    // else the plugin's own karaoke or synced file. A forced kind means
    // exactly that kind of file.
    Future<Lyrics?> cascade() async {
      final p = await plugin();
      if (!p.present) return null;
      final want = switch (forced) {
        'Karaoke' => 'karaoke',
        'Synced' => 'synced',
        _ => null,
      };
      Future<Map> ask(bool syllable) async {
        final q = [if (syllable) 'syllable=true', if (p.caps.contains('ttml-lyrics')) 'ttml=true'];
        final res = await _http.get(Uri.parse('${_pluginUrl(p.legacy, s.id)}${q.isEmpty ? '' : '?${q.join('&')}'}'), headers: jf.headers).timeout(_timeout);
        if (res.statusCode != 200) throw JellyfinError('HTTP ${res.statusCode}', res.statusCode);
        return jsonDecode(res.body) as Map;
      }

      var d = await ask(want == null && p.caps.contains('syllable'));
      if (want == null) {
        final e = edited(d);
        if (e != null) return e;
      }
      if (d['type'] == 'syllable') {
        final conv = spicyFitsTrack(d['spicy'], s.seconds.toDouble()) ? convertSpicyLyrics(d['spicy']) : null;
        if (conv != null) return Lyrics(conv.lines, conv.credit.provider, credit: conv.credit);
        d = await ask(false);
      }
      final lrc = d['lrc'] as String?;
      if (lrc == null || (want != null && d['type'] != want)) return null;
      final lines = clean(parseLRC(lrc));
      return lines.isEmpty ? null : Lyrics(lines, forced ?? 'Cascade');
    }

    if (_serverOnly) {
      final found = await safe(cascade);
      if (forced == null) _cache[s.id] = found;
      return found;
    }

    if (forced != null) {
      return safe(switch (forced) {
        'Kugou' => kugou,
        'LRCLIB' => lrclib,
        _ => jellyfin,
      });
    }
    final r = await Future.wait([safe(spicy), safe(kugou), safe(lrclib), safe(jellyfin)]);
    final instrumental = r.whereType<Lyrics>().where((l) => l.instrumental).firstOrNull;
    final found = instrumental ?? r.whereType<Lyrics>().firstOrNull;
    _cache[s.id] = found;
    return found;
  }

  /// Ask again next time (a source was down rather than missing the song).
  void forget(String id) => _cache.remove(id);

  /// Already fetched: the lyrics (or null for none), without waiting.
  bool has(String id) => _cache.containsKey(id);
  Lyrics? cached(String id) => _cache[id];
}
