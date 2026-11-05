// Downloads: songs saved to this device as the server's original files
// (/Items/{id}/Download), so they play without the server. The list of what
// is here is a JSON file beside them, holding each song's server item, so
// the Downloads page and the player need nothing from the server.
// ponytail: one download at a time, no resume of a half-finished file
// (it starts over); Offline Mode's catalog (core/offline_index.dart) and
// video downloads build on this later.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/log.dart';

class Downloads extends ChangeNotifier {
  Downloads({Directory? dir, http.Client? client}) : _dirOverride = dir, _http = client ?? http.Client();
  final Directory? _dirOverride;
  final http.Client _http;
  late Directory _dir;

  /// Downloaded songs by id, as the server described them.
  final items = <String, Item>{};

  /// File name per id (the extension is the server's container).
  final _files = <String, String>{};

  /// Waiting and in-flight downloads, and how far the current one is (0-1).
  final queue = <(Item, Jellyfin)>[];
  String? current;
  double progress = 0;
  String? error;

  Future<void> load() async {
    _dir = _dirOverride ?? Directory('${(await getApplicationSupportDirectory()).path}/downloads');
    await _dir.create(recursive: true);
    try {
      final saved = jsonDecode(await File('${_dir.path}/index.json').readAsString()) as Map;
      for (final e in (saved['songs'] as List).cast<Map>()) {
        final id = e['item']['Id'] as String;
        if (File('${_dir.path}/${e['file']}').existsSync()) {
          items[id] = (e['item'] as Map).cast<String, dynamic>();
          _files[id] = e['file'] as String;
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() => File('${_dir.path}/index.json').writeAsString(
    jsonEncode({
      'songs': [
        for (final id in items.keys) {'item': items[id], 'file': _files[id]},
      ],
    }),
  );

  bool has(String id) => _files.containsKey(id);
  bool waiting(String id) => current == id || queue.any((q) => q.$1['Id'] == id);

  String? fileOf(String id) {
    final f = _files[id];
    return f == null ? null : '${_dir.path}/$f';
  }

  /// Bytes the downloads take.
  int get bytes => _files.values.fold(0, (t, f) {
    try {
      return t + File('${_dir.path}/$f').lengthSync();
    } catch (_) {
      return t;
    }
  });

  /// Download [songs] (skipping ones already here). The item is fetched for
  /// its container and full metadata.
  Future<void> add(Jellyfin jf, List<Song> songs) async {
    for (final s in songs) {
      if (s.id.isEmpty || has(s.id) || waiting(s.id)) continue;
      final item = await jf.get('/Items/${s.id}', {'userId': jf.userId, 'Fields': 'MediaSources,UserData'}) as Item;
      queue.add((item, jf));
    }
    notifyListeners();
    _run();
  }

  bool _running = false;
  Future<void> _run() async {
    if (_running) return;
    _running = true;
    while (queue.isNotEmpty) {
      final (item, jf) = queue.removeAt(0);
      final id = item['Id'] as String;
      current = id;
      progress = 0;
      notifyListeners();
      final ext = ((item['Container'] as String?) ?? 'audio').split(',').first;
      final name = '$id.$ext';
      final part = File('${_dir.path}/$name.part');
      try {
        final res = await _http.send(http.Request('GET', Uri.parse('${jf.server}/Items/$id/Download'))..headers.addAll(jf.headers));
        if (res.statusCode >= 300) throw JellyfinError('The server refused (${res.statusCode})', res.statusCode);
        final total = res.contentLength ?? 0;
        var got = 0;
        final sink = part.openWrite();
        await for (final chunk in res.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            progress = got / total;
            notifyListeners();
          }
        }
        await sink.close();
        await part.rename('${_dir.path}/$name');
        items[id] = item;
        _files[id] = name;
        await _save();
      } catch (e) {
        log('download $id failed: $e');
        error = 'Could not download ${item['Name']}: $e';
        if (part.existsSync()) part.deleteSync();
      }
    }
    current = null;
    _running = false;
    notifyListeners();
  }

  Future<void> remove(Iterable<String> ids) async {
    for (final id in [...ids]) {
      final f = fileOf(id);
      if (f != null && File(f).existsSync()) File(f).deleteSync();
      items.remove(id);
      _files.remove(id);
    }
    await _save();
    notifyListeners();
  }
}
