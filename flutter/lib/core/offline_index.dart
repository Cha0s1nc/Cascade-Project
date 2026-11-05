// What is downloaded, as one value: the single source of truth for offline
// playback and Offline Mode's library. Pure, so the rules that decide what a
// removal may delete and what counts as a finished download are tested.
// Ported from desktop/src/core/offline-index.ts (version 2 of the catalog).
// The app owns the files and the one copy on disk; offline_query.dart answers
// the screens' requests from this.
//
// Items are Jellyfin item Maps. Libraries, the user, the history snapshot,
// plays, changes and segments are the JSON Maps the desktop stores, so an
// index round-trips through toJson and parseIndex. Paths are relative to the
// offline folder.
import 'dart:convert';

import 'jellyfin.dart' show Item;
import 'lyrics.dart';
import 'spicy_lyrics.dart' show SpicyContributor, SpicyCredit;

const indexVersion = 2;

/// A saved subtitle's JSON-facing record.
class OfflineSubtitle {
  final int index;
  final String file;
  String? language, title;
  bool? isDefault, isForced;
  OfflineSubtitle(this.index, this.file, {this.language, this.title, this.isDefault, this.isForced});

  Map<String, Object?> toJson() => {'index': index, 'file': file, 'language': ?language, 'title': ?title, 'isDefault': ?isDefault, 'isForced': ?isForced};
}

/// Lyrics saved with a track, already parsed. [expiresAt] is ISO 8601 or null (never).
class OfflineLyrics {
  final String source;
  final bool synced;
  final List<LyricLine> lines;
  final String savedAt;
  final String? expiresAt;
  SpicyCredit? credit;
  OfflineLyrics(this.source, this.synced, this.lines, this.savedAt, this.expiresAt, [this.credit]);

  Map<String, Object?> toJson() => {
    'source': source,
    'synced': synced,
    'lines': lines.map(lyricLineToJson).toList(),
    'savedAt': savedAt,
    'expiresAt': expiresAt,
    if (credit != null) 'credit': _creditJson(credit!),
  };
}

Map<String, Object?>? _wordJson(LyricWord w) => {'Start': w.start, 'End': w.end, 'Text': w.text};

/// A lyric line as the catalog stores it.
Map<String, Object?> lyricLineToJson(LyricLine l) => {
  'Start': l.start,
  'End': l.end,
  'Text': l.text,
  'Words': l.words?.map(_wordJson).toList(),
  if (l.background != null) 'Background': l.background!.map(_wordJson).toList(),
  if (l.opposite) 'Opposite': true,
};

Map<String, Object?>? _contribJson(SpicyContributor? c) => c == null ? null : {'name': c.name, 'url': c.url};

Map<String, Object?> _creditJson(SpicyCredit c) => {'provider': c.provider, 'uploader': _contribJson(c.uploader), 'maker': _contribJson(c.maker)};

/// The source a lyrics result is stored under, from the waterfall's label. A result carrying a credit is SpicyLyrics, whatever its label.
String lyricsSourceKey(String label, bool hasCredit) {
  if (hasCredit) return 'spicy';
  final l = label.toLowerCase();
  if (l.startsWith('kugou')) return 'kugou';
  if (l.startsWith('lrclib')) return 'lrclib';
  if (l.startsWith('jellyfin')) return 'jellyfin';
  return 'cascade';
}

/// How a stored source is named in the lyrics UI.
String lyricsSourceLabel(OfflineLyrics lyrics) {
  if (lyrics.credit != null) return lyrics.credit!.provider;
  return const {'cascade': 'Cascade', 'kugou': 'Kugou', 'lrclib': 'LRCLIB', 'jellyfin': 'Jellyfin'}[lyrics.source] ?? lyrics.source;
}

/// A downloaded media item: a track, a movie or an episode. [file] is "media/ID.ext" once the whole file is on disk, else null. [segments] are `{Type, StartTicks, EndTicks}` Maps.
class OfflineTrack {
  Item item;
  String? file;
  num bytes;
  String? library;
  OfflineLyrics? lyrics;
  List<OfflineSubtitle>? subs;
  List<Map<String, Object?>>? segments;
  bool? explicit;
  String? readyAt, watchedAt;

  /// Video: 'direct', 'remux' or 'reencode'.
  String? outcome;
  int? burnIn;
  OfflineTrack(this.item, this.file, this.bytes);

  Map<String, Object?> toJson() => {
    'item': item,
    'file': file,
    'bytes': bytes,
    'library': ?library,
    if (lyrics != null) 'lyrics': lyrics!.toJson(),
    if (subs != null) 'subs': subs!.map((s) => s.toJson()).toList(),
    'segments': ?segments,
    if (explicit == true) 'explicit': true,
    'readyAt': ?readyAt,
    'watchedAt': ?watchedAt,
    'outcome': ?outcome,
    'burnIn': ?burnIn,
  };
}

/// What the person asked for: an album, playlist, movie, season or series. A track shared by two is stored once.
class OfflineCollection {
  Item item;
  List<String> trackIds;

  /// A series only: follow new episodes since this time (ISO 8601).
  String? follow;

  /// A series only: episodes removed as watched, never fetched again.
  List<String>? skip;
  OfflineCollection(this.item, this.trackIds);

  Map<String, Object?> toJson() => {'item': item, 'trackIds': trackIds, 'follow': ?follow, 'skip': ?skip};
}

/// A library as /UserViews names it: a Map with Id, Name, CollectionType.
typedef OfflineLibraryView = Map<String, String>;

/// A change made offline: `{itemId, userId, at, kind: 'position'|'played'|'favorite', ticks?, played?, favorite?, was?}`.
typedef UserDataChange = Map<String, dynamic>;

/// A play the server never heard about: `{itemId, userId, date}`.
typedef OfflinePlay = Map<String, dynamic>;

/// One row of the server's play history: `{Id, LastPlayedDate, PlayCount}`.
typedef HistoryEntry = Map<String, Object?>;

/// The server's play history when last online: `{takenAt, entries}`.
typedef HistorySnapshot = Map<String, dynamic>;

/// The whole catalog.
class OfflineIndex {
  int version = indexVersion;
  Map<String, OfflineTrack> tracks = {};

  /// Newest first.
  List<OfflineCollection> collections = [];

  /// Series and seasons the downloaded episodes belong to, by id.
  Map<String, Item> containers = {};
  List<OfflineLibraryView> libraries = [];

  /// `{Id, Name, Policy}` or null.
  Map<String, dynamic>? user;
  HistorySnapshot? history;
  List<OfflinePlay> plays = [];

  /// User data changed offline, oldest first.
  List<UserDataChange> changes = [];

  /// The server's history moved on, so the plays wait for the person.
  bool playsHeld = false;

  Map<String, Object?> toJson() => {
    'version': version,
    'tracks': {for (final e in tracks.entries) e.key: e.value.toJson()},
    'collections': collections.map((c) => c.toJson()).toList(),
    'containers': containers,
    'libraries': libraries,
    'user': user,
    'history': history,
    'plays': plays,
    'changes': changes,
    'playsHeld': playsHeld,
  };

  /// JSON text, for comparing two indexes.
  String get json => jsonEncode(toJson());
}

OfflineIndex emptyIndex() => OfflineIndex();

/// Most plays kept while offline.
const maxQueuedPlays = 5000;

/// Rows of play history kept in the snapshot.
const maxHistoryEntries = 200;

/// How long SpicyLyrics may be kept: the plugin's own cache rule.
const spicyLyricsDays = 25;

const _mediaTypes = {'Audio', 'Movie', 'Episode'};
const _collectionTypes = {'MusicAlbum', 'Playlist', 'Movie', 'Episode', 'Season', 'Series'};

bool _isFinite(Object? v) => v is num && v.isFinite;
bool _isMap(Object? v) => v is Map;

int? _parseMs(Object? v) => v is String ? DateTime.tryParse(v)?.millisecondsSinceEpoch : null;

String _iso(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

String? _isoDate(Object? v) {
  final t = _parseMs(v);
  return t == null ? null : _iso(t);
}

// Libraries ------------------------------------------------------------------

/// Where items with no known library go: one placeholder per kind.
const placeholderLibraries = <String, OfflineLibraryView>{
  'Audio': {'Id': 'cascade-offline-music', 'Name': 'Downloads', 'CollectionType': 'music'},
  'Movie': {'Id': 'cascade-offline-movies', 'Name': 'Downloaded Movies', 'CollectionType': 'movies'},
  'Episode': {'Id': 'cascade-offline-shows', 'Name': 'Downloaded Shows', 'CollectionType': 'tvshows'},
};

bool isPlaceholderLibrary(String id) => placeholderLibraries.values.any((l) => l['Id'] == id);

final _libId = RegExp(r'^[A-Za-z0-9-]{1,64}$');
final _dashes = RegExp(r'^-+$');

/// A library id: a GUID with or without dashes, or a placeholder's.
bool isSafeLibraryId(Object? id) => id is String && _libId.hasMatch(id) && !_dashes.hasMatch(id);

OfflineLibraryView _placeholderFor(Item item) => item['Type'] == 'Movie'
    ? placeholderLibraries['Movie']!
    : item['Type'] == 'Episode'
    ? placeholderLibraries['Episode']!
    : placeholderLibraries['Audio']!;

/// The library a downloaded item belongs to: the one it came from when known and still listed, else its kind's placeholder. Null for an unknown track.
String? libraryOf(OfflineIndex index, String trackId) {
  final t = index.tracks[trackId];
  if (t == null) return null;
  if (t.library != null && index.libraries.any((l) => l['Id'] == t.library)) return t.library;
  return _placeholderFor(t.item)['Id'];
}

/// Items still in a placeholder library, sorted, for the online lookup to place.
List<String> unplacedTrackIds(OfflineIndex index) => (index.tracks.keys.where((id) => isPlaceholderLibrary(libraryOf(index, id) ?? '')).toList()..sort());

/// Unplaced items grouped by what they share a library with: a track by its album, an episode by its show, anything else by itself.
Map<String, List<String>> placementGroups(OfflineIndex index, List<String> trackIds) {
  final groups = <String, List<String>>{};
  for (final id in trackIds) {
    final item = index.tracks[id]?.item;
    if (item == null) continue;
    final key = [item['AlbumId'], item['SeriesId'], id].firstWhere(isSafeId, orElse: () => id) as String;
    groups[key] = [...?groups[key], id];
  }
  return groups;
}

/// The stored library among an item's ancestors (a bare array, nearest first), or null.
String? libraryFromAncestors(OfflineIndex index, Object? ancestors) {
  if (ancestors is! List) return null;
  final stored = index.libraries.map((l) => l['Id']).toSet();
  for (final a in ancestors) {
    if (a is Map && a['Id'] is String && stored.contains(a['Id'])) return a['Id'] as String;
  }
  return null;
}

/// The libraries Offline Mode lists: every stored library holding a downloaded item, then each placeholder that holds one.
List<OfflineLibraryView> librariesInUse(OfflineIndex index) {
  final used = index.tracks.keys.map((id) => libraryOf(index, id)).toSet();
  return [...index.libraries.where((l) => used.contains(l['Id'])), ...placeholderLibraries.values.where((l) => used.contains(l['Id']))];
}

/// Stores the server's library list (/UserViews), keeping the kinds that can hold downloads.
void setLibraries(OfflineIndex index, List<Object?> views) {
  const kinds = {'music', 'musicvideos', 'movies', 'tvshows'};
  final seen = <String>{};
  index.libraries = [];
  for (final v in views) {
    if (v is! Map || !isSafeLibraryId(v['Id']) || isPlaceholderLibrary(v['Id']) || seen.contains(v['Id'])) continue;
    if (!kinds.contains(v['CollectionType'] ?? '')) continue;
    seen.add(v['Id']);
    index.libraries.add({'Id': v['Id'] as String, 'Name': v['Name'] is String ? v['Name'] as String : '', 'CollectionType': v['CollectionType'] as String});
  }
}

/// Places items in a library the lookup found them in. A library not in the stored list is refused.
void assignLibrary(OfflineIndex index, List<String> trackIds, String libraryId) {
  if (!index.libraries.any((l) => l['Id'] == libraryId)) return;
  for (final id in trackIds) {
    index.tracks[id]?.library = libraryId;
  }
}

// Items ----------------------------------------------------------------------

const _stringFields = [
  'Id',
  'Name',
  'SortName',
  'Type',
  'MediaType',
  'Album',
  'AlbumId',
  'AlbumArtist',
  'AlbumPrimaryImageTag',
  'DateCreated',
  'Overview',
  'PlaylistItemId',
  'SeriesId',
  'SeriesName',
  'SeriesPrimaryImageTag',
  'SeasonId',
  'SeasonName',
  'OfficialRating',
];
const _numberFields = ['RunTimeTicks', 'IndexNumber', 'ParentIndexNumber', 'ProductionYear', 'ChildCount', 'NormalizationGain', 'CommunityRating'];
const _booleanFields = ['CanDelete', 'IsPublic'];
const _stringArrayFields = ['Artists', 'Genres', 'BackdropImageTags'];
const _nameIdFields = ['ArtistItems', 'AlbumArtists', 'GenreItems'];
const _streamStrings = ['Type', 'Codec', 'Language', 'DisplayTitle'];
const _streamNumbers = ['Index', 'Channels', 'Width', 'Height'];
const _streamBooleans = ['IsDefault', 'IsForced', 'IsExternal', 'IsTextSubtitleStream'];

List<Map<String, Object?>>? _slimNameIds(Object? v) {
  if (v is! List) return null;
  final out = <Map<String, Object?>>[];
  for (final x in v) {
    if (x is! Map || x['Id'] is! String || (x['Id'] as String).isEmpty) continue;
    out.add(x['Name'] is String ? {'Id': x['Id'], 'Name': x['Name']} : {'Id': x['Id']});
  }
  return out;
}

/// An item cut down to the fields its screens read offline, each checked for its type. Video keeps its streams and chapters; audio does not.
Item slimItem(Map src) {
  final out = <String, dynamic>{};
  for (final k in _stringFields) {
    if (src[k] is String) out[k] = src[k];
  }
  for (final k in _numberFields) {
    if (_isFinite(src[k])) out[k] = src[k];
  }
  for (final k in _booleanFields) {
    if (src[k] is bool) out[k] = src[k];
  }
  for (final k in _stringArrayFields) {
    if (src[k] is List) out[k] = (src[k] as List).whereType<String>().toList();
  }
  for (final k in _nameIdFields) {
    final list = _slimNameIds(src[k]);
    if (list != null) out[k] = list;
  }
  final tags = src['ImageTags'];
  if (tags is Map && tags['Primary'] is String) out['ImageTags'] = {'Primary': tags['Primary']};

  final ud = src['UserData'];
  if (ud is Map) {
    final u = <String, dynamic>{};
    if (ud['Played'] is bool) u['Played'] = ud['Played'];
    if (ud['IsFavorite'] is bool) u['IsFavorite'] = ud['IsFavorite'];
    if (_isFinite(ud['PlayCount'])) u['PlayCount'] = ud['PlayCount'];
    if (_isFinite(ud['PlaybackPositionTicks'])) u['PlaybackPositionTicks'] = ud['PlaybackPositionTicks'];
    if (ud['LastPlayedDate'] is String) u['LastPlayedDate'] = ud['LastPlayedDate'];
    out['UserData'] = u;
  }

  // The first source only: the merge compares its bitrate, video needs its id.
  final source = src['MediaSources'] is List && (src['MediaSources'] as List).isNotEmpty ? (src['MediaSources'] as List).first : null;
  if (source is Map) {
    final s = <String, dynamic>{};
    if (source['Id'] is String) s['Id'] = source['Id'];
    if (source['Container'] is String) s['Container'] = source['Container'];
    if (_isFinite(source['Bitrate'])) s['Bitrate'] = source['Bitrate'];
    if (_isFinite(source['Size'])) s['Size'] = source['Size'];
    out['MediaSources'] = [s];
  }

  final video = out['Type'] == 'Movie' || out['Type'] == 'Episode';
  if (video && src['MediaStreams'] is List) {
    out['MediaStreams'] = [
      for (final m in (src['MediaStreams'] as List).whereType<Map>())
        {
          for (final k in _streamStrings)
            if (m[k] is String) k: m[k],
          for (final k in _streamNumbers)
            if (_isFinite(m[k])) k: m[k],
          for (final k in _streamBooleans)
            if (m[k] is bool) k: m[k],
        },
    ];
  }
  if (video && src['Chapters'] is List) {
    out['Chapters'] = [
      for (final c in (src['Chapters'] as List).whereType<Map>())
        if (_isFinite(c['StartPositionTicks']))
          c['Name'] is String ? {'StartPositionTicks': c['StartPositionTicks'], 'Name': c['Name']} : {'StartPositionTicks': c['StartPositionTicks']},
    ];
  }
  return out;
}

// Reading --------------------------------------------------------------------

/// The collection with this item id, or null.
OfflineCollection? collectionOf(OfflineIndex index, String id) {
  for (final c in index.collections) {
    if (c.item['Id'] == id) return c;
  }
  return null;
}

/// The file a ready track plays from, or null while it is not all on disk.
String? readyFile(OfflineIndex index, String trackId) => index.tracks[trackId]?.file;

/// Tracks still to fetch, oldest request first, a shared track once.
List<String> pendingTrackIds(OfflineIndex index) {
  final seen = <String>{};
  final out = <String>[];
  for (final c in index.collections.reversed) {
    for (final id in c.trackIds) {
      if (index.tracks[id] != null && index.tracks[id]!.file == null && seen.add(id)) out.add(id);
    }
  }
  return out;
}

/// How many of a collection's tracks are on disk, of how many.
({int done, int total}) collectionProgress(OfflineIndex index, String collectionId) {
  final ids = collectionOf(index, collectionId)?.trackIds ?? const <String>[];
  return (done: ids.where((id) => index.tracks[id]?.file != null).length, total: ids.length);
}

/// Bytes every download takes.
num totalBytes(OfflineIndex index) => index.tracks.values.fold<num>(0, (s, t) => s + t.bytes);

/// Bytes a collection's ready tracks take, counting a shared track in full.
num collectionBytes(OfflineIndex index, String collectionId) {
  final ids = collectionOf(index, collectionId)?.trackIds ?? const <String>[];
  return ids.fold<num>(0, (s, id) => s + (index.tracks[id]?.bytes ?? 0));
}

/// Every file the index points at: ready media and saved subtitles.
Set<String> indexedFiles(OfflineIndex index) => {
  for (final t in index.tracks.values) ...[if (t.file != null) t.file!, ...?t.subs?.map((s) => s.file)],
};

/// Lyrics saved with a track, or null when there are none or they have expired.
OfflineLyrics? lyricsOf(OfflineIndex index, String trackId, DateTime now) {
  final l = index.tracks[trackId]?.lyrics;
  if (l == null) return null;
  final exp = _parseMs(l.expiresAt);
  return l.expiresAt != null && exp != null && exp <= now.millisecondsSinceEpoch ? null : l;
}

/// Tracks whose saved lyrics have expired, sorted.
List<String> expiredLyricsTrackIds(OfflineIndex index, DateTime now) =>
    (index.tracks.keys.where((id) => index.tracks[id]!.lyrics != null && lyricsOf(index, id, now) == null).toList()..sort());

// Changing (in place) --------------------------------------------------------

/// Asks for a collection: an album or playlist with its tracks, a movie with itself, a season or series with its episodes. Asking again refreshes its list; items already on disk are kept. [containers] are the series and seasons the episodes belong to. Items that are not audio, a movie or an episode are dropped, and so is an id that cannot be a file name.
void addCollection(OfflineIndex index, Item collection, List<Item> items, [List<Item> containers = const []]) {
  final media = items.where((t) => t['Id'] != null && isSafeId(t['Id']) && (t['Type'] == null || _mediaTypes.contains(t['Type']))).toList();
  index.collections = index.collections.where((c) => c.item['Id'] != collection['Id']).toList();
  index.collections.insert(0, OfflineCollection(slimItem(collection), [for (final t in media) t['Id'] as String]));
  for (final t in media) {
    final existing = index.tracks[t['Id']];
    if (existing != null) {
      existing.item = slimItem(t);
    } else {
      index.tracks[t['Id']] = OfflineTrack(slimItem(t), null, 0);
    }
  }
  for (final c in containers) {
    if (c['Id'] != null && isSafeId(c['Id']) && (c['Type'] == 'Series' || c['Type'] == 'Season')) index.containers[c['Id']] = slimItem(c);
  }
}

/// Refreshes stored items from a fresher copy: fields the copy has replace the stored ones, fields it lacks are kept.
void refreshItems(OfflineIndex index, List<Item> items) {
  for (final fresh in items) {
    final t = fresh['Id'] != null ? index.tracks[fresh['Id']] : null;
    if (t != null) t.item = slimItem({...t.item, ...fresh});
  }
}

/// Marks a track's file as fully on disk.
void markReady(OfflineIndex index, String trackId, String file, num bytes, [DateTime? now]) {
  final t = index.tracks[trackId];
  if (t == null) return;
  t.file = file;
  t.bytes = bytes;
  if (now != null) t.readyAt = _iso(now.millisecondsSinceEpoch);
}

/// This device played it to the end.
void markWatched(OfflineIndex index, String trackId, DateTime now) {
  final t = index.tracks[trackId];
  if (t != null) t.watchedAt = _iso(now.millisecondsSinceEpoch);
}

/// Video: what the server did to make the file ('direct', 'remux' or 'reencode').
void setOutcome(OfflineIndex index, String trackId, String outcome) => index.tracks[trackId]?.outcome = outcome;

/// A picture subtitle to burn in, chosen when the download was asked for. Null (or a bad index) clears it.
void setBurnIn(OfflineIndex index, String trackId, int? streamIndex) {
  final t = index.tracks[trackId];
  if (t == null) return;
  t.burnIn = streamIndex != null && streamIndex >= 0 ? streamIndex : null;
}

// New episodes and watched ones ------------------------------------------------

/// Most episode ids a followed series remembers as removed.
const maxSkippedEpisodes = 5000;

/// Turns "Download new episodes as they arrive" on or off for a downloaded series. Turning it on counts from now.
void setFollow(OfflineIndex index, String seriesId, bool on, DateTime now) {
  final c = collectionOf(index, seriesId);
  if (c == null || c.item['Type'] != 'Series') return;
  if (on) {
    c.follow ??= _iso(now.millisecondsSinceEpoch);
  } else {
    c.follow = null;
  }
}

/// The episodes a followed series should fetch now: added after the follow started, not downloaded, not watched, not removed as watched. Empty when the series is not followed.
List<Item> newEpisodes(OfflineIndex index, String seriesId, List<Item> episodes) {
  final c = collectionOf(index, seriesId);
  final since = c?.follow != null ? _parseMs(c!.follow) : null;
  if (c == null || since == null) return [];
  final held = c.trackIds.toSet();
  final skip = (c.skip ?? const <String>[]).toSet();
  return episodes.where((e) {
    if (e['Id'] == null || !isSafeId(e['Id']) || e['Type'] != 'Episode') return false;
    if (held.contains(e['Id']) || skip.contains(e['Id'])) return false;
    if ((e['UserData'] as Map?)?['Played'] == true) return false;
    final created = _parseMs(e['DateCreated'] ?? '');
    return created != null && created > since;
  }).toList();
}

/// Adds items to a collection already asked for, after the ones it has.
void addToCollection(OfflineIndex index, String collectionId, List<Item> items) {
  final c = collectionOf(index, collectionId);
  if (c == null) return;
  for (final t in items) {
    if (t['Id'] == null || !isSafeId(t['Id']) || (t['Type'] != null && !_mediaTypes.contains(t['Type'])) || c.trackIds.contains(t['Id'])) continue;
    c.trackIds.add(t['Id']);
    index.tracks.putIfAbsent(t['Id'], () => OfflineTrack(slimItem(t), null, 0));
  }
}

/// A watched episode is removed this long after it was finished (a day).
const removeWatchedAfterMs = 24 * 60 * 60 * 1000;

/// Downloaded episodes finished at least a day ago: played to the end on this device, or marked played on the server after the file landed. Movies are never removed. Sorted.
List<String> watchedToRemove(OfflineIndex index, DateTime now) {
  final out = <String>[];
  for (final e in index.tracks.entries) {
    final t = e.value;
    if (t.item['Type'] != 'Episode' || t.file == null) continue;
    int? finished = _parseMs(t.watchedAt);
    final ud = t.item['UserData'] as Map?;
    if (finished == null && ud?['Played'] == true && ud?['LastPlayedDate'] != null && t.readyAt != null) {
      final played = _parseMs(ud!['LastPlayedDate']);
      final ready = _parseMs(t.readyAt);
      if (played != null && ready != null && played > ready) finished = played;
    }
    if (finished != null && now.millisecondsSinceEpoch - finished >= removeWatchedAfterMs) out.add(e.key);
  }
  return out..sort();
}

/// Removes single items (watched episodes) from every collection that holds them. A followed series remembers them so the follow never fetches them again, and stays even with no episode left; any other collection left empty goes. Returns the files now nobody's, sorted.
List<String> removeTracks(OfflineIndex index, List<String> ids) {
  final drop = ids.toSet();
  for (final c in index.collections) {
    final removed = c.trackIds.where(drop.contains).toList();
    if (removed.isEmpty) continue;
    c.trackIds = c.trackIds.where((id) => !drop.contains(id)).toList();
    if (c.follow != null) {
      final all = [...?c.skip, ...removed];
      c.skip = all.length > maxSkippedEpisodes ? all.sublist(all.length - maxSkippedEpisodes) : all;
    }
  }
  index.collections = index.collections.where((c) => c.trackIds.isNotEmpty || c.follow != null).toList();
  return _dropOrphans(index);
}

List<String> _dropOrphans(OfflineIndex index) {
  final kept = {for (final c in index.collections) ...c.trackIds};
  final orphaned = <String>[];
  for (final id in index.tracks.keys.toList()) {
    if (kept.contains(id)) continue;
    final t = index.tracks[id]!;
    if (t.file != null) orphaned.add(t.file!);
    for (final s in t.subs ?? const <OfflineSubtitle>[]) {
      orphaned.add(s.file);
    }
    index.tracks.remove(id);
  }
  _pruneContainers(index);
  return orphaned..sort();
}

/// Containers nothing downloaded still belongs to.
void _pruneContainers(OfflineIndex index) {
  final held = <String>{};
  for (final t in index.tracks.values) {
    final s = t.item['SeriesId'], n = t.item['SeasonId'];
    if (s is String && s.isNotEmpty) held.add(s);
    if (n is String && n.isNotEmpty) held.add(n);
  }
  index.containers.removeWhere((id, _) => !held.contains(id));
}

/// Drops a collection, and with it every item no other collection still holds, and the series and seasons nothing left belongs to. Returns the files now nobody's (media and subtitles), sorted.
List<String> removeCollection(OfflineIndex index, String collectionId) {
  index.collections = index.collections.where((c) => c.item['Id'] != collectionId).toList();
  return _dropOrphans(index);
}

/// Brings the index in line with the disk: a ready track whose file is gone goes back to pending, a subtitle whose file is gone is forgotten. Returns files on disk the index does not know, sorted.
List<String> reconcile(OfflineIndex index, Iterable<String> filesOnDisk) {
  final onDisk = filesOnDisk.toSet();
  for (final t in index.tracks.values) {
    if (t.file != null && !onDisk.contains(t.file)) {
      t.file = null;
      t.bytes = 0;
    }
    if (t.subs != null) {
      t.subs = t.subs!.where((s) => onDisk.contains(s.file)).toList();
      if (t.subs!.isEmpty) t.subs = null;
    }
  }
  final known = indexedFiles(index);
  return onDisk.where((f) => !known.contains(f)).toList()..sort();
}

/// Saves a track's lyrics. [lines] are line Maps or LyricLines; bad ones are dropped. [credit] is a Map or SpicyCredit. SpicyLyrics (source 'spicy') get an expiry [spicyLyricsDays] out.
void setLyrics(OfflineIndex index, String trackId, DateTime now, {required String source, required bool synced, required List<Object?> lines, Object? credit}) {
  final t = index.tracks[trackId];
  if (t == null) return;
  final parsed = _parseLyricLines([for (final l in lines) l is LyricLine ? lyricLineToJson(l) : l]);
  if (parsed.isEmpty || source.isEmpty) return;
  final expires = source == 'spicy' ? _iso(now.millisecondsSinceEpoch + spicyLyricsDays * 86400000) : null;
  t.lyrics = OfflineLyrics(source, synced, parsed, _iso(now.millisecondsSinceEpoch), expires);
  final c = _parseCredit(credit is SpicyCredit ? _creditJson(credit) : credit);
  if (c != null) t.lyrics!.credit = c;
}

/// Forgets a track's saved lyrics.
void dropLyrics(OfflineIndex index, String trackId) => index.tracks[trackId]?.lyrics = null;

/// Saves a video's external subtitles (Maps with index, file, ...); invalid ones are dropped.
void setSubtitles(OfflineIndex index, String trackId, List<Object?> subs) {
  final t = index.tracks[trackId];
  if (t == null) return;
  final valid = _parseSubtitles(subs);
  t.subs = valid.isEmpty ? null : valid;
}

/// Saves a video's media segments (`{Type, StartTicks, EndTicks}` Maps); invalid ones are dropped.
void setSegments(OfflineIndex index, String trackId, List<Object?> segments) {
  final t = index.tracks[trackId];
  if (t == null) return;
  final valid = _parseSegments(segments);
  t.segments = valid.isEmpty ? null : valid;
}

/// The plugin's explicit flag, so the badge shows offline.
void setExplicit(OfflineIndex index, String trackId, bool explicit) {
  final t = index.tracks[trackId];
  if (t == null) return;
  t.explicit = explicit ? true : null;
}

/// Stores the signed-in user from /Users/{id}, keeping the Policy fields the apps read.
void setUser(OfflineIndex index, Object? user) => index.user = _parseUser(user);

/// The rows a snapshot keeps, from the server's played items, newest first.
List<HistoryEntry> historyEntriesOf(List<Item> items) => [
  for (final i in items.where((i) => isSafeId(i['Id'])).take(maxHistoryEntries))
    {
      'Id': i['Id'],
      'LastPlayedDate': (i['UserData'] as Map?)?['LastPlayedDate'] is String ? (i['UserData'] as Map)['LastPlayedDate'] : null,
      'PlayCount': _isFinite((i['UserData'] as Map?)?['PlayCount']) ? (i['UserData'] as Map)['PlayCount'] : 0,
    },
];

/// Keeps the server's history, and writes its dates and counts into the downloads it lists.
void setHistory(OfflineIndex index, List<Item> items, DateTime takenAt) {
  final entries = historyEntriesOf(items);
  index.history = {'takenAt': _iso(takenAt.millisecondsSinceEpoch), 'entries': entries};
  for (final e in entries) {
    for (final item in _storedCopies(index, e['Id'] as String)) {
      final ud = (item['UserData'] ??= <String, dynamic>{}) as Map;
      ud['Played'] = true;
      ud['PlayCount'] = e['PlayCount'];
      if (e['LastPlayedDate'] != null) ud['LastPlayedDate'] = e['LastPlayedDate'];
    }
  }
  _overlayPending(index, {for (final e in entries) e['Id'] as String});
}

/// Queues a play for replay, and counts it in the catalog. Newest are kept past the cap.
void addPlay(OfflineIndex index, OfflinePlay play) {
  index.plays.add(play);
  if (index.plays.length > maxQueuedPlays) index.plays.removeRange(0, index.plays.length - maxQueuedPlays);
  _applyPlay(index, play);
}

/// Queues a user data change and shows it in the catalog at once.
void addChange(OfflineIndex index, UserDataChange change) {
  index.changes.add(change);
  if (index.changes.length > maxQueuedPlays) index.changes.removeRange(0, index.changes.length - maxQueuedPlays);
  _applyChange(index, change);
}

/// Replaces the stored user data with the server's, then lays what is still queued back on top.
void refreshUserData(OfflineIndex index, List<Item> items) {
  final ids = <String>{};
  for (final fresh in items) {
    if (!isSafeId(fresh['Id']) || fresh['UserData'] is! Map) continue;
    final ud = slimItem({'Id': fresh['Id'], 'UserData': fresh['UserData']})['UserData'];
    for (final item in _storedCopies(index, fresh['Id'])) {
      item['UserData'] = {...ud as Map};
    }
    ids.add(fresh['Id']);
  }
  _overlayPending(index, ids);
}

/// Every id the catalog stores user data for: files, collections, shows.
List<String> userDataIds(OfflineIndex index) =>
    {...index.tracks.keys, for (final c in index.collections) c.item['Id'] as String, ...index.containers.keys}.toList();

List<Item> _storedCopies(OfflineIndex index, String id) => [
  if (index.tracks[id] != null) index.tracks[id]!.item,
  for (final c in index.collections)
    if (c.item['Id'] == id) c.item,
  if (index.containers[id] != null) index.containers[id]!,
];

void _applyPlay(OfflineIndex index, OfflinePlay play) {
  for (final item in _storedCopies(index, play['itemId'])) {
    final ud = (item['UserData'] ??= <String, dynamic>{}) as Map;
    ud['Played'] = true;
    ud['PlayCount'] = ((ud['PlayCount'] as num?) ?? 0) + 1;
    final last = _parseMs(ud['LastPlayedDate']);
    if (ud['LastPlayedDate'] == null || ud['LastPlayedDate'] == '' || (last != null && last < (_parseMs(play['date']) ?? 0))) {
      ud['LastPlayedDate'] = play['date'];
    }
  }
}

void _applyChange(OfflineIndex index, UserDataChange c) {
  for (final item in _storedCopies(index, c['itemId'])) {
    final ud = (item['UserData'] ??= <String, dynamic>{}) as Map;
    if (c['kind'] == 'favorite') {
      ud['IsFavorite'] = c['favorite'] == true;
    } else if (c['kind'] == 'position') {
      ud['PlaybackPositionTicks'] = c['ticks'] ?? 0;
      ud['LastPlayedDate'] = c['at'];
    } else if (c['played'] == true) {
      ud['Played'] = true;
      ud['PlaybackPositionTicks'] = 0;
      ud['LastPlayedDate'] = c['at'];
    } else {
      ud['Played'] = false;
      ud['PlaybackPositionTicks'] = 0;
    }
  }
}

void _overlayPending(OfflineIndex index, Set<String> ids) {
  for (final p in index.plays) {
    if (ids.contains(p['itemId'])) _applyPlay(index, p);
  }
  for (final c in index.changes) {
    if (ids.contains(c['itemId'])) _applyChange(index, c);
  }
}

/// Whether a download of [adding] bytes would take the downloads past the storage limit (null: no limit).
bool overStorageLimit(num usedBytes, num adding, num? limitBytes) => limitBytes != null && limitBytes > 0 && usedBytes + adding > limitBytes;

/// Whether a queued play the server refused should be dropped rather than retried: the item is gone (404) or the request can never succeed (400).
bool dropsPlay(int status) => status == 400 || status == 404;

// Storage --------------------------------------------------------------------

final _safeIdRe = RegExp(r'^[A-Za-z0-9]{1,64}$');

/// An id fit to become a file name.
bool isSafeId(Object? id) => id is String && _safeIdRe.hasMatch(id);

final _mediaPathRe = RegExp(r'^media/[A-Za-z0-9_-][A-Za-z0-9._-]*$');

/// "media/" plus a plain file name: no separators, no "..", no dot-file.
bool isSafeMediaPath(Object? p) => p is String && _mediaPathRe.hasMatch(p) && !p.contains('..');

/// "art/ID.jpg".
bool isSafeArtPath(Object? p) => p is String && RegExp(r'^art/[A-Za-z0-9]{1,64}\.jpg$').hasMatch(p);

/// "subs/ID.INDEX.vtt".
bool isSafeSubtitlePath(Object? p) => p is String && RegExp(r'^subs/[A-Za-z0-9]{1,64}\.\d{1,4}\.vtt$').hasMatch(p);

/// A Jellyfin user id (a GUID, with or without dashes). It names the account's offline folder, so it must never be a path.
bool isSafeUserId(Object? id) => id is String && _libId.hasMatch(id) && !_dashes.hasMatch(id);

const _maxLyricLines = 5000;
const _maxLyricWords = 500;

List<LyricWord>? _parseWords(Object? v) {
  if (v is! List) return null;
  return [
    for (final w in v.take(_maxLyricWords).whereType<Map>())
      if (_isFinite(w['Start']) && w['Text'] is String)
        LyricWord((w['Start'] as num).toInt(), _isFinite(w['End']) ? (w['End'] as num).toInt() : null, w['Text'] as String),
  ];
}

List<LyricLine> _parseLyricLines(Object? v) {
  if (v is! List) return [];
  final out = <LyricLine>[];
  for (final l in v.take(_maxLyricLines)) {
    if (l is! Map || !_isFinite(l['Start']) || l['Text'] is! String) continue;
    final line = LyricLine((l['Start'] as num).toInt(), _isFinite(l['End']) ? (l['End'] as num).toInt() : null, l['Text'] as String, _parseWords(l['Words']));
    final bg = _parseWords(l['Background']);
    if (bg != null) line.background = bg;
    if (l['Opposite'] == true) line.opposite = true;
    out.add(line);
  }
  return out;
}

SpicyContributor? _parseContributor(Object? v) =>
    v is Map && v['name'] is String ? (name: v['name'] as String, url: v['url'] is String ? v['url'] as String : null) : null;

SpicyCredit? _parseCredit(Object? v) => v is Map && v['provider'] is String && (v['provider'] as String).isNotEmpty
    ? (provider: v['provider'] as String, uploader: _parseContributor(v['uploader']), maker: _parseContributor(v['maker']))
    : null;

OfflineLyrics? _parseLyrics(Object? v) {
  if (v is! Map || v['source'] is! String || (v['source'] as String).isEmpty) return null;
  final lines = _parseLyricLines(v['lines']);
  final savedAt = _isoDate(v['savedAt']);
  if (lines.isEmpty || savedAt == null) return null;
  // SpicyLyrics with no readable expiry are treated as already expired rather than kept for good.
  final expiresAt = _isoDate(v['expiresAt']) ?? (v['source'] == 'spicy' ? savedAt : null);
  final out = OfflineLyrics(v['source'] as String, v['synced'] == true, lines, savedAt, expiresAt);
  final credit = _parseCredit(v['credit']);
  if (credit != null) out.credit = credit;
  return out;
}

List<OfflineSubtitle> _parseSubtitles(Object? v) {
  if (v is! List) return [];
  final seen = <int>{};
  final out = <OfflineSubtitle>[];
  for (final s in v) {
    if (s is! Map || s['index'] is! int || (s['index'] as int) < 0 || !isSafeSubtitlePath(s['file'])) continue;
    if (!seen.add(s['index'] as int)) continue;
    out.add(
      OfflineSubtitle(
        s['index'] as int,
        s['file'] as String,
        language: s['language'] is String ? s['language'] as String : null,
        title: s['title'] is String ? s['title'] as String : null,
        isDefault: s['isDefault'] is bool ? s['isDefault'] as bool : null,
        isForced: s['isForced'] is bool ? s['isForced'] as bool : null,
      ),
    );
  }
  return out;
}

List<Map<String, Object?>> _parseSegments(Object? v) {
  if (v is! List) return [];
  return [
    for (final s in v.whereType<Map>())
      if (s['Type'] is String && _isFinite(s['StartTicks']) && _isFinite(s['EndTicks']) && (s['EndTicks'] as num) > (s['StartTicks'] as num))
        {'Type': s['Type'], 'StartTicks': s['StartTicks'], 'EndTicks': s['EndTicks']},
  ];
}

Map<String, dynamic>? _parseUser(Object? v) {
  if (v is! Map || !isSafeUserId(v['Id']) || v['Name'] is! String) return null;
  final p = v['Policy'] is Map ? v['Policy'] as Map : const {};
  final policy = <String, dynamic>{};
  for (final k in ['IsAdministrator', 'EnableContentDeletion', 'EnableContentDownloading', 'EnableLiveTvAccess']) {
    if (p[k] is bool) policy[k] = p[k];
  }
  if (p['EnableContentDeletionFromFolders'] is List) {
    policy['EnableContentDeletionFromFolders'] = (p['EnableContentDeletionFromFolders'] as List).whereType<String>().toList();
  }
  return {'Id': v['Id'], 'Name': v['Name'], 'Policy': policy};
}

HistorySnapshot? _parseHistory(Object? v) {
  if (v is! Map || v['entries'] is! List) return null;
  final takenAt = _isoDate(v['takenAt']);
  if (takenAt == null) return null;
  final entries = <HistoryEntry>[];
  for (final e in (v['entries'] as List).take(maxHistoryEntries)) {
    if (e is! Map || !isSafeId(e['Id'])) continue;
    entries.add({
      'Id': e['Id'],
      'LastPlayedDate': e['LastPlayedDate'] is String ? e['LastPlayedDate'] : null,
      'PlayCount': _isFinite(e['PlayCount']) && (e['PlayCount'] as num) >= 0 ? (e['PlayCount'] as num).floor() : 0,
    });
  }
  return {'takenAt': takenAt, 'entries': entries};
}

/// A queued change, checked like anything read from disk (or sent by the renderer). Null when it is not one.
UserDataChange? parseChange(Object? v) {
  if (v is! Map || !isSafeId(v['itemId']) || !isSafeUserId(v['userId'])) return null;
  final at = _isoDate(v['at']);
  if (at == null) return null;
  final base = {'itemId': v['itemId'], 'userId': v['userId'], 'at': at};
  if (v['kind'] == 'position' && _isFinite(v['ticks']) && (v['ticks'] as num) >= 0) return {...base, 'kind': 'position', 'ticks': (v['ticks'] as num).round()};
  if (v['kind'] == 'played' && v['played'] is bool) return {...base, 'kind': 'played', 'played': v['played']};
  if (v['kind'] == 'favorite' && v['favorite'] is bool) {
    return {...base, 'kind': 'favorite', 'favorite': v['favorite'], 'was': v['was'] is bool ? v['was'] : !(v['favorite'] as bool)};
  }
  return null;
}

/// A stored index, validated: it is read from disk, where anything can be. A path that could leave the offline folder is dropped (the track goes back to pending), an id that is not a plain id is dropped, an unreadable value is an empty index. A version 1 index reads into version 2 as is.
OfflineIndex parseIndex(Object? raw) {
  final index = emptyIndex();
  if (raw is! Map) return index;

  if (raw['tracks'] is Map) {
    for (final e in (raw['tracks'] as Map).entries) {
      final id = e.key, v = e.value;
      if (!isSafeId(id) || v is! Map || v['item'] is! Map || (v['item'] as Map)['Id'] != id) continue;
      final file = isSafeMediaPath(v['file']) ? v['file'] as String : null;
      final b = v['bytes'];
      final bytes = file != null && b is num && b.isFinite && b > 0 ? b.floor() : 0;
      final track = OfflineTrack(slimItem(v['item'] as Map), file, bytes);
      if (isSafeLibraryId(v['library']) && !isPlaceholderLibrary(v['library'])) track.library = v['library'] as String;
      final lyrics = _parseLyrics(v['lyrics']);
      if (lyrics != null) track.lyrics = lyrics;
      final subs = _parseSubtitles(v['subs']);
      if (subs.isNotEmpty) track.subs = subs;
      final segments = _parseSegments(v['segments']);
      if (segments.isNotEmpty) track.segments = segments;
      if (v['explicit'] == true) track.explicit = true;
      final readyAt = file != null ? _isoDate(v['readyAt']) : null;
      if (readyAt != null) track.readyAt = readyAt;
      final watchedAt = _isoDate(v['watchedAt']);
      if (watchedAt != null) track.watchedAt = watchedAt;
      if (v['outcome'] == 'direct' || v['outcome'] == 'remux' || v['outcome'] == 'reencode') track.outcome = v['outcome'] as String;
      if (v['burnIn'] is int && (v['burnIn'] as int) >= 0) track.burnIn = v['burnIn'] as int;
      index.tracks[id as String] = track;
    }
  }

  if (raw['collections'] is List) {
    final seen = <String>{};
    for (final c in raw['collections'] as List) {
      if (c is! Map || c['item'] is! Map || !isSafeId((c['item'] as Map)['Id']) || seen.contains((c['item'] as Map)['Id'])) continue;
      final item = c['item'] as Map;
      if (item['Type'] is String && !_collectionTypes.contains(item['Type'])) continue;
      seen.add(item['Id'] as String);
      final ids = c['trackIds'] is List
          ? [
              for (final id in c['trackIds'] as List)
                if (id is String && index.tracks.containsKey(id)) id,
            ]
          : <String>[];
      final collection = OfflineCollection(slimItem(item), ids);
      final follow = collection.item['Type'] == 'Series' ? _isoDate(c['follow']) : null;
      if (follow != null) {
        collection.follow = follow;
        if (c['skip'] is List) {
          final s = (c['skip'] as List).where(isSafeId).cast<String>().toList();
          collection.skip = s.length > maxSkippedEpisodes ? s.sublist(s.length - maxSkippedEpisodes) : s;
        }
      }
      index.collections.add(collection);
    }
  }

  if (raw['containers'] is Map) {
    for (final e in (raw['containers'] as Map).entries) {
      final v = e.value;
      if (!isSafeId(e.key) || v is! Map || v['Id'] != e.key || (v['Type'] != 'Series' && v['Type'] != 'Season')) continue;
      index.containers[e.key as String] = slimItem(v);
    }
  }

  if (raw['libraries'] is List) setLibraries(index, (raw['libraries'] as List).where(_isMap).toList());
  index.user = _parseUser(raw['user']);
  index.history = _parseHistory(raw['history']);

  if (raw['plays'] is List) {
    for (final p in raw['plays'] as List) {
      if (p is! Map || !isSafeId(p['itemId']) || !isSafeUserId(p['userId'])) continue;
      final date = _isoDate(p['date']);
      if (date != null) index.plays.add({'itemId': p['itemId'], 'userId': p['userId'], 'date': date});
    }
    if (index.plays.length > maxQueuedPlays) index.plays.removeRange(0, index.plays.length - maxQueuedPlays);
  }
  if (raw['changes'] is List) {
    for (final c in raw['changes'] as List) {
      final change = parseChange(c);
      if (change != null) index.changes.add(change);
    }
    if (index.changes.length > maxQueuedPlays) index.changes.removeRange(0, index.changes.length - maxQueuedPlays);
  }
  index.playsHeld = raw['playsHeld'] == true && index.plays.isNotEmpty;

  // A track no collection holds is nobody's: it would never be listed, played from a Downloads row, or removed.
  final held = {for (final c in index.collections) ...c.trackIds};
  index.tracks.removeWhere((id, _) => !held.contains(id));
  _pruneContainers(index);
  return index;
}

// Judging a download -----------------------------------------------------------

const _audioExtensions = {
  'audio/flac': 'flac',
  'audio/x-flac': 'flac',
  'audio/mpeg': 'mp3',
  'audio/mp3': 'mp3',
  'audio/mp4': 'm4a',
  'audio/x-m4a': 'm4a',
  'audio/aac': 'aac',
  'audio/ogg': 'ogg',
  'audio/opus': 'opus',
  'audio/wav': 'wav',
  'audio/x-wav': 'wav',
  'audio/webm': 'webm',
  'audio/x-ms-wma': 'wma',
  'audio/x-matroska': 'mka',
};

final _audioFileExtensions = {..._audioExtensions.values, 'alac', 'aif', 'aiff', 'ape', 'wv', 'dsf', 'dff', 'oga', 'mp4', 'm4b', 'mpc'};

const _videoExtensions = {'video/mp4': 'mp4', 'video/x-matroska': 'mkv', 'video/webm': 'webm', 'video/quicktime': 'mov', 'video/x-m4v': 'm4v'};

final _videoFileExtensions = {..._videoExtensions.values, 'avi', 'ts', 'm2ts', 'mpg', 'mpeg', 'wmv', 'ogv'};

final _filenameRe = RegExp(r'''filename\*?=(?:UTF-8'')?"?([^";]+)"?''', caseSensitive: false);

/// The extension a downloaded file is saved under: the server's file name first (only when it names audio, or video), then the MIME type; null when neither says so.
String? fileExtensionFor(String? contentDisposition, String? contentType, {bool video = false}) {
  final name = _filenameRe.firstMatch(contentDisposition ?? '')?[1];
  if (name != null) {
    final dot = name.lastIndexOf('.');
    final ext = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
    if ((video ? _videoFileExtensions : _audioFileExtensions).contains(ext)) return ext;
  }
  final mime = (contentType ?? '').split(';').first.trim().toLowerCase();
  return (video ? _videoExtensions : _audioExtensions)[mime];
}

/// The verdict on a download: [ok] with [ext], or not with a [message].
typedef DownloadVerdict = ({bool ok, String? ext, String? message});

/// Whether what arrived is a finished file: a 2xx with the full length ([expected] null when the server did not announce one) and something that says audio (or video).
DownloadVerdict judgeDownload({
  required int status,
  required int? expected,
  required int received,
  String? contentDisposition,
  String? contentType,
  bool video = false,
}) {
  if (status < 200 || status >= 300) {
    return (
      ok: false,
      ext: null,
      message: status == 403
          ? 'The server does not allow this account to download. An admin can turn on media downloading for it.'
          : 'The server answered HTTP $status.',
    );
  }
  if (received <= 0 || (expected != null && received != expected)) return (ok: false, ext: null, message: 'A download was cut short.');
  final ext = fileExtensionFor(contentDisposition, contentType, video: video);
  if (ext == null) {
    return (
      ok: false,
      ext: null,
      message: video ? 'The server sent something that is not a video file.' : 'The server sent something that is not a music file.',
    );
  }
  return (ok: true, ext: ext, message: null);
}

// Serving a file ---------------------------------------------------------------

/// The part of a file a request asked for: inclusive byte offsets.
typedef ByteRange = ({int start, int end});

final _rangeRe = RegExp(r'^bytes=(\d*)-(\d*)$');

/// A Range header against a file of [size] bytes: a [ByteRange], null for "no usable range, send the whole file" (absent, malformed, multi-range), or the string 'unsatisfiable' (answer 416).
Object? parseByteRange(String? header, int size) {
  final m = _rangeRe.firstMatch((header ?? '').trim());
  if (m == null || (m[1] == '' && m[2] == '')) return null;
  if (size <= 0) return 'unsatisfiable';
  if (m[1] == '') {
    // "-N": the last N bytes.
    final n = num.parse(m[2]!);
    return n == 0 ? 'unsatisfiable' : (start: n >= size ? 0 : (size - n).toInt(), end: size - 1);
  }
  final start = num.parse(m[1]!);
  final end = m[2] == '' ? size - 1 : (num.parse(m[2]!) < size - 1 ? num.parse(m[2]!) : size - 1);
  if (start >= size || end < start) return 'unsatisfiable';
  return (start: start.toInt(), end: end.toInt());
}

const _contentTypes = {
  'flac': 'audio/flac',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'opus': 'audio/ogg',
  'wav': 'audio/wav',
  'wma': 'audio/x-ms-wma',
  'mka': 'audio/x-matroska',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'jpg': 'image/jpeg',
  'vtt': 'text/vtt',
};

/// What to tell the media element a stored file is, from its extension.
String contentTypeForFile(String file) => _contentTypes[file.substring(file.lastIndexOf('.') + 1).toLowerCase()] ?? 'application/octet-stream';
