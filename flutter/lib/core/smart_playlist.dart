// User-defined smart playlists: parsing the stored definitions, a Jellyfin
// query prefilter, and the client-side rule check. Pure. Ported from
// desktop/src/core/smart-playlist.ts.
//
// A rule is a Map like {'field': 'genre', 'op': 'is', 'value': 'Rock'} (fields:
// genre, artist, year, addedWithinDays, played, playCount, favorite) and a
// definition is a Map with id, name, match ('all'|'any'), rules, sortBy,
// sortDir, limit. Both are what jsonDecode gives back, so they round-trip.
import 'dart:convert';

import 'jellyfin.dart' show Item;

typedef SmartPlaylistRule = Map<String, Object?>;
typedef SmartPlaylistDef = Map<String, Object?>;

const _sortFields = ['name', 'artist', 'album', 'dateAdded', 'playCount'];
const _maxLimit = 500;
const _defaultLimit = 100;
const _maxDays = 3650;
const _minYear = 1000;
const _maxYear = 2100;
const _dayMs = 24 * 60 * 60 * 1000;

int _clampInt(Object? n, int min, int max, int fallback) {
  if (n is! num || !n.isFinite) return fallback;
  return n.truncate().clamp(min, max);
}

String? _trimmed(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

SmartPlaylistRule? _validateRule(Object? raw) {
  if (raw is! Map) return null;
  switch (raw['field']) {
    case 'genre':
      final v = _trimmed(raw['value']);
      if ((raw['op'] != 'is' && raw['op'] != 'isNot') || v == null) return null;
      return {'field': 'genre', 'op': raw['op'], 'value': v};
    case 'artist':
      final v = _trimmed(raw['value']);
      if (raw['op'] != 'is' || v == null) return null;
      return {'field': 'artist', 'op': 'is', 'value': v};
    case 'year':
      if (raw['op'] != 'between') return null;
      final a = _clampInt(raw['min'], _minYear, _maxYear, _minYear);
      final b = _clampInt(raw['max'], _minYear, _maxYear, _maxYear);
      return {'field': 'year', 'op': 'between', 'min': a < b ? a : b, 'max': a < b ? b : a};
    case 'addedWithinDays':
      if (raw['op'] != 'lte') return null;
      return {'field': 'addedWithinDays', 'op': 'lte', 'days': _clampInt(raw['days'], 1, _maxDays, 30)};
    case 'played':
      if (raw['op'] != 'is' || raw['value'] is! bool) return null;
      return {'field': 'played', 'op': 'is', 'value': raw['value']};
    case 'playCount':
      if (raw['op'] != 'gte') return null;
      return {'field': 'playCount', 'op': 'gte', 'value': _clampInt(raw['value'], 0, 1000000, 1)};
    case 'favorite':
      if (raw['op'] != 'is' || raw['value'] is! bool) return null;
      return {'field': 'favorite', 'op': 'is', 'value': raw['value']};
    default:
      return null;
  }
}

SmartPlaylistDef? _validateDef(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['id'] is String ? (raw['id'] as String).trim() : '';
  final name = raw['name'] is String ? (raw['name'] as String).trim() : '';
  if (id.isEmpty || name.isEmpty) return null;
  final rules = raw['rules'] is List ? [for (final r in raw['rules'] as List) ?_validateRule(r)] : <SmartPlaylistRule>[];
  return {
    'id': id,
    'name': name,
    'match': raw['match'] == 'any' ? 'any' : 'all',
    'rules': rules,
    'sortBy': _sortFields.contains(raw['sortBy']) ? raw['sortBy'] : 'name',
    'sortDir': raw['sortDir'] == 'desc' ? 'desc' : 'asc',
    'limit': _clampInt(raw['limit'], 1, _maxLimit, _defaultLimit),
  };
}

/// Parses the stored `smartPlaylists` value. Never throws: bad JSON, a non-list or a bad entry is dropped.
List<SmartPlaylistDef> parseSmartPlaylists(String? raw) {
  if (raw == null || raw.isEmpty) return [];
  Object? arr;
  try {
    arr = jsonDecode(raw);
  } catch (_) {
    return [];
  }
  return arr is List ? [for (final d in arr) ?_validateDef(d)] : [];
}

/// The definitions as the JSON string to store.
String serializeSmartPlaylists(List<SmartPlaylistDef> defs) => jsonEncode(defs);

List<SmartPlaylistRule> _rules(SmartPlaylistDef def) => [for (final r in (def['rules'] as List? ?? const [])) r as SmartPlaylistRule];

/// Best-effort /Items query params for an ALL match. Only a superset prefilter: matchesRules still decides.
Map<String, Object> toItemsQuery(SmartPlaylistDef def) {
  final params = <String, Object>{};
  if (def['match'] != 'all') return params;
  for (final rule in _rules(def)) {
    final f = rule['field'];
    if (f == 'genre' && rule['op'] == 'is' && !params.containsKey('Genres')) {
      params['Genres'] = rule['value']!;
    } else if (f == 'artist' && !params.containsKey('Artists')) {
      params['Artists'] = rule['value']!;
    } else if (f == 'year' && !params.containsKey('Years') && (rule['max'] as int) - (rule['min'] as int) <= 100) {
      params['Years'] = [for (var y = rule['min'] as int; y <= (rule['max'] as int); y++) y].join(',');
    } else if (f == 'played' && !params.containsKey('IsPlayed')) {
      params['IsPlayed'] = rule['value']!;
    } else if (f == 'favorite' && !params.containsKey('IsFavorite')) {
      params['IsFavorite'] = rule['value']!;
    }
  }
  return params;
}

Map? _ud(Item i) => i['UserData'] is Map ? i['UserData'] as Map : null;
List<String> _strings(Object? v) => v is List ? v.whereType<String>().toList() : const [];

/// Whether [item] satisfies one [rule]. [nowMs] is epoch millis.
bool ruleMatches(Item item, SmartPlaylistRule rule, int nowMs) {
  switch (rule['field']) {
    case 'genre':
      final v = (rule['value'] as String).toLowerCase();
      final has = _strings(item['Genres']).any((g) => g.toLowerCase() == v);
      return rule['op'] == 'is' ? has : !has;
    case 'artist':
      final name = (rule['value'] as String).toLowerCase();
      return _strings(item['Artists']).any((a) => a.toLowerCase() == name) || '${item['AlbumArtist'] ?? ''}'.toLowerCase() == name;
    case 'year':
      final y = item['ProductionYear'];
      return y is num && y >= (rule['min'] as int) && y <= (rule['max'] as int);
    case 'addedWithinDays':
      final raw = item['DateCreated'];
      final created = raw is String ? DateTime.tryParse(raw)?.millisecondsSinceEpoch : null;
      return created != null && nowMs - created <= (rule['days'] as int) * _dayMs;
    case 'played':
      return (_ud(item)?['Played'] == true) == rule['value'];
    case 'playCount':
      return (((_ud(item)?['PlayCount']) as num?) ?? 0) >= (rule['value'] as int);
    case 'favorite':
      return (_ud(item)?['IsFavorite'] == true) == rule['value'];
  }
  return false;
}

/// Whether [item] matches the definition's rules (all or any). No rules matches everything.
bool matchesRules(Item item, SmartPlaylistDef def, int nowMs) {
  final rules = _rules(def);
  if (rules.isEmpty) return true;
  return def['match'] == 'any' ? rules.any((r) => ruleMatches(item, r, nowMs)) : rules.every((r) => ruleMatches(item, r, nowMs));
}

Comparable<Object> _sortKey(Item item, String sortBy) {
  switch (sortBy) {
    // The title, not SortName: a track's SortName starts with its track number.
    case 'name':
      return '${item['Name'] ?? ''}';
    case 'artist':
      final aa = item['AlbumArtist'];
      if (aa is String && aa.isNotEmpty) return aa;
      final a = _strings(item['Artists']);
      return a.isEmpty ? '' : a.first;
    case 'album':
      return '${item['Album'] ?? ''}';
    case 'dateAdded':
      final raw = item['DateCreated'];
      return (raw is String ? DateTime.tryParse(raw)?.millisecondsSinceEpoch : null) ?? 0;
    default:
      return ((_ud(item)?['PlayCount']) as num?) ?? 0;
  }
}

final _digits = RegExp(r'(\d+)');

/// Natural, case-insensitive compare so "Track 10" follows "Track 2".
int naturalCompare(String a, String b) {
  final pa = a.toLowerCase().splitMapJoin(_digits, onMatch: (m) => '\u0000${m[1]!.padLeft(20, '0')}\u0000', onNonMatch: (s) => s);
  final pb = b.toLowerCase().splitMapJoin(_digits, onMatch: (m) => '\u0000${m[1]!.padLeft(20, '0')}\u0000', onNonMatch: (s) => s);
  return pa.compareTo(pb);
}

/// Filters by the full rule check, sorts, and limits. Input is not mutated.
List<Item> applySmartPlaylistRules(List<Item> items, SmartPlaylistDef def, int nowMs) {
  final dir = def['sortDir'] == 'desc' ? -1 : 1;
  final sortBy = '${def['sortBy']}';
  final keyed = [
    for (final item in items)
      if (matchesRules(item, def, nowMs)) (item, _sortKey(item, sortBy)),
  ];
  // Dart's sort is not stable; tie order only matters for equal keys, which JS keeps in input order.
  final order = {for (var i = 0; i < keyed.length; i++) keyed[i].$1: i};
  keyed.sort((a, b) {
    final ka = a.$2, kb = b.$2;
    final c = ka is String ? naturalCompare(ka, kb as String) : (ka as num).compareTo(kb as num);
    return c != 0 ? c * dir : order[a.$1]!.compareTo(order[b.$1]!);
  });
  return [for (final k in keyed.take((def['limit'] as int?) ?? _defaultLimit)) k.$1];
}
