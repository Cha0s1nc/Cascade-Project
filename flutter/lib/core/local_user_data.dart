// Local mode's favorites, plays and positions: written straight into the
// catalog's UserData, kept by item id so they outlive a rescan. Not Offline
// Mode's queue of changes (offline_sync.dart): there is no server to send them
// to. Pure. Ported from desktop/src/core/local-user-data.ts.
import 'offline_index.dart';

/// The user Local mode signs in as: there is nobody else.
const localUserId = 'local';

/// What the person did with an item: a Map with any of IsFavorite, Played, PlayCount, PlaybackPositionTicks, LastPlayedDate.
typedef LocalUserData = Map<String, Object?>;

/// A change: `{kind: 'favorite', favorite}`, `{kind: 'played', played}`, `{kind: 'position', ticks}` or `{kind: 'play'}` (playback started).
typedef LocalChange = Map<String, Object?>;

bool _finite(Object? v) => v is num && v.isFinite;

/// A change sent by the renderer, checked. Null when it is not one.
LocalChange? parseLocalChange(Object? v) {
  if (v is! Map) return null;
  if (v['kind'] == 'favorite' && v['favorite'] is bool) return {'kind': 'favorite', 'favorite': v['favorite']};
  if (v['kind'] == 'played' && v['played'] is bool) return {'kind': 'played', 'played': v['played']};
  if (v['kind'] == 'position' && _finite(v['ticks']) && (v['ticks'] as num) >= 0) return {'kind': 'position', 'ticks': (v['ticks'] as num).round()};
  if (v['kind'] == 'play') return {'kind': 'play'};
  return null;
}

String _iso(DateTime d) => DateTime.fromMillisecondsSinceEpoch(d.millisecondsSinceEpoch, isUtc: true).toIso8601String();

/// One item's user data after a change, as the server would have it. Returns a new Map.
LocalUserData applyLocalChange(LocalUserData? ud, LocalChange change, DateTime now) {
  final out = <String, Object?>{...?ud};
  final at = _iso(now);
  switch (change['kind']) {
    case 'favorite':
      out['IsFavorite'] = change['favorite'];
    case 'play':
      out['Played'] = true;
      out['PlayCount'] = ((out['PlayCount'] as num?) ?? 0) + 1;
      out['LastPlayedDate'] = at;
    case 'position':
      out['PlaybackPositionTicks'] = change['ticks'];
      out['LastPlayedDate'] = at;
    case 'played':
      out['Played'] = change['played'];
      out['PlaybackPositionTicks'] = 0;
      if (change['played'] == true) out['LastPlayedDate'] = at;
  }
  return out;
}

/// Writes an item's user data into every copy the catalog keeps of it: its file's, its album's or playlist's, its show's or season's.
void setLocalUserData(OfflineIndex index, String itemId, LocalUserData ud) {
  final copies = [
    if (index.tracks[itemId] != null) index.tracks[itemId]!.item,
    for (final c in index.collections)
      if (c.item['Id'] == itemId) c.item,
    if (index.containers[itemId] != null) index.containers[itemId]!,
  ];
  for (final item in copies) {
    item['UserData'] = {...ud};
  }
}

/// Stored user data by item id, checked; an id that is not a plain id is dropped.
Map<String, LocalUserData> parseUserData(Object? raw) {
  final out = <String, LocalUserData>{};
  if (raw is! Map) return out;
  for (final e in raw.entries) {
    final v = e.value;
    if (!isSafeId(e.key) || v is! Map) continue;
    final ud = <String, Object?>{};
    if (v['IsFavorite'] is bool) ud['IsFavorite'] = v['IsFavorite'];
    if (v['Played'] is bool) ud['Played'] = v['Played'];
    if (_finite(v['PlayCount']) && (v['PlayCount'] as num) >= 0) ud['PlayCount'] = (v['PlayCount'] as num).floor();
    if (_finite(v['PlaybackPositionTicks']) && (v['PlaybackPositionTicks'] as num) >= 0) {
      ud['PlaybackPositionTicks'] = (v['PlaybackPositionTicks'] as num).round();
    }
    if (v['LastPlayedDate'] is String) {
      final d = DateTime.tryParse(v['LastPlayedDate'] as String);
      if (d != null) ud['LastPlayedDate'] = _iso(d);
    }
    if (ud.isNotEmpty) out[e.key as String] = ud;
  }
  return out;
}
