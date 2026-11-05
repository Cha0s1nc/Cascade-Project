// The Jellyfin client, ported from the desktop's src/core/jellyfin.ts:
// Quick Connect sign-in and the saved session, GET/POST/DELETE that read
// failed responses, queries fanned out over the chosen libraries and merged
// (the same song or album in two libraries once), paging, and turning server
// items into the app's models. The token rides in the Authorization header,
// the only way Jellyfin 12 accepts by default (no api_key in URLs).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/data.dart';

/// A server item, as the server sent it.
typedef Item = Map<String, dynamic>;

/// One library's results, for views that show a section per library.
typedef Group = ({String libraryId, List<Item> items});

const _client = 'Cascade Flutter';
const _version = '0.1.0';

/// Default page size when a caller sets no Limit.
const _pageSize = 500;

/// Copies of one song in two libraries count as the same when their lengths
/// are this close (seconds), so a live or extended cut stays separate.
const duplicateDurationSec = 3;

class JellyfinError implements Exception {
  JellyfinError(this.message, [this.status]);
  final String message;

  /// The HTTP status, or null when nothing answered.
  final int? status;
  @override
  String toString() => message;
}

class Jellyfin {
  Jellyfin(this.server, this.deviceId, {this.token, this.userId, this.userName, http.Client? client}) : _http = client ?? http.Client();

  final String server, deviceId;
  String? token, userId, userName;
  final http.Client _http;

  /// The music libraries queries fan out over; empty or null means all.
  List<String>? libraryIds;

  /// Told about every request that failed, with its status, or null when
  /// nothing answered: how a server dropping mid-session gets noticed.
  void Function(int? status)? onFailure;

  static String get _device => Platform.isWindows
      ? 'Windows'
      : Platform.isAndroid
      ? 'Android'
      : Platform.isLinux
      ? 'Linux'
      : Platform.operatingSystem;

  Map<String, String> get headers => {
    'Authorization':
        'MediaBrowser Client="$_client", Device="$_device", DeviceId="$deviceId", Version="$_version"'
        '${token == null ? '' : ', Token="$token"'}',
  };

  Uri _uri(String path, Map<String, Object?> query) {
    final q = {
      for (final e in query.entries)
        if (e.value != null) e.key: '${e.value}',
    };
    final u = Uri.parse('$server$path');
    return q.isEmpty ? u : u.replace(queryParameters: q);
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(const Duration(seconds: 30));
    } catch (e) {
      onFailure?.call(null);
      rethrow;
    }
  }

  /// The body as JSON, null when there is none (a 204), or a JellyfinError
  /// carrying the server's own message (CODEMAP rule 1: read what a write says).
  dynamic _read(http.Response res) {
    if (res.statusCode >= 300) {
      onFailure?.call(res.statusCode);
      throw JellyfinError(errorMessage(res), res.statusCode);
    }
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<dynamic> get(String path, [Map<String, Object?> query = const {}]) async => _read(await _send(() => _http.get(_uri(path, query), headers: headers)));

  Future<dynamic> post(String path, [Object? body, Map<String, Object?> query = const {}]) async => _read(
    await _send(() => _http.post(_uri(path, query), headers: {...headers, 'Content-Type': 'application/json'}, body: body == null ? null : jsonEncode(body))),
  );

  /// DELETE, for endpoints that answer with no body. False when refused or
  /// unanswered, never throws: every caller is cleaning up and carries on.
  Future<bool> del(String path, [Map<String, Object?> query = const {}]) async {
    try {
      final res = await _send(() => _http.delete(_uri(path, query), headers: headers));
      if (res.statusCode >= 300) onFailure?.call(res.statusCode);
      return res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  static List<Item> _items(dynamic res) => ((res is Map ? res['Items'] : null) as List? ?? const []).cast<Item>();

  // Queries over the chosen libraries ---------------------------------------

  /// The query run against each library and merged, the same item once (see
  /// [dedupe]). With no libraries chosen, a plain get. Limit is per library;
  /// [getAllPaged] keeps going past it. [libraries] overrides the music
  /// libraries, so video queries never fan out over music and vice versa.
  Future<List<Item>> getMerged(String path, [Map<String, Object?> query = const {}, List<String>? libraries]) async {
    final ids = libraries ?? libraryIds ?? const [];
    if (ids.isEmpty) return _items(await get(path, query));
    final d = _withDedupeFields(query, ids);
    return d.strip(dedupe([for (final g in await getGrouped(path, d.query, ids)) g.items]));
  }

  /// One group per library, in the order given. A library that fails gives
  /// an empty group rather than sinking the rest.
  Future<List<Group>> getGrouped(String path, [Map<String, Object?> query = const {}, List<String>? libraries]) async {
    final ids = libraries ?? libraryIds ?? const [];
    if (ids.isEmpty) return [(libraryId: '', items: _items(await get(path, query)))];
    final results = await Future.wait(ids.map((id) => get(path, {...query, 'ParentId': id}).then(_items, onError: (_) => <Item>[])));
    return [for (var i = 0; i < ids.length; i++) (libraryId: ids[i], items: results[i])];
  }

  /// [getMerged], paging each library to the end.
  Future<List<Item>> getAllPaged(String path, [Map<String, Object?> query = const {}, List<String>? libraries]) async {
    final ids = libraries ?? libraryIds ?? const [];
    final d = _withDedupeFields(query, ids);
    final per = await Future.wait(ids.isEmpty ? [_getAll(path, d.query)] : ids.map((id) => _getAll(path, {...d.query, 'ParentId': id})));
    return d.strip(dedupe(per));
  }

  /// [getGrouped], paging each library to the end.
  Future<List<Group>> getAllGrouped(String path, [Map<String, Object?> query = const {}, List<String>? libraries]) async {
    final ids = libraries ?? libraryIds ?? const [];
    if (ids.isEmpty) return [(libraryId: '', items: await _getAll(path, query))];
    final results = await Future.wait(ids.map((id) => _getAll(path, {...query, 'ParentId': id})));
    return [for (var i = 0; i < ids.length; i++) (libraryId: ids[i], items: results[i])];
  }

  /// Every item one query matches. The first page gives TotalRecordCount; the
  /// rest are fetched in parallel. A failed page is dropped, not fatal.
  Future<List<Item>> _getAll(String path, Map<String, Object?> query) async {
    final size = int.tryParse('${query['Limit']}') ?? _pageSize;
    final q = {...query, 'Limit': size};
    final first = await get(path, {...q, 'StartIndex': 0}).catchError((_) => null);
    final items = [..._items(first)];
    final total = (first is Map ? first['TotalRecordCount'] as int? : null) ?? items.length;
    if (total > items.length) {
      final pages = await Future.wait([
        for (var start = items.length; start < total; start += size) get(path, {...q, 'StartIndex': start}).then(_items, onError: (_) => <Item>[]),
      ]);
      for (final p in pages) {
        items.addAll(p);
      }
    }
    return items;
  }

  /// The fields [dedupe] compares copies by, asked for only across two or more
  /// libraries (MediaSources more than doubles a song's size), and taken back
  /// off afterwards unless the caller asked for them.
  static ({Map<String, Object?> query, List<Item> Function(List<Item>) strip}) _withDedupeFields(Map<String, Object?> query, List<String> ids) {
    final fields = '${query['Fields'] ?? ''}', types = '${query['IncludeItemTypes'] ?? ''}';
    bool has(String list, String name) => list.split(',').contains(name);
    final add = ids.length < 2
        ? const <String>[]
        : [if (has(types, 'Audio')) 'MediaSources', if (has(types, 'MusicAlbum')) 'ChildCount'].where((f) => !has(fields, f)).toList();
    if (add.isEmpty) return (query: query, strip: (r) => r);
    return (
      query: {
        ...query,
        'Fields': [if (fields.isNotEmpty) fields, ...add].join(','),
      },
      strip: (r) {
        for (final i in r) {
          for (final f in add) {
            i.remove(f);
          }
        }
        return r;
      },
    );
  }

  String? image(String? id, String? tag, {String type = 'Primary', int width = 300}) =>
      id == null || tag == null ? null : '$server/Items/$id/Images/$type?tag=$tag&maxWidth=$width&quality=90';

  /// The original file, untouched: mpv plays nearly every codec, and this is
  /// what gapless playback needs.
  String stream(String id) => '$server/Audio/$id/stream?static=true';

  // Sign-in --------------------------------------------------------------

  static String normalize(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u.contains('://') ? u : 'http://$u';
  }

  static Future<Jellyfin> forServer(String url) async => Jellyfin(normalize(url), _deviceId(await SharedPreferences.getInstance()));

  Future<String> serverName() async => (await get('/System/Info/Public'))['ServerName'] as String? ?? server;

  Future<({String code, String secret})> quickConnectStart() async {
    final j = await post('/QuickConnect/Initiate');
    return (code: j['Code'] as String, secret: j['Secret'] as String);
  }

  /// False until someone approves the code; an expired request (404) is false too.
  Future<bool> quickConnectApproved(String secret) async {
    try {
      return (await get('/QuickConnect/Connect', {'secret': secret}))['Authenticated'] == true;
    } on JellyfinError {
      return false;
    }
  }

  Future<void> quickConnectFinish(String secret) async {
    final j = await post('/Users/AuthenticateWithQuickConnect', {'Secret': secret});
    token = j['AccessToken'] as String;
    userId = j['User']['Id'] as String;
    userName = j['User']['Name'] as String;
    final p = await SharedPreferences.getInstance();
    await p.setString('server', server);
    await p.setString('token', token!);
    await p.setString('userId', userId!);
    await p.setString('userName', userName!);
  }

  static Future<Jellyfin?> restore() async {
    final p = await SharedPreferences.getInstance();
    final server = p.getString('server'), token = p.getString('token');
    if (server == null || token == null) return null;
    return Jellyfin(server, _deviceId(p), token: token, userId: p.getString('userId'), userName: p.getString('userName'));
  }

  Future<void> signOut() async {
    try {
      await post('/Sessions/Logout');
    } catch (_) {} // signing out locally matters more than telling the server
    final p = await SharedPreferences.getInstance();
    for (final k in ['token', 'userId', 'userName']) {
      await p.remove(k);
    }
    token = null;
  }

  static String _deviceId(SharedPreferences p) {
    var id = p.getString('deviceId');
    if (id == null) {
      final r = Random.secure();
      id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      p.setString('deviceId', id);
    }
    return id;
  }

  // Server items to models ------------------------------------------------

  Song song(Map j) {
    final id = j['Id'] as String;
    final ud = j['UserData'] as Map? ?? const {};
    final artists = j['ArtistItems'] as List? ?? j['AlbumArtists'] as List? ?? const [];
    return Song(
      j['Name'] as String? ?? '',
      j['AlbumArtist'] as String? ?? (j['Artists'] as List?)?.firstOrNull as String? ?? '',
      j['Album'] as String? ?? '',
      j['ProductionYear'] as int? ?? 0,
      ((j['RunTimeTicks'] as num? ?? 0) / 1e7).round(),
      artFor(id),
      id: id,
      albumId: j['AlbumId'] as String?,
      artistId: artists.isEmpty ? null : (artists.first as Map)['Id'] as String?,
      image: image(j['AlbumId'] as String? ?? id, j['AlbumPrimaryImageTag'] as String? ?? j['ImageTags']?['Primary'] as String?),
      track: j['IndexNumber'] as int? ?? 0,
      disc: j['ParentIndexNumber'] as int? ?? 0,
      playCount: ud['PlayCount'] as int? ?? 0,
      favorite: ud['IsFavorite'] == true,
      playlistItemId: j['PlaylistItemId'] as String?,
      lastPlayed: ud['LastPlayedDate'] as String?,
    );
  }

  /// A Live TV channel, as radio.
  Song channel(Map j) {
    final id = j['Id'] as String;
    return Song(
      j['Name'] as String? ?? '',
      j['ChannelNumber'] == null ? 'Radio' : 'Channel ${j['ChannelNumber']}',
      '',
      0,
      0,
      artFor(id),
      id: id,
      image: image(id, j['ImageTags']?['Primary'] as String?),
      live: true,
    );
  }

  Album album(Map j) {
    final id = j['Id'] as String;
    final playlist = j['Type'] == 'Playlist';
    final count = j['ChildCount'] as int?;
    final ud = j['UserData'] as Map? ?? const {};
    final artists = j['AlbumArtists'] as List? ?? const [];
    return Album(
      j['Name'] as String? ?? '',
      playlist ? (count == null ? 'Playlist' : '$count songs') : j['AlbumArtist'] as String? ?? '',
      artFor(id),
      id: id,
      image: image(id, j['ImageTags']?['Primary'] as String?),
      playlist: playlist,
      year: j['ProductionYear'] as int? ?? 0,
      artist: j['AlbumArtist'] as String? ?? '',
      artistId: artists.isEmpty ? null : (artists.first as Map)['Id'] as String?,
      count: count ?? 0,
      favorite: ud['IsFavorite'] == true,
      playCount: ud['PlayCount'] as int? ?? 0,
      lastPlayed: ud['LastPlayedDate'] as String?,
      overview: j['Overview'] as String?,
    );
  }

  Artist artist(Map j) {
    final id = j['Id'] as String;
    return Artist(
      j['Name'] as String? ?? '',
      artFor(id),
      id: id,
      image: image(id, j['ImageTags']?['Primary'] as String?),
      favorite: (j['UserData'] as Map?)?['IsFavorite'] == true,
      overview: j['Overview'] as String?,
    );
  }

  Genre genre(Map j) {
    final id = j['Id'] as String;
    return Genre(
      j['Name'] as String? ?? '',
      artFor(id),
      id: id,
      image: image(id, j['ImageTags']?['Primary'] as String?),
      count: j['AlbumCount'] as int? ?? j['ChildCount'] as int? ?? 0,
    );
  }

  Video video(Map j) {
    final id = j['Id'] as String;
    final episode = j['Type'] == 'Episode';
    final ticks = (j['RunTimeTicks'] as num? ?? 0) - (j['UserData']?['PlaybackPositionTicks'] as num? ?? 0);
    final minutes = (ticks / 6e8).round();
    final backdrops = j['BackdropImageTags'] as List? ?? const [];
    final parentBackdrops = j['ParentBackdropImageTags'] as List? ?? const [];
    return Video(
      id: id,
      type: j['Type'] as String? ?? '',
      seriesId: j['SeriesId'] as String?,
      episode ? j['SeriesName'] as String? ?? '' : j['Name'] as String? ?? '',
      episode ? 'S${j['ParentIndexNumber'] ?? '?'} E${j['IndexNumber'] ?? '?'} · ${j['Name'] ?? ''}' : 'Movie · ${j['ProductionYear'] ?? ''}',
      minutes >= 60 ? '${minutes ~/ 60} h ${minutes % 60} min left' : '$minutes min left',
      ((j['UserData']?['PlayedPercentage'] as num? ?? 0) / 100).toDouble(),
      artFor(id),
      image: backdrops.isNotEmpty
          ? image(id, backdrops.first as String, type: 'Backdrop', width: 480)
          : parentBackdrops.isNotEmpty
          ? image(j['ParentBackdropItemId'] as String?, parentBackdrops.first as String, type: 'Backdrop', width: 480)
          : null,
    );
  }
}

// Pure rules, each a port of the desktop function of the same name ---------

/// A failed response as one readable line: the status, plus the body when it
/// is short text. An HTML error page (a proxy's, usually) gives just the
/// status, and any body is collapsed to one line and capped.
String errorMessage(http.Response res) {
  final status = '${res.statusCode} ${res.reasonPhrase ?? ''}'.trim();
  final body = res.body.trim();
  if (body.isEmpty || (res.headers['content-type'] ?? '').contains('html') || body.startsWith('<')) return status;
  final one = body.replaceAll(RegExp(r'\s+'), ' ');
  return one.length > 200 ? '${one.substring(0, 200)}…' : one;
}

// ponytail: no NFKC normalization (Dart has none built in), so compatibility
// forms like fullwidth letters do not match their plain twins. Punctuation and
// case, the common differences, are handled.
final _punctuation = RegExp(r'[\p{P}\p{S}\s]+', unicode: true);
String _normalise(String? s) => (s ?? '').toLowerCase().replaceAll(_punctuation, '');

/// What makes two songs, albums or artists the same, or null for anything else.
String? _contentKey(Item item) {
  final name = _normalise(item['Name'] as String?);
  if (name.isEmpty) return null;
  final artists = item['Artists'] as List?;
  final first = artists != null && artists.isNotEmpty ? artists.first as String? : null;
  return switch (item['Type']) {
    'Audio' => 'a|$name|${_normalise(first ?? item['AlbumArtist'] as String?)}',
    'MusicAlbum' => 'm|$name|${_normalise(item['AlbumArtist'] as String? ?? first)}',
    'MusicArtist' => 'r|$name',
    _ => null,
  };
}

int _bitrate(Item i) {
  final sources = i['MediaSources'] as List?;
  return sources == null || sources.isEmpty ? 0 : (sources.first as Map)['Bitrate'] as int? ?? 0;
}

/// Which of two copies of the same song or album to keep: the album with
/// more tracks, the song with the higher bitrate.
bool _better(Item a, Item b) => a['Type'] == 'MusicAlbum' ? (a['ChildCount'] as int? ?? 0) > (b['ChildCount'] as int? ?? 0) : _bitrate(a) > _bitrate(b);

/// Per-library results, in library order, merged into one list: an item once
/// by Id, and the same song, album or artist found in two libraries once too
/// (the better copy, in the first copy's place). Songs match on title and
/// first artist with lengths within [duplicateDurationSec]; albums on name and
/// album artist; artists on name, since Jellyfin 12 gives an artist a new id
/// in every library. Copies inside one library are that library's business.
List<Item> dedupe(List<List<Item>> lists) {
  final seen = <String>{};
  final byContent = <String, List<({int lib, double? sec, int pos})>>{};
  final items = <Item>[];
  for (var lib = 0; lib < lists.length; lib++) {
    for (final item in lists[lib]) {
      if (!seen.add(item['Id'] as String)) continue;
      final key = _contentKey(item);
      if (key != null) {
        final ticks = item['RunTimeTicks'] as num?;
        final sec = ticks == null || ticks == 0 ? null : ticks / 1e7;
        final copies = byContent.putIfAbsent(key, () => []);
        final at = copies.indexWhere(
          (c) => c.lib != lib && (item['Type'] != 'Audio' || c.sec == null || sec == null || (c.sec! - sec).abs() <= duplicateDurationSec),
        );
        if (at >= 0) {
          final c = copies[at];
          if (_better(item, items[c.pos])) {
            items[c.pos] = item;
            copies[at] = (lib: lib, sec: sec, pos: c.pos);
          }
          continue;
        }
        copies.add((lib: lib, sec: sec, pos: items.length));
      }
      items.add(item);
    }
  }
  return items;
}

/// Saved video library ids sorted into movies and shows by each library's
/// CollectionType. An id that matches nothing any more is dropped.
({List<String> movieIds, List<String> showIds}) splitVideoLibraryIds(List<Item> libs, List<String> ids) {
  bool kind(String id, String type) => libs.any((l) => l['Id'] == id && l['CollectionType'] == type);
  return (movieIds: ids.where((id) => kind(id, 'movies')).toList(), showIds: ids.where((id) => kind(id, 'tvshows')).toList());
}

/// The ids in effect for one category. Null saved means never chosen: a sole
/// library defaults on, several default to none. An empty list is a real
/// "none" and sticks. Ids that no longer match a library are dropped.
List<String> effectiveLibraryIds(List<Item> categoryLibs, List<String>? saved) {
  if (categoryLibs.isEmpty) return const [];
  if (saved == null) return categoryLibs.length == 1 ? [categoryLibs.first['Id'] as String] : const [];
  return saved.where((id) => categoryLibs.any((l) => l['Id'] == id)).toList();
}

/// One Continue watching card per series: the first episode seen of each
/// SeriesId wins, so the caller's order decides. An episode with no SeriesId
/// and every movie always stays.
List<Item> onePerSeries(List<Item> items) {
  final seen = <String>{};
  return [
    for (final i in items)
      if (i['Type'] != 'Episode' || (i['SeriesId'] as String? ?? '').isEmpty || seen.add(i['SeriesId'] as String)) i,
  ];
}

/// Whether to offer Delete at all: admins, users with deletion everywhere,
/// or on at least one library. The server still refuses where not allowed.
bool canDeleteMedia(Map? policy) {
  if (policy == null) return false;
  if (policy['IsAdministrator'] == true || policy['EnableContentDeletion'] == true) return true;
  return (policy['EnableContentDeletionFromFolders'] as List? ?? const []).isNotEmpty;
}

/// Downloading is on unless the policy turns it off.
bool canDownload(Map? policy) => policy?['EnableContentDownloading'] != false;
