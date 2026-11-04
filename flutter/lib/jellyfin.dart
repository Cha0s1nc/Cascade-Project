// A small Jellyfin client: Quick Connect sign-in, the saved session, GET and
// POST, and turning server items into the app's models. Same auth as the
// desktop's src/core/jellyfin.ts: the token rides in the Authorization header,
// the only way Jellyfin 12 accepts by default (no api_key in URLs).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart';

const _client = 'Cascade Flutter';
const _version = '0.1.0';

class JellyfinError implements Exception {
  JellyfinError(this.message);
  final String message;
  @override
  String toString() => message;
}

class Jellyfin {
  Jellyfin(this.server, this.deviceId, {this.token, this.userId, this.userName});

  final String server, deviceId;
  String? token, userId, userName;

  static String get _device => Platform.isWindows
      ? 'Windows'
      : Platform.isAndroid
      ? 'Android'
      : Platform.operatingSystem;

  Map<String, String> get headers => {
    'Authorization':
        'MediaBrowser Client="$_client", Device="$_device", DeviceId="$deviceId", Version="$_version"'
        '${token == null ? '' : ', Token="$token"'}',
  };

  Future<dynamic> get(String path, [Map<String, Object?> query = const {}]) async {
    final uri = Uri.parse('$server$path').replace(
      queryParameters: {
        for (final e in query.entries)
          if (e.value != null) e.key: '${e.value}',
      },
    );
    return _read(await http.get(uri, headers: headers).timeout(const Duration(seconds: 15)), path);
  }

  Future<dynamic> post(String path, [Object? body]) async {
    final res = await http
        .post(Uri.parse('$server$path'), headers: {...headers, 'Content-Type': 'application/json'}, body: body == null ? null : jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    return _read(res, path);
  }

  dynamic _read(http.Response res, String path) {
    if (res.statusCode >= 300) throw JellyfinError('$path answered ${res.statusCode}');
    return res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
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
    return Song(
      j['Name'] as String? ?? '',
      j['AlbumArtist'] as String? ?? (j['Artists'] as List?)?.firstOrNull as String? ?? '',
      j['Album'] as String? ?? '',
      j['ProductionYear'] as int? ?? 0,
      ((j['RunTimeTicks'] as num? ?? 0) / 1e7).round(),
      artFor(id),
      id: id,
      image: image(j['AlbumId'] as String? ?? id, j['AlbumPrimaryImageTag'] as String? ?? j['ImageTags']?['Primary'] as String?),
    );
  }

  Album album(Map j) {
    final id = j['Id'] as String;
    final playlist = j['Type'] == 'Playlist';
    final count = j['ChildCount'] as int?;
    return Album(
      j['Name'] as String? ?? '',
      playlist ? (count == null ? 'Playlist' : '$count songs') : j['AlbumArtist'] as String? ?? '',
      artFor(id),
      id: id,
      image: image(id, j['ImageTags']?['Primary'] as String?),
      playlist: playlist,
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
