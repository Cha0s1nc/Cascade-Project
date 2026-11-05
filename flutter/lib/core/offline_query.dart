// The offline stand-in for the server: a request (path plus params) answered
// from the catalog (offline_index.dart) in Jellyfin's response shape, so the
// screens run unchanged in Offline Mode. Pure. Ported from
// desktop/src/core/offline-query.ts; both pass shared/fixtures/offline-query.json.
//
// It answers exactly the routes and params the screens send, and nothing
// speculative. Anything else answers an empty list marked unknownRoute, never a
// network call. Only what is on disk is answered. Sorting compares lowercased
// text by code point, so the desktop and Apple apps order things identically.
import 'dart:math';

import 'jellyfin.dart' show Item;
import 'offline_index.dart';

/// An answer: [status] 200, or 404 for an id the catalog does not hold. [unknownRoute] means the route is not one the engine knows and the body is an empty list.
typedef OfflineAnswer = ({int status, Object? body, bool unknownRoute});

typedef _Params = Map<String, String>;

/// A resolved catalog entry: the item as the screens see it, plus what the filters match on (every id normalized).
class _Entry {
  final Item item;
  final String key;
  final List<String> libraries, parents, artistIds, albumArtistIds, genreIds;

  /// A genre's item types, lowercased, for /Genres?IncludeItemTypes=.
  final List<String> types;
  const _Entry(
    this.item,
    this.key, {
    this.libraries = const [],
    this.parents = const [],
    this.artistIds = const [],
    this.albumArtistIds = const [],
    this.genreIds = const [],
    this.types = const [],
  });
}

const _emptyList = {'Items': [], 'TotalRecordCount': 0, 'StartIndex': 0};
OfflineAnswer _notFound() => (status: 404, body: null, unknownRoute: false);
OfflineAnswer _ok(Object? body) => (status: 200, body: body, unknownRoute: false);

/// Jellyfin ids compare without case or dashes ("N" and "D" GUID formats).
String _normId(String id) => id.toLowerCase().replaceAll('-', '');

List<String> _uniq(List<String> xs) => xs.length < 2 ? xs : xs.toSet().toList();

/// The placeholder libraries' ids, which Offline Mode adds to the libraries a screen fans out over.
List<String> placeholderLibraryIds() => placeholderLibraries.values.map((l) => l['Id']!).toList();

// Requests ---------------------------------------------------------------------

String _jsString(Object v) => v is num && v == v.truncateToDouble() && v.isFinite ? v.toInt().toString() : '$v';

({List<String> segments, _Params params}) _readParams(String path, Map<String, Object?> params) {
  final out = <String, String>{};
  final q = path.indexOf('?');
  if (q >= 0) {
    try {
      Uri.splitQueryString(path.substring(q + 1)).forEach((k, v) => out[k.toLowerCase()] = v);
    } catch (_) {}
    path = path.substring(0, q);
  }
  params.forEach((k, v) {
    if (v == null) return;
    out[k.toLowerCase()] = v is List ? v.map((x) => _jsString(x!)).join(',') : _jsString(v);
  });
  return (segments: path.split('/').where((s) => s.isNotEmpty).toList(), params: out);
}

final _comma = RegExp(',');
final _pipe = RegExp(r'\|');

List<String> _list(_Params p, String key, [RegExp? sep]) => (p[key] ?? '').split(sep ?? _comma).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

bool? _bool(_Params p, String key) {
  final v = (p[key] ?? '').toLowerCase();
  return v == 'true'
      ? true
      : v == 'false'
      ? false
      : null;
}

// JS Number(): '' is 0, junk is NaN.
double _number(String? s) => s == null ? double.nan : (s.trim().isEmpty ? 0 : (double.tryParse(s.trim()) ?? double.nan));

int? _int(_Params p, String key) {
  final n = _number(p[key]);
  return p.containsKey(key) && n.isFinite && n == n.truncateToDouble() && n >= 0 ? n.toInt() : null;
}

String? _parentOf(_Params p) => p.containsKey('parentid') ? _normId(p['parentid']!) : null;
Set<String> _typesOf(_Params p) => _list(p, 'includeitemtypes').map((t) => t.toLowerCase()).toSet();
String _typeOf(_Entry e) => ((e.item['Type'] as String?) ?? 'Audio').toLowerCase();

// The catalog as entries ---------------------------------------------------------

List<String> _ids(Object? list) => list is List ? [for (final x in list) _normId((x as Map)['Id'])] : const [];

num? _time(Object? s) => s is String && s.isNotEmpty ? DateTime.tryParse(s)?.millisecondsSinceEpoch : null;

/// What the engine sees: every ready media item, and, built on first use, the albums, playlists, shows, artists and genres they imply.
class _Catalog {
  final OfflineIndex index;
  final List<_Entry> media = [];
  final Map<String, _Entry> _mediaById = {};

  _Catalog(this.index) {
    final playlistsOf = <String, List<String>>{};
    for (final c in index.collections) {
      if (c.item['Type'] != 'Playlist') continue;
      final key = _normId(c.item['Id']);
      for (final id in c.trackIds) {
        (playlistsOf[id] ??= []).add(key);
      }
    }
    // Ids in a fixed order (normalized, then by code unit), since an album made from its tracks takes the first track's fields.
    final ready = [
      for (final id in index.tracks.keys)
        if (index.tracks[id]!.file != null) (_normId(id), id),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final stored = index.libraries.map((l) => l['Id']).toSet();
    for (final (key, id) in ready) {
      final t = index.tracks[id]!;
      final item = t.item;
      final library = t.library != null && stored.contains(t.library) ? t.library! : libraryOf(index, id)!;
      final parents = [...?playlistsOf[id]];
      for (final f in ['AlbumId', 'SeriesId', 'SeasonId']) {
        final v = item[f];
        if (v is String && v.isNotEmpty) parents.add(_normId(v));
      }
      final albumArtistIds = _ids(item['AlbumArtists']);
      final e = _Entry(
        item,
        key,
        libraries: [_normId(library)],
        parents: parents,
        artistIds: _uniq([..._ids(item['ArtistItems']), ...albumArtistIds]),
        albumArtistIds: albumArtistIds,
        genreIds: _ids(item['GenreItems']),
      );
      media.add(e);
      _mediaById[e.key] = e;
    }
  }

  late final List<_Entry> albums = _buildAlbums();
  late final _Playlists _playlistParts = _buildPlaylists();
  late final List<_Entry> containers = _buildContainers();
  late final List<_Entry> artists = _people((i) {
    final a = i['ArtistItems'], b = i['AlbumArtists'];
    return a is List && b is List ? [...a, ...b] : (a ?? b) as List?;
  });
  late final List<_Entry> albumArtists = _people((i) => i['AlbumArtists'] as List?);
  late final List<_Entry> musicGenres = _genreList([...media.where((e) => _typeOf(e) == 'audio'), ...albums], 'MusicGenre');
  late final List<_Entry> genres = _genreList([...media, ...albums, ...containers.where((c) => c.item['Type'] == 'Series')], 'Genre');

  List<_Entry> get playlists => _playlistParts.list;

  /// A playlist's ready tracks in playlist order.
  List<_Entry>? playlistTracks(String key) => _playlistParts.tracks[key];

  List<_Entry> _buildAlbums() {
    final stored = {
      for (final c in index.collections)
        if (c.item['Type'] == 'MusicAlbum') _normId(c.item['Id']): c.item,
    };
    final byAlbum = <String, List<_Entry>>{};
    for (final e in media) {
      final t = e.item['Type'];
      if ((t != 'Audio' && t != null) || e.item['AlbumId'] is! String || (e.item['AlbumId'] as String).isEmpty) continue;
      (byAlbum[_normId(e.item['AlbumId'])] ??= []).add(e);
    }
    final keys = byAlbum.keys.toList()..sort(_cmpText);
    return [
      for (final key in keys)
        () {
          final tracks = byAlbum[key]!;
          final first = tracks.first.item;
          final item = <String, dynamic>{
            ...stored[key] ??
                {
                  'Id': first['AlbumId'],
                  'Name': ?first['Album'],
                  'Type': 'MusicAlbum',
                  'AlbumArtist': ?first['AlbumArtist'],
                  if (first['AlbumArtists'] != null) 'AlbumArtists': first['AlbumArtists'],
                  if (first['ProductionYear'] != null) 'ProductionYear': first['ProductionYear'],
                  if (first['AlbumPrimaryImageTag'] is String && (first['AlbumPrimaryImageTag'] as String).isNotEmpty)
                    'ImageTags': {'Primary': first['AlbumPrimaryImageTag']},
                  'ChildCount': tracks.length,
                },
          };
          final genres = <String, Map>{};
          for (final t in tracks) {
            for (final g in (t.item['GenreItems'] as List? ?? const [])) {
              genres.putIfAbsent(_normId((g as Map)['Id']), () => g);
            }
          }
          if (item['DateCreated'] == null || item['DateCreated'] == '') {
            final d = _dateCreatedOf(tracks);
            if (d != null) item['DateCreated'] = d;
          }
          if (item['GenreItems'] == null && genres.isNotEmpty) {
            item['GenreItems'] = genres.values.toList();
            item['Genres'] = [for (final g in genres.values) (g['Name'] as String?) ?? ''];
          }
          final artistIds = {..._ids(item['AlbumArtists']), ..._ids(item['ArtistItems'])};
          final albumArtistIds = {..._ids(item['AlbumArtists'])};
          final libraries = <String>{};
          for (final t in tracks) {
            artistIds.addAll(t.artistIds);
            albumArtistIds.addAll(t.albumArtistIds);
            libraries.addAll(t.libraries);
          }
          return _Entry(
            item,
            key,
            libraries: libraries.toList(),
            artistIds: artistIds.toList(),
            albumArtistIds: albumArtistIds.toList(),
            genreIds: _uniq([..._ids(item['GenreItems']), ...genres.keys]),
          );
        }(),
    ];
  }

  _Playlists _buildPlaylists() {
    final list = <_Entry>[];
    final tracksOf = <String, List<_Entry>>{};
    final sorted = [...index.collections]..sort((a, b) => _cmpText(a.item['Id'], b.item['Id']));
    for (final c in sorted) {
      if (c.item['Type'] != 'Playlist') continue;
      final tracks = [for (final id in c.trackIds) ?_mediaById[_normId(id)]];
      if (tracks.isEmpty) continue;
      final key = _normId(c.item['Id']);
      list.add(_Entry({...c.item, 'ChildCount': tracks.length}, key));
      tracksOf[key] = tracks;
    }
    return (list: list, tracks: tracksOf);
  }

  /// Series and seasons with a ready episode. A season the catalog has no container for is made from the episode's own fields.
  List<_Entry> _buildContainers() {
    final episodes = media.where((e) => e.item['Type'] == 'Episode');
    final made = <String, Item>{};
    final under = <String, List<_Entry>>{};
    for (final e in episodes) {
      final ep = e.item;
      final series = ep['SeriesId'];
      if (series is String && series.isNotEmpty) {
        final key = _normId(series);
        made.putIfAbsent(key, () => index.containers[series] ?? {'Id': series, 'Name': ?ep['SeriesName'], 'Type': 'Series'});
        (under[key] ??= []).add(e);
      }
      final season = ep['SeasonId'];
      if (season is String && season.isNotEmpty) {
        final key = _normId(season);
        made.putIfAbsent(
          key,
          () =>
              index.containers[season] ??
              {
                'Id': season,
                'Name': ?ep['SeasonName'],
                'Type': 'Season',
                'SeriesId': ?ep['SeriesId'],
                'SeriesName': ?ep['SeriesName'],
                if (ep['ParentIndexNumber'] != null) 'IndexNumber': ep['ParentIndexNumber'],
              },
        );
        (under[key] ??= []).add(e);
      }
    }
    final keys = made.keys.toList()..sort(_cmpText);
    return [
      for (final key in keys)
        () {
          var item = made[key]!;
          final eps = under[key] ?? const <_Entry>[];
          if (item['Type'] == 'Series' && (item['DateCreated'] == null || item['DateCreated'] == '')) {
            final d = _dateCreatedOf(eps);
            if (d != null) item = {...item, 'DateCreated': d};
          }
          return _Entry(
            item,
            key,
            libraries: _uniq([for (final x in eps) ...x.libraries]),
            parents: item['Type'] == 'Season' && item['SeriesId'] is String && (item['SeriesId'] as String).isNotEmpty ? [_normId(item['SeriesId'])] : const [],
            genreIds: _ids(item['GenreItems']),
          );
        }(),
    ];
  }

  /// Artists, derived from what is downloaded: the catalog only has names and ids on the tracks.
  List<_Entry> _people(List? Function(Item) pick) {
    final found = <String, ({Map first, Set<String> libs})>{};
    for (final e in media) {
      for (final a in (pick(e.item) ?? const [])) {
        final key = _normId((a as Map)['Id']);
        final f = found.putIfAbsent(key, () => (first: a, libs: <String>{}));
        f.libs.addAll(e.libraries);
      }
    }
    final keys = found.keys.toList()..sort(_cmpText);
    return [
      for (final key in keys)
        _Entry({'Id': found[key]!.first['Id'], 'Name': found[key]!.first['Name'] ?? '', 'Type': 'MusicArtist'}, key, libraries: found[key]!.libs.toList()),
    ];
  }

  List<_Entry> _genreList(List<_Entry> from, String type) {
    final found = <String, ({Map item, Set<String> libs, Set<String> types})>{};
    for (final e in from) {
      for (final g in (e.item['GenreItems'] as List? ?? const [])) {
        final key = _normId((g as Map)['Id']);
        final f = found.putIfAbsent(key, () => (item: g, libs: <String>{}, types: <String>{}));
        f.libs.addAll(e.libraries);
        f.types.add(_typeOf(e));
      }
    }
    final keys = found.keys.toList()..sort(_cmpText);
    return [
      for (final key in keys)
        _Entry(
          {'Id': found[key]!.item['Id'], 'Name': found[key]!.item['Name'] ?? '', 'Type': type},
          key,
          libraries: found[key]!.libs.toList(),
          types: found[key]!.types.toList(),
        ),
    ];
  }

  /// Everything /Items may list, or with [types] (lowercased) only the parts that can hold those types. Artists and genres only when asked for by type or id.
  List<_Entry> all(bool withPeople, [Set<String> types = const {}]) {
    bool want(List<String> kinds) => types.isEmpty || kinds.any(types.contains);
    return [
      if (want(['audio', 'movie', 'episode'])) ...media,
      if (want(['musicalbum'])) ...albums,
      if (want(['playlist'])) ...playlists,
      if (want(['series', 'season'])) ...containers,
      if (withPeople && want(['musicartist'])) ...artists,
      if (withPeople && want(['musicgenre'])) ...musicGenres,
    ];
  }

  /// One entry by (normalized) id: a file, then what it implies.
  _Entry? byId(String key) {
    final m = _mediaById[key];
    if (m != null) return m;
    for (final list in [albums, playlists, containers, artists, albumArtists, musicGenres, genres]) {
      for (final e in list) {
        if (e.key == key) return e;
      }
    }
    return null;
  }

  Item? libraryView(String id) {
    for (final l in librariesInUse(index)) {
      if (_normId(l['Id']!) == id) return {'Id': l['Id'], 'Name': l['Name'], 'CollectionType': l['CollectionType'], 'Type': 'CollectionFolder'};
    }
    return null;
  }

  /// Whether a (normalized) id is a library: a stored one or a placeholder.
  bool isLibrary(String id) => index.libraries.any((l) => _normId(l['Id']!) == id) || placeholderLibraryIds().any((l) => _normId(l) == id);
}

typedef _Playlists = ({List<_Entry> list, Map<String, List<_Entry>> tracks});

/// The newest DateCreated among some entries.
String? _dateCreatedOf(List<_Entry> entries) {
  String? best;
  num bestTime = double.negativeInfinity;
  for (final e in entries) {
    final t = _time(e.item['DateCreated']);
    if (t != null && t > bestTime) {
      best = e.item['DateCreated'] as String;
      bestTime = t;
    }
  }
  return best;
}

// Sorting ----------------------------------------------------------------------

/// Lowercased text by code point: the same order on every system.
int _cmpText(String a, String b) {
  if (a == b) return 0;
  final x = a.toLowerCase().runes.toList(), y = b.toLowerCase().runes.toList();
  final n = min(x.length, y.length);
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return x.length == y.length ? 0 : (x.length > y.length ? 1 : -1);
}

/// One SortBy key's value (a String, a number or null). Null sorts first ascending, as Jellyfin's do.
Object? _sortValue(Item i, String key) {
  final ud = i['UserData'] as Map?;
  switch (key) {
    case 'sortname':
      return i['SortName'] ?? i['Name'] ?? '';
    case 'name':
      return i['Name'] ?? '';
    case 'album':
      return i['Album'] ?? '';
    case 'albumartist':
      return i['AlbumArtist'] ?? ((i['Artists'] as List?)?.isNotEmpty == true ? (i['Artists'] as List).first : null) ?? '';
    case 'datecreated':
      return _time(i['DateCreated']);
    case 'dateplayed':
      return _time(ud?['LastPlayedDate']);
    case 'playcount':
      return ud?['PlayCount'] ?? 0;
    case 'productionyear':
      return i['ProductionYear'];
    case 'parentindexnumber':
      return i['ParentIndexNumber'];
    case 'indexnumber':
      return i['IndexNumber'];
    case 'communityrating':
      return i['CommunityRating'];
    case 'runtime':
      return i['RunTimeTicks'];
  }
  return null;
}

const _sortKeys = {
  'sortname',
  'name',
  'album',
  'albumartist',
  'datecreated',
  'dateplayed',
  'playcount',
  'productionyear',
  'parentindexnumber',
  'indexnumber',
  'communityrating',
  'runtime',
};

int _compareValues(Object? a, Object? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  if (a is String && b is String) return _cmpText(a, b);
  if (a is num && b is num) return a < b ? -1 : (a > b ? 1 : 0);
  return 0;
}

/// Sorts by Jellyfin SortBy keys (unknown ones ignored) and SortOrder (one for all, or one per key), the id breaking any tie. Random shuffles with [random].
List<_Entry> _sortEntries(List<_Entry> entries, _Params p, double Function() random, List<String> fallback) {
  final keys = _list(p, 'sortby').map((k) => k.toLowerCase()).toList();
  if (keys.contains('random')) {
    final out = [...entries];
    for (var i = out.length - 1; i > 0; i--) {
      final j = min((random() * (i + 1)).floor(), i);
      final t = out[i];
      out[i] = out[j];
      out[j] = t;
    }
    return out;
  }
  final orders = _list(p, 'sortorder').map((o) => o.toLowerCase() == 'descending' ? -1 : 1).toList();
  final chosen = (keys.isNotEmpty ? keys : fallback).where(_sortKeys.contains).toList();
  final values = [
    for (final e in entries) [for (final k in chosen) _sortValue(e.item, k)],
  ];
  final order = List.generate(entries.length, (i) => i)
    ..sort((x, y) {
      for (var k = 0; k < chosen.length; k++) {
        final c = _compareValues(values[x][k], values[y][k]);
        if (c != 0) return c * (k < orders.length ? orders[k] : (orders.isNotEmpty ? orders[0] : 1));
      }
      final t = _cmpText(entries[x].item['Id'], entries[y].item['Id']);
      return t != 0 ? t : x.compareTo(y);
    });
  return [for (final i in order) entries[i]];
}

Map<String, Object?> _page(List<_Entry> entries, _Params p) {
  final start = _int(p, 'startindex') ?? 0;
  final limit = _int(p, 'limit');
  final from = min(start, entries.length);
  final to = limit == null ? entries.length : min(start + limit, entries.length);
  return {
    'Items': [for (final e in entries.sublist(from, max(from, to))) e.item],
    'TotalRecordCount': entries.length,
    'StartIndex': start,
  };
}

// Filters ----------------------------------------------------------------------

const _foldFrom =
    'ÀÁÂÃÄÅàáâãäåÇçÈÉÊËèéêëÌÍÎÏìíîïÑñÒÓÔÕÖòóôõöÙÚÛÜùúûüÝýÿĀāĂăĄąĆćĈĉĊċČčĎďĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĨĩĪīĬĭĮįİĴĵĶķĹĺĻļĽľŃńŅņŇňŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽž';
const _foldTo =
    'AAAAAAaaaaaaCcEEEEeeeeIIIIiiiiNnOOOOOoooooUUUUuuuuYyyAaAaAaCcCcCcCcDdEeEeEeEeEeGgGgGgGgHhIiIiIiIiIJjKkLlLlLlNnNnNnOoOoOoRrRrRrSsSsSsSsTtTtUuUuUuUuUuUuWwYyYZzZzZz';
final _foldMap = {for (var i = 0; i < _foldFrom.length; i++) _foldFrom[i]: _foldTo[i]};
final _marks = RegExp('[̀-ͯ]');

// ponytail: Dart has no Unicode normalization, so this folds Latin-1 and Latin Extended-A accents (what NFD plus stripping marks does there), not every script.
String _fold(String s) => s.split('').map((c) => _foldMap[c] ?? c).join().replaceAll(_marks, '').toLowerCase();

bool _meets(List<String> have, Set<String> want) => have.any(want.contains);

/// The filters /Items and the artist and genre lists share.
List<_Entry> _filterEntries(List<_Entry> entries, _Params p) {
  Set<String> wanted(String key) => _list(p, key).map(_normId).toSet();
  final artistIds = wanted('artistids'), albumArtistIds = wanted('albumartistids'), genreIds = wanted('genreids');
  final genreNames = _list(p, 'genres', _pipe).map(_fold).toSet();
  final artistNames = _list(p, 'artists', _pipe).map(_fold).toSet();
  final years = {
    for (final y in _list(p, 'years'))
      if (_number(y).isFinite && _number(y) == _number(y).truncateToDouble()) _number(y).toInt(),
  };
  final term = _fold(p['searchterm'] ?? '').trim();
  final filters = _list(p, 'filters').map((f) => f.toLowerCase()).toSet();
  final favorite = _bool(p, 'isfavorite') ?? (filters.contains('isfavorite') ? true : null);
  final played = _bool(p, 'isplayed') ?? (filters.contains('isplayed') ? true : (filters.contains('isunplayed') ? false : null));
  final resumable = filters.contains('isresumable');
  final any =
      artistIds.isNotEmpty ||
      albumArtistIds.isNotEmpty ||
      genreIds.isNotEmpty ||
      genreNames.isNotEmpty ||
      artistNames.isNotEmpty ||
      years.isNotEmpty ||
      term.isNotEmpty ||
      favorite != null ||
      played != null ||
      resumable;
  if (!any) return entries;

  return entries.where((e) {
    final item = e.item;
    final ud = item['UserData'] as Map?;
    if (artistIds.isNotEmpty && !_meets(e.artistIds, artistIds)) return false;
    if (albumArtistIds.isNotEmpty && !_meets(e.albumArtistIds, albumArtistIds)) return false;
    if (genreIds.isNotEmpty && !_meets(e.genreIds, genreIds)) return false;
    if (genreNames.isNotEmpty && !((item['Genres'] as List?) ?? const []).any((n) => genreNames.contains(_fold('$n')))) return false;
    if (artistNames.isNotEmpty && ![...((item['Artists'] as List?) ?? const []), item['AlbumArtist'] ?? ''].any((n) => artistNames.contains(_fold('$n')))) {
      return false;
    }
    if (years.isNotEmpty &&
        !(item['ProductionYear'] is num &&
            years.contains((item['ProductionYear'] as num).toInt()) &&
            item['ProductionYear'] == (item['ProductionYear'] as num).toInt())) {
      return false;
    }
    if (term.isNotEmpty && !_fold('${item['Name'] ?? ''}').contains(term)) return false;
    if (favorite != null && (ud?['IsFavorite'] == true) != favorite) return false;
    if (played != null && (ud?['Played'] == true) != played) return false;
    if (resumable && !(((ud?['PlaybackPositionTicks'] as num?) ?? 0) > 0)) return false;
    return true;
  }).toList();
}

List<_Entry> _inLibrary(List<_Entry> entries, String? parent) => parent == null ? entries : entries.where((e) => e.libraries.contains(parent)).toList();

// Routes -----------------------------------------------------------------------

OfflineAnswer _items(_Catalog c, _Params p, double Function() random) {
  final types = _typesOf(p);
  final idList = _list(p, 'ids').map(_normId).toList();
  final parent = _parentOf(p);
  final wantsPeople = idList.isNotEmpty || types.contains('musicartist') || types.contains('musicgenre');
  var entries = c.all(wantsPeople, types);
  var fallback = ['sortname'];

  if (idList.isNotEmpty) {
    final set = idList.toSet();
    entries = entries.where((e) => set.contains(e.key)).toList();
  }
  if (parent != null) {
    final playlist = c.playlistTracks(parent);
    if (types.length == 1 && types.contains('playlist') && playlist == null) {
      // Jellyfin 12: playlists holding the parent's items.
      final under = c.media.where((e) => e.parents.contains(parent) || e.libraries.contains(parent)).map((e) => e.key).toSet();
      entries = entries.where((e) => e.item['Type'] == 'Playlist' && (c.playlistTracks(e.key) ?? const []).any((t) => under.contains(t.key))).toList();
    } else if (playlist != null) {
      final present = entries.map((e) => e.key).toSet();
      entries = playlist.where((t) => present.contains(t.key)).toList();
      fallback = [];
    } else if (c.isLibrary(parent)) {
      entries = _inLibrary(entries.where((e) => e.item['Type'] != 'Playlist').toList(), parent);
    } else {
      // An album, series or season: in disc and track (or season and episode) order unless a sort is asked for.
      entries = entries.where((e) => e.parents.contains(parent)).toList();
      fallback = ['parentindexnumber', 'indexnumber', 'sortname'];
    }
  }
  if (types.isNotEmpty) entries = entries.where((e) => types.contains(_typeOf(e))).toList();
  entries = _filterEntries(entries, p);
  // A playlist keeps its own order unless a sort is asked for.
  final sorted = fallback.isNotEmpty || p.containsKey('sortby') ? _sortEntries(entries, p, random, fallback) : entries;
  return _ok(_page(sorted, p));
}

OfflineAnswer _oneItem(_Catalog c, String id) {
  final e = c.byId(id);
  if (e != null) return _ok(e.item);
  final view = c.libraryView(id);
  return view != null ? _ok(view) : _notFound();
}

OfflineAnswer _latest(_Catalog c, _Params p) {
  final types = _typesOf(p);
  var entries = _inLibrary(c.media, _parentOf(p));
  if (types.isNotEmpty) entries = entries.where((e) => types.contains(_typeOf(e))).toList();
  final sorted = _sortEntries(entries, {'sortby': 'DateCreated', 'sortorder': 'Descending'}, () => 0, []);
  return _ok([for (final e in sorted.take(_int(p, 'limit') ?? 20)) e.item]);
}

OfflineAnswer _queryFilters(_Catalog c, _Params p) {
  final types = _typesOf(p);
  var entries = _inLibrary(c.all(false, types), _parentOf(p));
  if (types.isNotEmpty) entries = entries.where((e) => types.contains(_typeOf(e))).toList();
  List<String> sortedUniq(Iterable<String> xs) => xs.toSet().toList()..sort(_cmpText);
  final years = <num>{
    for (final e in entries)
      if (e.item['ProductionYear'] is num) e.item['ProductionYear'] as num,
  }.toList()..sort();
  return _ok({
    'Genres': sortedUniq([for (final e in entries) ...((e.item['Genres'] as List?) ?? const []).cast<String>()]),
    'Tags': [],
    'OfficialRatings': sortedUniq([
      for (final e in entries)
        if (e.item['OfficialRating'] is String && (e.item['OfficialRating'] as String).isNotEmpty) e.item['OfficialRating'] as String,
    ]),
    'Years': years,
  });
}

OfflineAnswer _views(_Catalog c) {
  final out = [
    for (final v in librariesInUse(c.index)) {'Id': v['Id'], 'Name': v['Name'], 'CollectionType': v['CollectionType'], 'Type': 'CollectionFolder'},
  ];
  return _ok({'Items': out, 'TotalRecordCount': out.length, 'StartIndex': 0});
}

OfflineAnswer _user(_Catalog c, String id) {
  final u = c.index.user;
  if (u == null || (id != 'me' && _normId(u['Id']) != id)) return _notFound();
  return _ok({'Id': u['Id'], 'Name': u['Name'], 'Policy': u['Policy']});
}

OfflineAnswer _playlistItems(_Catalog c, String id, _Params p) {
  final tracks = c.playlistTracks(id);
  if (tracks == null) return _notFound();
  final withEntryIds = [
    for (final t in tracks) _Entry({...t.item, 'PlaylistItemId': t.item['PlaylistItemId'] ?? t.item['Id']}, t.key),
  ];
  return _ok(_page(withEntryIds, p));
}

OfflineAnswer _playlist(_Catalog c, String id) {
  final tracks = c.playlistTracks(id);
  _Entry? e;
  for (final x in c.playlists) {
    if (x.key == id) e = x;
  }
  if (tracks == null || e == null) return _notFound();
  return _ok({
    'OpenAccess': e.item['IsPublic'] == true,
    'Shares': [],
    'ItemIds': [for (final t in tracks) t.item['Id']],
  });
}

OfflineAnswer _seasons(_Catalog c, String seriesId, _Params p, double Function() random) {
  if (!c.containers.any((e) => e.key == seriesId)) return _notFound();
  final found = c.containers.where((e) => e.item['Type'] == 'Season' && e.parents.contains(seriesId)).toList();
  return _ok(_page(_sortEntries(found, {}, random, ['indexnumber', 'sortname']), p));
}

OfflineAnswer _episodes(_Catalog c, String seriesId, _Params p, double Function() random) {
  if (!c.containers.any((e) => e.key == seriesId)) return _notFound();
  final season = p.containsKey('seasonid') ? _normId(p['seasonid']!) : null;
  final found = c.media.where((e) => e.item['Type'] == 'Episode' && e.parents.contains(seriesId) && (season == null || e.parents.contains(season))).toList();
  return _ok(_page(_sortEntries(found, {}, random, ['parentindexnumber', 'indexnumber', 'sortname']), p));
}

/// Per show, the first unplayed episode after the last played one; shows not started are left out. Most recently watched show first.
OfflineAnswer _nextUp(_Catalog c, _Params p, double Function() random) {
  final onlySeries = p.containsKey('seriesid') ? _normId(p['seriesid']!) : null;
  final resumable = _bool(p, 'enableresumable') != false;
  final found = <({_Entry entry, num last})>[];
  for (final series in _inLibrary(c.containers.where((e) => e.item['Type'] == 'Series').toList(), _parentOf(p))) {
    if (onlySeries != null && series.key != onlySeries) continue;
    final eps = _sortEntries(c.media.where((e) => e.item['Type'] == 'Episode' && e.parents.contains(series.key)).toList(), {}, random, [
      'parentindexnumber',
      'indexnumber',
      'sortname',
    ]);
    var lastPlayed = -1;
    for (var i = 0; i < eps.length; i++) {
      if ((eps[i].item['UserData'] as Map?)?['Played'] == true) lastPlayed = i;
    }
    if (lastPlayed < 0) continue;
    _Entry? next;
    for (final e in eps.skip(lastPlayed + 1)) {
      final ud = e.item['UserData'] as Map?;
      if (ud?['Played'] != true && (resumable || !(((ud?['PlaybackPositionTicks'] as num?) ?? 0) > 0))) {
        next = e;
        break;
      }
    }
    if (next == null) continue;
    num last = 0;
    for (final e in eps) {
      final t = _time((e.item['UserData'] as Map?)?['LastPlayedDate']) ?? 0;
      if (t > last) last = t;
    }
    found.add((entry: next, last: last));
  }
  found.sort((a, b) {
    final c = b.last.compareTo(a.last);
    return c != 0 ? c : _cmpText(a.entry.item['Id'], b.entry.item['Id']);
  });
  return _ok(_page([for (final f in found) f.entry], p));
}

OfflineAnswer _segments(_Catalog c, String id) {
  String? key;
  for (final k in c.index.tracks.keys) {
    if (_normId(k) == id) {
      key = k;
      break;
    }
  }
  final segs = key != null && c.index.tracks[key]!.file != null
      ? c.index.tracks[key]!.segments ?? const <Map<String, Object?>>[]
      : const <Map<String, Object?>>[];
  final out = [
    for (final s in segs) {'ItemId': key, 'Type': s['Type'], 'StartTicks': s['StartTicks'], 'EndTicks': s['EndTicks']},
  ];
  return _ok({'Items': out, 'TotalRecordCount': out.length, 'StartIndex': 0});
}

/// /Artists, /Artists/AlbumArtists, /Persons, /MusicGenres and /Genres: a derived list with the filters those routes take.
OfflineAnswer _derivedList(List<_Entry> from, _Params p, double Function() random) {
  var entries = _filterEntries(_inLibrary(from, _parentOf(p)), p);
  final types = _typesOf(p);
  if (types.isNotEmpty) entries = entries.where((e) => e.types.any(types.contains)).toList();
  return _ok(_page(_sortEntries(entries, p, random, ['sortname']), p));
}

OfflineAnswer _persons(_Catalog c, _Params p, double Function() random) {
  final kinds = _list(p, 'persontypes').map((t) => t.toLowerCase()).toSet();
  if (kinds.isNotEmpty && !kinds.contains('artist') && !kinds.contains('albumartist')) return _ok(_emptyList);
  return _derivedList(kinds.length == 1 && kinds.contains('albumartist') ? c.albumArtists : c.artists, p, random);
}

/// /Items/WORD routes that are not an item id.
const _reserved = {'latest', 'filters', 'filters2', 'root', 'counts', 'resume'};
final _idLike = RegExp(r'^[a-z0-9-]+$');

OfflineAnswer _route(_Catalog c, String path, Map<String, Object?> params, double Function() random) {
  final r = _readParams(path, params);
  final seg = r.segments, p = r.params;
  final s = seg.map((x) => x.toLowerCase()).toList();
  String id(int i) => _normId(seg[i]);

  if (s.length == 1 && s[0] == 'items') return _items(c, p, random);
  if (s.length == 2 && s[0] == 'items' && s[1] == 'latest') return _latest(c, p);
  if (s.length == 2 && s[0] == 'items' && s[1] == 'filters') return _queryFilters(c, p);
  if (s.length == 2 && s[0] == 'items' && _idLike.hasMatch(s[1]) && !_reserved.contains(s[1])) return _oneItem(c, id(1));
  if (s.length == 1 && s[0] == 'userviews') return _views(c);
  if (s.length == 2 && s[0] == 'users' && _idLike.hasMatch(s[1])) return _user(c, s[1] == 'me' ? 'me' : id(1));
  if (s.length == 3 && s[0] == 'playlists' && s[2] == 'items') return _playlistItems(c, id(1), p);
  if (s.length == 2 && s[0] == 'playlists') return _playlist(c, id(1));
  if (s.length == 2 && s[0] == 'shows' && s[1] == 'nextup') return _nextUp(c, p, random);
  if (s.length == 3 && s[0] == 'shows' && s[2] == 'seasons') return _seasons(c, id(1), p, random);
  if (s.length == 3 && s[0] == 'shows' && s[2] == 'episodes') return _episodes(c, id(1), p, random);
  if (s.length == 2 && s[0] == 'mediasegments') return _segments(c, id(1));
  if (s.length == 1 && s[0] == 'artists') return _derivedList(c.artists, p, random);
  if (s.length == 2 && s[0] == 'artists' && s[1] == 'albumartists') return _derivedList(c.albumArtists, p, random);
  if (s.length == 1 && s[0] == 'persons') return _persons(c, p, random);
  if (s.length == 1 && s[0] == 'musicgenres') return _derivedList(c.musicGenres, p, random);
  if (s.length == 1 && s[0] == 'genres') return _derivedList(c.genres, p, random);
  return (status: 200, body: _emptyList, unknownRoute: true);
}

final _rng = Random();

/// An engine over one state of the catalog. Keep it while the catalog is unchanged and make a new one when it changes: what it has built is not rebuilt.
class OfflineQuery {
  final _Catalog _catalog;
  OfflineQuery(OfflineIndex index) : _catalog = _Catalog(index);

  /// Answers one GET. [path] is the route as the apps send it (a query string on it is read too); [params] the query, names in any case. [random] drives SortBy=Random.
  OfflineAnswer answer(String path, [Map<String, Object?> params = const {}, double Function()? random]) =>
      _route(_catalog, path, params, random ?? _rng.nextDouble);
}

/// An engine over one state of the catalog.
OfflineQuery offlineQuery(OfflineIndex index) => OfflineQuery(index);

/// Answers one GET from the catalog as it is now.
OfflineAnswer answerOffline(OfflineIndex index, String path, [Map<String, Object?> params = const {}, double Function()? random]) =>
    offlineQuery(index).answer(path, params, random);
