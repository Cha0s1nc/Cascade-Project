// The big library lists (albums, artists, songs, playlists, genres) kept on
// disk between launches, so a page opens at once from last time's list and
// the server is only asked what changed. One JSON file per list, named for
// the server, the user and the chosen libraries, so switching any of those
// starts a fresh list rather than mixing two.
import 'dart:convert';
import 'dart:io';

import 'package:cascade/core/jellyfin.dart';

typedef CachedList = ({List<Item> items, int total, DateTime fetchedAt});

class ListCache {
  ListCache(this.dir);
  final Directory dir;

  File _file(String key) => File('${dir.path}/${key.hashCode.toUnsigned(32).toRadixString(16)}-${key.length}.json');

  Future<CachedList?> read(String key) async {
    try {
      final m = jsonDecode(await _file(key).readAsString()) as Map;
      if (m['key'] != key) return null;
      return (
        items: (m['items'] as List).cast<Map>().map((i) => i.cast<String, dynamic>()).toList(),
        total: m['total'] as int,
        fetchedAt: DateTime.parse(m['fetchedAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, List<Item> items, int total, DateTime at) async {
    try {
      await dir.create(recursive: true);
      final f = _file(key);
      // Written beside and moved in place, so a crash mid-write never leaves half a list.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'key': key, 'total': total, 'fetchedAt': at.toUtc().toIso8601String(), 'items': items}));
      await tmp.rename(f.path);
    } catch (_) {}
  }
}

/// [cached] with [changed] laid over it by Id, changed items replacing their
/// old copies and new ones added. Also how many of [changed] were new.
({List<Item> items, int added}) mergeChanged(List<Item> cached, List<Item> changed) {
  final byId = {for (final (i, it) in cached.indexed) it['Id']: i};
  final out = [...cached];
  var added = 0;
  for (final c in changed) {
    final at = byId[c['Id']];
    if (at != null) {
      out[at] = c;
    } else {
      byId[c['Id']] = out.length;
      out.add(c);
      added++;
    }
  }
  return (items: out, added: added);
}
