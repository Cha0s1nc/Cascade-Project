// Downloads, kept as the desktop's offline catalog (core/offline_index.dart):
// what the person asked for (an album, a playlist, a song), the files and
// covers on disk, each item's library, and the plays and likes made offline.
// The catalog is what Offline Mode answers the library from
// (core/offline_query.dart), so the same screens work with no server.
// Files: <support>/downloads/index.json, media/<id>.<ext>, art/<id>.jpg.
// ponytail: one download at a time; a half-finished file starts over.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/core/offline_index.dart';

const _fields = 'MediaSources,UserData,Genres,GenreItems,ArtistItems,AlbumArtists,Overview,DateCreated,SortName,ChildCount,ProductionYear';

class Downloads extends ChangeNotifier {
  Downloads({Directory? dir, http.Client? client}) : _dirOverride = dir, _http = client ?? http.Client();
  final Directory? _dirOverride;
  final http.Client _http;
  late Directory _dir;
  OfflineIndex index = emptyIndex();

  /// What is downloading: the track, how far (0-1), and the last failure.
  String? current;
  double progress = 0;
  String? error;
  Jellyfin? _jf;

  Future<void> load() async {
    _dir = _dirOverride ?? Directory('${(await getApplicationSupportDirectory()).path}/downloads');
    await Directory('${_dir.path}/media').create(recursive: true);
    await Directory('${_dir.path}/art').create(recursive: true);
    try {
      final raw = jsonDecode(await File('${_dir.path}/index.json').readAsString());
      index = raw is Map && raw['songs'] is List ? _fromFirstFormat(raw['songs'] as List) : parseIndex(raw);
    } catch (_) {}
    final onDisk = [
      for (final f in Directory('${_dir.path}/media').listSync().whereType<File>())
        if (!f.path.endsWith('.part')) 'media/${f.uri.pathSegments.last}',
    ];
    reconcile(index, onDisk);
    notifyListeners();
  }

  /// The first Flutter build kept a plain list of songs: each becomes a
  /// collection of one, its file moved under media/.
  OfflineIndex _fromFirstFormat(List songs) {
    final idx = emptyIndex();
    for (final e in songs.whereType<Map>()) {
      final item = (e['item'] as Map?)?.cast<String, dynamic>();
      final file = e['file'] as String?;
      if (item == null || file == null) continue;
      final old = File('${_dir.path}/$file');
      if (!old.existsSync()) continue;
      old.renameSync('${_dir.path}/media/$file');
      addCollection(idx, item, [item]);
      markReady(idx, item['Id'] as String, 'media/$file', File('${_dir.path}/media/$file').lengthSync());
    }
    return idx;
  }

  Future<void> save() => File('${_dir.path}/index.json').writeAsString(index.json);

  bool has(String id) => readyFile(index, id) != null;
  bool waiting(String id) => index.tracks.containsKey(id) && !has(id);

  String? fileOf(String id) {
    final f = readyFile(index, id);
    return f == null ? null : '${_dir.path}/$f';
  }

  /// A downloaded cover for an item, if there is one.
  String? artOf(String id) {
    final f = File('${_dir.path}/art/$id.jpg');
    return f.existsSync() ? f.path : null;
  }

  /// The downloaded tracks, newest collection first.
  List<Item> get items => [
    for (final t in index.tracks.values)
      if (t.file != null) t.item,
  ];

  int get bytes => totalBytes(index).round();

  /// Download [songs] as [collection] (an album or playlist item; null for
  /// songs on their own, each its own collection). The server's libraries,
  /// the user and each item's library are stored too, so the catalog
  /// answers offline the way the server would.
  Future<void> add(Jellyfin jf, List<Song> songs, {Item? collection, List<Item> views = const [], Map? user}) async {
    _jf = jf;
    final ids = [
      for (final s in songs)
        if (s.id.isNotEmpty) s.id,
    ];
    if (ids.isEmpty) return;
    final items = <Item>[];
    for (var i = 0; i < ids.length; i += 100) {
      final res = await jf.get('/Items', {'userId': jf.userId, 'Ids': ids.skip(i).take(100).join(','), 'Fields': _fields});
      items.addAll(((res as Map)['Items'] as List).cast<Item>());
    }
    if (views.isNotEmpty) setLibraries(index, views);
    if (user != null) setUser(index, user);
    if (collection != null) {
      addCollection(index, collection, items);
    } else {
      for (final it in items) {
        addCollection(index, it, [it]);
      }
    }
    // Each album's library, from its ancestors (Jellyfin 12 ignores ParentId
    // when Ids is given, so asking per library would misplace them).
    for (final MapEntry(key: key, value: group) in placementGroups(index, unplacedTrackIds(index)).entries) {
      try {
        final anc = await jf.get('/Items/$key/Ancestors', {'userId': jf.userId});
        final lib = libraryFromAncestors(index, anc);
        if (lib != null) assignLibrary(index, group, lib);
      } catch (_) {}
    }
    await save();
    notifyListeners();
    _run();
  }

  bool _running = false;
  Future<void> _run() async {
    final jf = _jf;
    if (_running || jf == null) return;
    _running = true;
    error = null;
    while (true) {
      final pending = pendingTrackIds(index);
      if (pending.isEmpty) break;
      final id = pending.first;
      final item = index.tracks[id]!.item;
      current = id;
      progress = 0;
      notifyListeners();
      final ext = (((item['MediaSources'] as List?)?.firstOrNull as Map?)?['Container'] as String? ?? 'audio').split(',').first;
      final name = 'media/$id.$ext';
      final part = File('${_dir.path}/$name.part');
      try {
        final res = await _http.send(http.Request('GET', Uri.parse('${jf.server}/Items/$id/Download'))..headers.addAll(jf.headers));
        if (res.statusCode >= 300) throw JellyfinError('The server refused (${res.statusCode})', res.statusCode);
        final total = res.contentLength ?? 0;
        var got = 0;
        final sink = part.openWrite();
        await for (final chunk in res.stream) {
          // Cancelled or removed while it came in: stop the transfer.
          if (!index.tracks.containsKey(id)) break;
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            progress = got / total;
            notifyListeners();
          }
        }
        await sink.close();
        if (!index.tracks.containsKey(id)) {
          if (part.existsSync()) part.deleteSync();
          continue;
        }
        await part.rename('${_dir.path}/$name');
        markReady(index, id, name, got, DateTime.now());
        await _art(jf, item['AlbumId'] as String? ?? id, item['AlbumPrimaryImageTag'] as String? ?? (item['ImageTags'] as Map?)?['Primary'] as String?);
        for (final c in index.collections) {
          await _art(jf, c.item['Id'] as String, (c.item['ImageTags'] as Map?)?['Primary'] as String?);
        }
        await save();
      } catch (e) {
        log('download $id failed: $e');
        error = 'Could not download ${item['Name']}: $e';
        if (part.existsSync()) part.deleteSync();
        // Out of the pending list so the loop moves on; asked again next time.
        removeTracks(index, [id]);
        await save();
      }
    }
    current = null;
    _running = false;
    notifyListeners();
  }

  Future<void> _art(Jellyfin jf, String id, String? tag) async {
    if (tag == null || !isSafeId(id)) return;
    final f = File('${_dir.path}/art/$id.jpg');
    if (f.existsSync()) return;
    try {
      final res = await _http.get(Uri.parse('${jf.server}/Items/$id/Images/Primary?tag=$tag&maxWidth=600&quality=90'), headers: jf.headers);
      if (res.statusCode == 200) await f.writeAsBytes(res.bodyBytes);
    } catch (_) {}
  }

  /// Remove songs (from every collection holding them), or whole collections.
  /// One still coming in stops (the loop sees it gone).
  Future<void> remove(Iterable<String> ids) async {
    final list = ids.toList();
    await _drop([
      ...removeTracks(index, list),
      for (final id in list)
        if (collectionOf(index, id) != null) ...removeCollection(index, id),
    ]);
  }

  /// Remove downloads as they were made (an album, a playlist, a song on its
  /// own), keeping files another download still holds: removing an album
  /// leaves its songs in a downloaded playlist. Ids that are not a download
  /// are skipped. One still coming in stops.
  Future<void> removeCollections(Iterable<String> ids) async => _drop([
    for (final id in ids)
      if (collectionOf(index, id) != null) ...removeCollection(index, id),
  ]);

  /// Stop everything still to come in; what has landed stays.
  Future<void> cancelAll() => remove(pendingTrackIds(index));

  /// Whether [collectionId] (an album, a playlist, a song on its own) is a
  /// download, and if so whether it is all here.
  ({int done, int total})? downloadOf(String collectionId) => collectionOf(index, collectionId) == null ? null : collectionProgress(index, collectionId);

  Future<void> _drop(List<String> files) async {
    for (final f in files) {
      final file = File('${_dir.path}/$f');
      if (file.existsSync()) file.deleteSync();
    }
    await save();
    notifyListeners();
  }
}
