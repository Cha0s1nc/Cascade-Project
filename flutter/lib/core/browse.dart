// Sorting and filtering for the library grids (Albums, Artists, Playlists,
// Movies, TV Shows) and the day grouping used by History. Pure, returns new
// lists. Ported from desktop/src/core/library-browse.ts.
import 'dart:convert';

import 'jellyfin.dart' show Item;
import 'queue.dart';

num _ms(Object? iso) => iso is String ? (DateTime.tryParse(iso)?.millisecondsSinceEpoch ?? 0) : 0;

String _nameKey(Item item) {
  final s = item['SortName'], n = item['Name'];
  return (s is String && s.isNotEmpty ? s : n is String ? n : '').toLowerCase();
}

Map? _userData(Item item) => item['UserData'] is Map ? item['UserData'] as Map : null;

/// Sort key for an album, artist, playlist, movie or show. Missing values are 0 or ''.
Comparable<Object> librarySortValue(Item item, String field) {
  switch (field) {
    case 'artist':
      return artistKey(item);
    case 'year':
      return (item['ProductionYear'] as num?) ?? 0;
    case 'added':
      return _ms(item['DateCreated']);
    case 'played':
      return _ms(_userData(item)?['LastPlayedDate']);
    case 'count':
      return (item['ChildCount'] as num?) ?? 0;
    default:
      return _nameKey(item);
  }
}

/// Sorts a copy of [items]. 'random' shuffles. Ties break on name in either direction.
List<Item> sortLibraryItems(List<Item> items, String field, String dir) {
  if (field == 'random') return shuffleInPlace([...items]);
  final mul = dir == 'desc' ? -1 : 1;
  final keyed = [for (var i = 0; i < items.length; i++) (i, items[i], librarySortValue(items[i], field))];
  keyed.sort((a, b) {
    final c = compareSortValues(a.$3, b.$3);
    if (c != 0) return c * mul;
    final t = _nameKey(a.$2).compareTo(_nameKey(b.$2));
    return t != 0 ? t : a.$1.compareTo(b.$1);
  });
  return [for (final k in keyed) k.$2];
}

/// Grid filters. [genre] is an exact name, [decade] a start year (1990 is 1990-1999).
class LibraryFilters {
  final bool favorite;
  final String? genre;
  final int? decade;
  final String? played; // 'played' | 'unplayed'
  const LibraryFilters({this.favorite = false, this.genre, this.decade, this.played});
}

/// Whether [item] passes every filter in [f].
bool matchesLibraryFilters(Item item, LibraryFilters f) {
  final ud = _userData(item);
  if (f.favorite && ud?['IsFavorite'] != true) return false;
  if (f.genre != null && f.genre!.isNotEmpty) {
    final g = item['Genres'];
    if (g is! List || !g.contains(f.genre)) return false;
  }
  if (f.decade != null) {
    final y = item['ProductionYear'];
    if (y is! num || (y / 10).floor() * 10 != f.decade) return false;
  }
  if (f.played == 'played' && ud?['Played'] != true) return false;
  if (f.played == 'unplayed' && ud?['Played'] == true) return false;
  return true;
}

/// [items] narrowed by [f]; the same list when nothing is set.
List<Item> filterLibraryItems(List<Item> items, LibraryFilters f) {
  if (!f.favorite && (f.genre == null || f.genre!.isEmpty) && f.decade == null && (f.played == null || f.played!.isEmpty)) return items;
  return items.where((i) => matchesLibraryFilters(i, f)).toList();
}

/// Genres A-Z and decades newest first, only those present in the loaded items.
typedef LibraryFilterOptions = ({List<String> genres, List<int> decades});

LibraryFilterOptions libraryFilterOptions(List<Item> items) {
  final genres = <String>{};
  final decades = <int>{};
  for (final item in items) {
    final g = item['Genres'];
    if (g is List) genres.addAll(g.whereType<String>());
    final y = item['ProductionYear'];
    if (y is num && y != 0) decades.add((y / 10).floor() * 10);
  }
  return (
    // ponytail: case-insensitive code-unit order, not full locale collation
    genres: genres.toList()..sort((a, b) {
      final c = a.toLowerCase().compareTo(b.toLowerCase());
      return c != 0 ? c : a.compareTo(b);
    }),
    decades: decades.toList()..sort((a, b) => b - a),
  );
}

/// A grid's saved sort and filters.
typedef LibraryPrefs = ({String field, String dir, bool favorite, String? genre, int? decade, String? played});

/// Turns whatever is stored back into safe prefs. Bad JSON, an unoffered field, a bad direction or a non-integer decade fall back to defaults.
LibraryPrefs normalizeLibraryPrefs(String? raw, List<String> allowedFields) {
  Map d = const {};
  if (raw != null && raw.isNotEmpty) {
    try {
      final p = jsonDecode(raw);
      if (p is Map) d = p;
    } catch (_) {}
  }
  final f = d['field'], g = d['genre'], dec = d['decade'], pl = d['played'];
  return (
    field: f is String && allowedFields.contains(f) ? f : 'name',
    dir: d['dir'] == 'desc' ? 'desc' : 'asc',
    favorite: d['favorite'] == true,
    genre: g is String && g.isNotEmpty ? g : null,
    decade: dec is num && dec.isFinite ? dec.toInt() : null,
    played: pl == 'played' || pl == 'unplayed' ? pl as String : null,
  );
}

/// One day of History.
typedef DayGroup = ({String label, List<Item> items});

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

String _dayLabel(DateTime day, DateTime today) {
  // Round, not truncate, so a DST day (23 or 25 hours) still counts as one.
  final diff = (today.difference(day).inMinutes / 1440).round();
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final s = '${_months[day.month - 1]} ${day.day}';
  return day.year == today.year ? s : '$s, ${day.year}';
}

/// Groups newest-first items by the local day they were last played. Items with no parseable date are dropped.
List<DayGroup> groupByDay(List<Item> items, [DateTime? now]) {
  final today = _startOfDay(now ?? DateTime.now());
  final labels = <String>[];
  final buckets = <List<Item>>[];
  DateTime? last;
  for (final item in items) {
    final raw = _userData(item)?['LastPlayedDate'];
    final ts = raw is String ? DateTime.tryParse(raw) : null;
    if (ts == null) continue;
    final day = _startOfDay(ts.toLocal());
    if (last == null || day != last) {
      labels.add(_dayLabel(day, today));
      buckets.add([]);
      last = day;
    }
    buckets.last.add(item);
  }
  return [for (var i = 0; i < labels.length; i++) (label: labels[i], items: buckets[i])];
}
