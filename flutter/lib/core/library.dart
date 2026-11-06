// The signed-in library: the server's libraries and which ones are chosen,
// what the user may do, and Home's shelves. Or the demo library. The queries
// and selection rules are the desktop's (renderer.js connect() and
// loadRecentlyPlayed and friends); the setting names are electron-store's.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/downloads.dart';
import 'package:cascade/core/lyrics_fetch.dart';
import 'package:cascade/core/offline_index.dart';
import 'package:cascade/core/offline_mode.dart';
import 'package:cascade/core/offline_query.dart';
import 'package:cascade/core/offline_sync.dart';
import 'package:cascade/core/smart_playlist.dart';

class Library extends ChangeNotifier {
  Jellyfin? jf;
  bool demo = false, loading = false;
  String? error;

  /// The server's libraries by kind, from /UserViews.
  List<Item> musicLibs = [], movieLibs = [], showLibs = [];

  /// The chosen ones in effect (see [effectiveLibraryIds]).
  List<String> movieIds = [], showIds = [];

  /// The user's policy, from /Users/{id}.
  Map? policy;
  bool get isAdmin => policy?['IsAdministrator'] == true;
  bool get canDelete => canDeleteMedia(policy);
  bool get mayDownload => canDownload(policy);

  List<Song> recentlyPlayed = [], frequent = [];
  List<Album> recentlyAdded = [], playlists = [];
  List<Video> continueWatching = [];

  /// Whether the server has Live TV channels to offer as Radio.
  bool hasLiveTv = false;

  bool get signedIn => demo || jf?.token != null;

  /// Lyrics for the signed-in server, kept per song for the session.
  LyricsFetcher? _lyrics;
  LyricsFetcher? get lyrics {
    final j = jf;
    if (j == null) return null;
    if (_lyrics?.jf != j) _lyrics = LyricsFetcher(j);
    return _lyrics;
  }

  bool get hasVideo => movieIds.isNotEmpty || showIds.isNotEmpty;
  Map<String, String>? get headers => jf?.headers;

  void useDemo() {
    demo = true;
    recentlyPlayed = const [reckoner, ...demoRecentlyPlayed];
    frequent = demoRecentlyPlayed.reversed.toList();
    recentlyAdded = demoRecentlyAdded;
    playlists = demoPlaylists;
    continueWatching = demoContinueWatching;
    notifyListeners();
  }

  Future<void> use(Jellyfin j) async {
    jf = j;
    demo = false;
    await refresh();
  }

  /// Called after each load that worked: the player restores its queue then,
  /// since a server that was down at launch could not give it the songs.
  void Function()? onLoaded;

  Timer? _retry;
  int _attempt = 0;

  // Offline Mode (docs/offline-mode-plan.md) --------------------------------
  //
  // Manual (the Settings switch, the desktop's offlineMode key) or
  // unreachable (the server stopped answering and there are downloads to
  // fall back on). Either way the client answers from the downloads catalog,
  // and plays and likes queue there until the server is back.

  /// Set by the app: the downloads catalog.
  Downloads? downloads;
  OfflineState offlineState = OfflineState.online;
  bool get offline => isOffline(offlineState);
  Timer? _probe;
  int _probeAttempt = 0;

  void _setOffline(OfflineEvent event) {
    final before = offlineState;
    offlineState = nextOfflineState(offlineState, event);
    final d = downloads;
    jf?.offline = offline && d != null ? (path, query) => answerOffline(d.index, path, query) : null;
    if (before != offlineState) {
      _probe?.cancel();
      if (offlineState == OfflineState.unreachable) _probeLater();
    }
  }

  /// The Settings switch.
  Future<void> setOfflineMode(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('offlineMode', on);
    // Right before going offline by hand, the history the sync will compare.
    if (on && !offline && jf != null) await _snapshot(jf!).catchError((_) {});
    _setOffline(OfflineSwitch(on));
    await refresh();
  }

  /// Asks the server directly (past the catalog) on a backoff, 30 s doubling
  /// to five minutes; when it answers, back online and sync.
  void _probeLater() {
    _probe = Timer(Duration(milliseconds: probeDelayMs(_probeAttempt++)), () async {
      final j = jf;
      if (j == null || offlineState != OfflineState.unreachable) return;
      try {
        final res = await http.get(Uri.parse('${j.server}/System/Info/Public')).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          _probeAttempt = 0;
          _setOffline(const OfflineReachable());
          await refresh();
          return;
        }
      } catch (_) {}
      _probeLater();
    });
  }

  /// A play while offline, queued for the history catch-up.
  void offlinePlay(String itemId) {
    final d = downloads, j = jf;
    if (!offline || d == null || j == null || itemId.isEmpty) return;
    addPlay(d.index, {'itemId': itemId, 'userId': j.userId, 'date': DateTime.now().toUtc().toIso8601String()});
    d.save();
  }

  /// The server's play history as it is now, kept for the catch-up check.
  Future<void> _snapshot(Jellyfin j) async {
    final d = downloads;
    if (d == null || d.index.tracks.isEmpty) return;
    final res = await j.get('/Items', {...historyQuery, 'userId': j.userId});
    setHistory(d.index, ((res as Map)['Items'] as List).cast<Item>(), DateTime.now());
    await d.save();
  }

  /// Back online: send what happened offline, then refresh the catalog's
  /// user data and the snapshot. Plays replay only when the server's history
  /// still matches the snapshot; otherwise they wait (held), as the desktop.
  Future<void> _syncOffline(Jellyfin j) async {
    final d = downloads;
    if (d == null) return;
    final idx = d.index;
    try {
      final hist = ((await j.get('/Items', {...historyQuery, 'userId': j.userId}) as Map)['Items'] as List).cast<Item>();
      switch (playsCatchUp(idx.plays, idx.history, idx.playsHeld, hist)) {
        case 'replay':
          for (final p in playsOldestFirst(idx.plays.where((p) => p['userId'] == j.userId).toList())) {
            await j.post('/UserPlayedItems/${p['itemId']}', null, {'userId': j.userId, 'datePlayed': p['date']});
          }
          idx.plays.removeWhere((p) => p['userId'] == j.userId);
        case 'hold':
          idx.playsHeld = true;
      }
      final updates = coalesceChanges(idx.changes.where((c) => c['userId'] == j.userId).toList());
      for (var i = 0; i < updates.length; i += 100) {
        final chunk = updates.skip(i).take(100).toList();
        final res = await j.get('/Items', {'userId': j.userId, 'Ids': chunk.map((u) => u['itemId']).join(','), 'Fields': 'UserData'});
        final byId = {for (final it in ((res as Map)['Items'] as List).cast<Item>()) it['Id']: it};
        for (final u in chunk) {
          final send = updateToSend(u, byId[u['itemId']]);
          if (send == null) continue;
          if (send['favorite'] is bool) await setFavorite('${u['itemId']}', send['favorite'] as bool);
          if (send['userData'] is Map) await j.post('/UserItems/${u['itemId']}/UserData', send['userData'], {'userId': j.userId});
        }
      }
      idx.changes.removeWhere((c) => c['userId'] == j.userId);
      final ids = userDataIds(idx);
      for (var i = 0; i < ids.length; i += 100) {
        final res = await j.get('/Items', {'userId': j.userId, 'Ids': ids.skip(i).take(100).join(','), 'Fields': 'UserData'});
        refreshUserData(idx, ((res as Map)['Items'] as List).cast<Item>());
      }
      setHistory(idx, hist, DateTime.now());
      await d.save();
    } catch (e) {
      debugPrint('offline sync: $e');
    }
  }

  /// The libraries, the user's policy and the chosen libraries, then Home.
  /// A server that does not answer is tried again by itself, 5 s later and
  /// then less often (up to every minute), until it does.
  Future<void> refresh() async {
    final j = jf;
    if (j == null) return;
    _retry?.cancel();
    loading = true;
    error = null;
    _cache.clear();
    _stats = null;
    notifyListeners();
    // The saved switch, at launch.
    if (offlineState == OfflineState.online && (await SharedPreferences.getInstance()).getBool('offlineMode') == true) _setOffline(const OfflineSwitch(true));
    try {
      await _connect(j);
      await _loadHome(j);
      _attempt = 0;
      onLoaded?.call();
      if (!offline) _syncOffline(j);
    } catch (e) {
      final status = e is JellyfinError ? e.status : null;
      // No server, but downloads: carry on from them and keep probing.
      if (!offline && failureKind(status) == 'unreachable' && (downloads?.index.tracks.isNotEmpty ?? false)) {
        _setOffline(const OfflineUnreachable());
        loading = false;
        return refresh();
      }
      if (offline) {
        error = 'Could not read the downloads: $e';
      } else {
        final wait = min(60, 5 << min(_attempt++, 4));
        error = 'Could not reach your server, trying again in $wait s ($e)';
        _retry = Timer(Duration(seconds: wait), refresh);
      }
    }
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _probe?.cancel();
    super.dispose();
  }

  Future<void> _connect(Jellyfin j) async {
    final [views, user] = await Future.wait([
      j.get('/UserViews', {'userId': j.userId}),
      j.get('/Users/${j.userId}'),
    ]);
    final libs = ((views as Map)['Items'] as List).cast<Item>();
    List<Item> kind(String type) => libs.where((l) => l['CollectionType'] == type).toList();
    musicLibs = kind('music');
    movieLibs = kind('movies');
    showLibs = kind('tvshows');
    // Offline, older downloads sit in placeholder libraries that count as
    // chosen whatever was saved.
    final placeholders = offline ? placeholderLibraryIds().toSet() : const <String>{};
    policy = (user as Map)['Policy'] as Map?;

    final prefs = await SharedPreferences.getInstance();
    // Music: what was saved, minus libraries that vanished; all of them when
    // nothing was ever chosen or nothing saved is left.
    final saved = (prefs.getStringList('libraryIds') ?? const []).where((id) => musicLibs.any((l) => l['Id'] == id)).toList();
    j.libraryIds = saved.isNotEmpty
        ? [
            ...saved,
            for (final l in musicLibs)
              if (placeholders.contains(l['Id'])) l['Id'] as String,
          ]
        : [for (final l in musicLibs) l['Id'] as String];
    movieIds = [
      ...effectiveLibraryIds(movieLibs, prefs.getStringList('movieLibraryIds')),
      for (final l in movieLibs)
        if (placeholders.contains(l['Id'])) l['Id'] as String,
    ];
    // Best effort: a server without Live TV answers with an error or nothing.
    hasLiveTv = await j
        .get('/LiveTv/Channels', {'userId': j.userId, 'Limit': 1})
        .then((r) => ((r as Map)['TotalRecordCount'] as int? ?? 0) > 0, onError: (_) => false);
    showIds = effectiveLibraryIds(showLibs, prefs.getStringList('showLibraryIds'));
  }

  Future<void> _loadHome(Jellyfin j) async {
    final user = {'userId': j.userId};
    const played = {'IncludeItemTypes': 'Audio', 'Recursive': true, 'Filters': 'IsPlayed', 'SortOrder': 'Descending'};
    final r = await Future.wait([
      j.getMerged('/Items', {...user, ...played, 'SortBy': 'DatePlayed', 'Limit': 9}),
      j.getMerged('/Items', {...user, 'IncludeItemTypes': 'MusicAlbum', 'Recursive': true, 'SortBy': 'DateCreated', 'SortOrder': 'Descending', 'Limit': 12}),
      // Playlists live in their own collection, not the music libraries.
      j.getMerged('/Items', {
        ...user,
        'IncludeItemTypes': 'Playlist',
        'Recursive': true,
        'SortBy': 'DatePlayed,SortName',
        'SortOrder': 'Descending',
        'Fields': 'ChildCount',
        'Limit': 12,
      }, const []),
      j.getMerged('/Items', {...user, ...played, 'SortBy': 'PlayCount', 'Limit': 9}),
      _continueWatching(j),
    ]);
    // getMerged concatenates libraries, so the server's DatePlayed order only
    // holds within one: put recently played back in order across them.
    recentlyPlayed = (r[0]..sort((a, b) => _lastPlayed(b).compareTo(_lastPlayed(a)))).take(9).map(j.song).toList();
    recentlyAdded = r[1].map(j.album).toList();
    playlists = r[2].where((i) => i['MediaType'] != 'Video').map(j.album).toList();
    frequent = r[3].map(j.song).toList();
    continueWatching = r[4].map(j.video).toList();
  }

  static String _lastPlayed(Item i) => (i['UserData'] as Map?)?['LastPlayedDate'] as String? ?? '';

  /// What is partway through, most recent first, then Next Up, one card per
  /// series (renderer.js loadContinueWatching).
  Future<List<Item>> _continueWatching(Jellyfin j) async {
    if (!hasVideo) return const [];
    const fields = 'UserData,ProductionYear,SeriesPrimaryImageTag';
    final [resume, nextUp] = await Future.wait([
      j.getMerged(
        '/Items',
        {
          'userId': j.userId,
          'SortBy': 'DatePlayed',
          'SortOrder': 'Descending',
          'IncludeItemTypes': 'Movie,Episode',
          'Filters': 'IsResumable',
          'Recursive': true,
          'Fields': fields,
          'Limit': 24,
        },
        [...movieIds, ...showIds],
      ),
      // Best effort: a failed Next Up still leaves the resume list.
      showIds.isEmpty
          ? Future.value(<Item>[])
          : j.getMerged('/Shows/NextUp', {'UserId': j.userId, 'Fields': fields, 'Limit': 24, 'EnableResumable': false}, showIds).catchError((_) => <Item>[]),
    ]);
    resume.sort((a, b) => _lastPlayed(b).compareTo(_lastPlayed(a)));
    return onePerSeries([...resume, ...nextUp]).take(24).toList();
  }

  /// Choose the libraries in use and load everything again (renderer.js
  /// library picker). Empty music means all; empty video means none.
  Future<void> setLibraries({List<String>? music, List<String>? movies, List<String>? shows}) async {
    final prefs = await SharedPreferences.getInstance();
    if (music != null) await prefs.setStringList('libraryIds', music);
    if (movies != null) await prefs.setStringList('movieLibraryIds', movies);
    if (shows != null) await prefs.setStringList('showLibraryIds', shows);
    await refresh();
  }

  /// Ask the server to scan its libraries (admins only).
  Future<void> scanServer() async => jf?.post('/Library/Refresh');

  /// Approve another device's Quick Connect code with this account.
  Future<void> approveQuickConnect(String code) async => jf?.post('/QuickConnect/Authorize', null, {'code': code.trim(), 'userId': jf?.userId});

  /// The Live TV channels, as radio.
  Future<List<Song>> radioChannels() async {
    final j = jf;
    if (j == null) return const [];
    final res = await j.get('/LiveTv/Channels', {'userId': j.userId});
    return [for (final c in ((res as Map)['Items'] as List).cast<Item>()) j.channel(c)];
  }

  // Browsing ---------------------------------------------------------------
  //
  // The whole lists (albums, artists, songs) load once per session and are
  // kept, as the desktop keeps rawItems; a write that changes them (a like,
  // a new playlist) refreshes what it touched.

  final _cache = <String, Future<List<Item>>>{};

  Future<List<Item>> _cached(String key, Future<List<Item>> Function() load) {
    final f = _cache[key] ??= load();
    f.then(
      (_) {},
      onError: (_) {
        if (identical(_cache[key], f)) _cache.remove(key);
      },
    );
    return f;
  }

  /// Forget a cached list (or all of them), so the next look loads it again.
  void invalidate([String? key]) {
    key == null ? _cache.clear() : _cache.remove(key);
    notifyListeners();
  }

  Map<String, Object?> get _user => {'userId': jf?.userId};

  static int _bySortName(Item a, Item b) =>
      ((a['SortName'] ?? a['Name'] ?? '') as String).toLowerCase().compareTo(((b['SortName'] ?? b['Name'] ?? '') as String).toLowerCase());

  Future<List<Item>> albumItems() => _cached('albums', () async {
    final j = jf;
    if (j == null) return demoRecentlyAdded.map((a) => <String, dynamic>{'Id': a.title, 'Name': a.title, 'AlbumArtist': a.subtitle}).toList();
    final r = await j.getAllPaged('/Items', {
      ..._user,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': true,
      'SortBy': 'SortName',
      'Fields': 'SortName,Genres,ProductionYear,UserData,DateCreated,ChildCount',
    });
    return r..sort(_bySortName);
  });

  Future<List<Item>> artistItems() => _cached('artists', () async {
    final j = jf;
    if (j == null) return const [];
    final r = await j.getAllPaged('/Artists', {'UserId': j.userId, 'SortBy': 'SortName', 'Fields': 'SortName,DateCreated,UserData'});
    return r..sort(_bySortName);
  });

  Future<List<Item>> songItems() => _cached('songs', () async {
    final j = jf;
    if (j == null) return const [];
    final r = await j.getAllPaged('/Items', {
      ..._user,
      'IncludeItemTypes': 'Audio',
      'Recursive': true,
      'SortBy': 'SortName',
      'Fields': 'AlbumId,AlbumPrimaryImageTag,SortName,DateCreated,UserData,Genres',
    });
    return r..sort(_bySortName);
  });

  Future<List<Item>> playlistItems() => _cached('playlists', () async {
    final j = jf;
    if (j == null) return const [];
    final r = await j.getMerged('/Items', {
      ..._user,
      'IncludeItemTypes': 'Playlist',
      'Recursive': true,
      'SortBy': 'SortName',
      'Fields': 'ChildCount,DateCreated,UserData,SortName',
    }, const []);
    return r.where((i) => i['MediaType'] != 'Video').toList()..sort(_bySortName);
  });

  /// Genres across the chosen libraries, once per name.
  Future<List<Item>> genreItems() => _cached('genres', () async {
    final j = jf;
    if (j == null) return const [];
    final r = await j.getMerged('/MusicGenres', {'UserId': j.userId, 'Fields': 'ChildCount'});
    final seen = <String>{};
    return [
      for (final g in r..sort(_bySortName))
        if (seen.add(((g['Name'] ?? '') as String).toLowerCase())) g,
    ];
  });

  /// What was played, newest first (up to [limit]).
  Future<List<Song>> history({int limit = 300}) async {
    final j = jf;
    if (j == null) return recentlyPlayed;
    final r = await j.getMerged('/Items', {
      ..._user,
      'IncludeItemTypes': 'Audio',
      'Recursive': true,
      'Filters': 'IsPlayed',
      'SortBy': 'DatePlayed',
      'SortOrder': 'Descending',
      'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData',
      'Limit': limit,
    });
    r.sort((a, b) => _lastPlayed(b).compareTo(_lastPlayed(a)));
    return r.take(limit).map(j.song).toList();
  }

  /// Home's voice line: songs on the server and how many were played in the
  /// last week. ponytail: the week counts from the last 500 plays, which is
  /// every play for anyone who plays fewer than 500 songs a week.
  Future<({int songs, int week})>? _stats;
  Future<({int songs, int week})> stats() => _stats ??=
      () async {
        final j = jf;
        if (j == null) return (songs: 4212, week: 61);
        final ids = j.libraryIds ?? const <String>[];
        final counts = await Future.wait([
          for (final id in ids.isEmpty ? [null] : ids)
            j
                .get('/Items', {..._user, 'IncludeItemTypes': 'Audio', 'Recursive': true, 'Limit': 0, 'ParentId': ?id})
                .then((r) => (r as Map)['TotalRecordCount'] as int? ?? 0),
        ]);
        final recent = await history(limit: 500);
        final weekAgo = DateTime.now().subtract(const Duration(days: 7));
        final week = recent.where((s) => DateTime.tryParse(s.lastPlayed ?? '')?.isAfter(weekAgo) ?? false).length;
        return (songs: counts.fold<int>(0, (a, b) => a + b), week: week);
      }()..catchError((_) {
        _stats = null;
        return (songs: 0, week: 0);
      });

  /// One item, with its user data.
  Future<Item?> item(String id) async {
    final j = jf;
    if (j == null || id.isEmpty) return null;
    return (await j.get('/Items/$id', _user)) as Item?;
  }

  /// An artist's albums, newest first, and the ones they only appear on.
  Future<({List<Album> own, List<Album> appearsOn})> artistAlbums(String artistId) async {
    final j = jf;
    if (j == null) return (own: const <Album>[], appearsOn: const <Album>[]);
    const q = {
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': true,
      'SortBy': 'ProductionYear,SortName',
      'SortOrder': 'Descending',
      'Fields': 'ProductionYear,UserData,ChildCount',
    };
    final [own, all] = await Future.wait([
      j.getMerged('/Items', {..._user, ...q, 'AlbumArtistIds': artistId}),
      j.getMerged('/Items', {..._user, ...q, 'ContributingArtistIds': artistId}),
    ]);
    final ownIds = {for (final a in own) a['Id']};
    int byYear(Item a, Item b) => (b['ProductionYear'] as int? ?? 0).compareTo(a['ProductionYear'] as int? ?? 0);
    return (
      own: (own..sort(byYear)).map(j.album).toList(),
      appearsOn: (all.where((a) => !ownIds.contains(a['Id'])).toList()..sort(byYear)).map(j.album).toList(),
    );
  }

  /// An artist's songs, by album, disc and track (renderer.js fetchArtistSongs).
  Future<List<Song>> artistSongs(String artistId) async {
    final j = jf;
    if (j == null) return const [];
    final r = await j.getMerged('/Items', {
      ..._user,
      'ArtistIds': artistId,
      'IncludeItemTypes': 'Audio',
      'Recursive': true,
      'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData',
    });
    r.sort(
      (a, b) => ((a['Album'] ?? '') as String).compareTo((b['Album'] ?? '') as String) != 0
          ? ((a['Album'] ?? '') as String).compareTo((b['Album'] ?? '') as String)
          : (a['ParentIndexNumber'] as int? ?? 0) != (b['ParentIndexNumber'] as int? ?? 0)
          ? (a['ParentIndexNumber'] as int? ?? 0) - (b['ParentIndexNumber'] as int? ?? 0)
          : (a['IndexNumber'] as int? ?? 0) - (b['IndexNumber'] as int? ?? 0),
    );
    return r.map(j.song).toList();
  }

  /// An artist's most played songs.
  Future<List<Song>> topSongs(String artistId, {int limit = 10}) async {
    final j = jf;
    if (j == null) return const [];
    final r = await j.getMerged('/Items', {
      ..._user,
      'ArtistIds': artistId,
      'IncludeItemTypes': 'Audio',
      'Recursive': true,
      'SortBy': 'PlayCount,SortName',
      'SortOrder': 'Descending',
      'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData',
      'Limit': limit,
    });
    r.sort((a, b) => ((b['UserData']?['PlayCount'] ?? 0) as int).compareTo((a['UserData']?['PlayCount'] ?? 0) as int));
    return r.take(limit).map(j.song).toList();
  }

  /// Similar artists, kept to the chosen libraries (the endpoint has no
  /// library scope of its own).
  Future<List<Artist>> similarArtists(String artistId) async {
    final j = jf;
    if (j == null) return const [];
    try {
      final res = await j.get('/Artists/$artistId/Similar', {'UserId': j.userId, 'Limit': 24});
      final known = {for (final a in await artistItems()) ((a['Name'] ?? '') as String).toLowerCase()};
      return [
        for (final a in ((res as Map)['Items'] as List).cast<Item>())
          if (known.isEmpty || known.contains(((a['Name'] ?? '') as String).toLowerCase())) j.artist(a),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// A genre's albums.
  Future<List<Album>> genreAlbums(String genreId) async {
    final j = jf;
    if (j == null) return const [];
    final r = await j.getMerged('/Items', {
      ..._user,
      'GenreIds': genreId,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': true,
      'SortBy': 'SortName',
      'Fields': 'ProductionYear,UserData,SortName',
    });
    return (r..sort(_bySortName)).map(j.album).toList();
  }

  /// A genre's songs.
  Future<List<Song>> genreSongs(String genreId) async {
    final j = jf;
    if (j == null) return const [];
    final r = await j.getMerged('/Items', {
      ..._user,
      'GenreIds': genreId,
      'IncludeItemTypes': 'Audio',
      'Recursive': true,
      'SortBy': 'SortName',
      'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData,SortName',
    });
    return (r..sort(_bySortName)).map(j.song).toList();
  }

  /// Search across music and video (renderer.js runSearch): songs, albums,
  /// artists, and movies and shows when those libraries are chosen.
  Future<({List<Song> songs, List<Album> albums, List<Artist> artists, List<Video> movies, List<Video> shows})> search(String query) async {
    final j = jf;
    final q = query.trim();
    if (j == null || q.isEmpty) {
      return (songs: const <Song>[], albums: const <Album>[], artists: const <Artist>[], movies: const <Video>[], shows: const <Video>[]);
    }
    Future<List<Item>> safe(Future<List<Item>> f) => f.catchError((_) => <Item>[]);
    final r = await Future.wait([
      safe(
        j.getMerged('/Items', {
          ..._user,
          'SearchTerm': q,
          'Recursive': true,
          'Limit': 10,
          'IncludeItemTypes': 'Audio',
          'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData',
        }),
      ),
      safe(j.getMerged('/Items', {..._user, 'SearchTerm': q, 'Recursive': true, 'Limit': 8, 'IncludeItemTypes': 'MusicAlbum', 'Fields': 'ProductionYear'})),
      safe(j.getMerged('/Artists', {'UserId': j.userId, 'SearchTerm': q, 'Limit': 8})),
      movieIds.isEmpty
          ? Future.value(<Item>[])
          : safe(
              j.getMerged('/Items', {
                ..._user,
                'SearchTerm': q,
                'Recursive': true,
                'Limit': 8,
                'IncludeItemTypes': 'Movie',
                'Fields': 'ProductionYear',
              }, movieIds),
            ),
      showIds.isEmpty
          ? Future.value(<Item>[])
          : safe(
              j.getMerged('/Items', {
                ..._user,
                'SearchTerm': q,
                'Recursive': true,
                'Limit': 8,
                'IncludeItemTypes': 'Series',
                'Fields': 'ProductionYear',
              }, showIds),
            ),
    ]);
    return (
      songs: r[0].take(10).map(j.song).toList(),
      albums: r[1].take(8).map(j.album).toList(),
      artists: r[2].take(8).map(j.artist).toList(),
      movies: r[3].take(8).map(j.video).toList(),
      shows: r[4].take(8).map(j.video).toList(),
    );
  }

  // Writes -----------------------------------------------------------------

  /// Likes changed this session, over what the server sent with each item.
  final _favorites = <String, bool>{};

  bool isFavorite(String id, bool fromServer) => _favorites[id] ?? fromServer;

  /// Flip a like, showing it at once and putting it back if the server
  /// refuses.
  Future<void> toggleFavorite(String id, bool fromServer) async {
    final on = !isFavorite(id, fromServer);
    _favorites[id] = on;
    notifyListeners();
    // Offline: queued in the catalog, sent when the server is back.
    final d = downloads, j = jf;
    if (offline && d != null && j != null) {
      addChange(d.index, {'itemId': id, 'kind': 'favorite', 'favorite': on, 'was': !on, 'userId': j.userId, 'at': DateTime.now().toUtc().toIso8601String()});
      await d.save();
      return;
    }
    var ok = false;
    try {
      ok = await setFavorite(id, on);
    } catch (_) {}
    if (!ok) {
      _favorites[id] = !on;
      notifyListeners();
    }
  }

  /// Like or unlike anything (POST/DELETE /UserFavoriteItems, the only
  /// favorites route in Jellyfin 10.11 and 12). True when the server took it.
  Future<bool> setFavorite(String id, bool on) async {
    final j = jf;
    if (j == null || id.isEmpty) return false;
    try {
      if (on) {
        await j.post('/UserFavoriteItems/$id', null, _user);
        return true;
      }
      return await j.del('/UserFavoriteItems/$id', _user);
    } finally {
      _cache.remove('albums');
      _cache.remove('artists');
      _cache.remove('songs');
    }
  }

  /// Mark played or unplayed (/UserPlayedItems).
  Future<bool> setPlayed(String id, bool on) async {
    final j = jf;
    if (j == null || id.isEmpty) return false;
    if (on) {
      await j.post('/UserPlayedItems/$id', null, _user);
      return true;
    }
    return j.del('/UserPlayedItems/$id', _user);
  }

  /// A new playlist with [songIds] in it; its id.
  Future<String?> createPlaylist(String name, List<String> songIds) async {
    final j = jf;
    if (j == null) return null;
    final res = await j.post('/Playlists', {'Name': name, 'Ids': songIds, 'UserId': j.userId, 'MediaType': 'Audio'});
    invalidate('playlists');
    return (res as Map?)?['Id'] as String?;
  }

  Future<void> addToPlaylist(String playlistId, List<String> songIds) async {
    final j = jf;
    if (j == null || songIds.isEmpty) return;
    await _playlistGate(playlistId);
    await j.post('/Playlists/$playlistId/Items', null, {'ids': songIds.join(','), 'userId': j.userId});
    invalidate('playlists');
  }

  /// Rewrite a playlist's songs in one request (renderer.js savePlaylistIds):
  /// removing and reordering both go through here.
  Future<void> setPlaylistSongs(String playlistId, List<String> songIds) async {
    final j = jf;
    if (j == null) return;
    await _playlistGate(playlistId);
    await j.post('/Playlists/$playlistId', {'Ids': songIds});
    invalidate('playlists');
  }

  Future<void> renamePlaylist(String playlistId, String name) async {
    final j = jf;
    if (j == null) return;
    await _playlistGate(playlistId);
    await j.post('/Playlists/$playlistId', {'Name': name});
    invalidate('playlists');
  }

  Future<bool> deleteItem(String id) async {
    final j = jf;
    if (j == null) return false;
    final ok = await j.del('/Items/$id');
    invalidate();
    return ok;
  }

  // Jellyfin's background playlist.xml saver can undo a write that follows
  // another too closely, so writes to one playlist are spaced 400 ms apart
  // (playlist-edit.ts createPlaylistWriteGate).
  final _nextWrite = <String, DateTime>{};
  Future<void> _playlistGate(String id) async {
    final now = DateTime.now();
    final slot = _nextWrite[id] != null && _nextWrite[id]!.isAfter(now) ? _nextWrite[id]! : now;
    _nextWrite[id] = slot.add(const Duration(milliseconds: 400));
    if (slot.isAfter(now)) await Future<void>.delayed(slot.difference(now));
  }

  /// Smart playlists: rules kept on this device (the desktop's smartPlaylists
  /// key), worked out against the library each time they open.
  Future<List<SmartPlaylistDef>> smartPlaylists() async => parseSmartPlaylists((await SharedPreferences.getInstance()).getString('smartPlaylists'));

  Future<void> saveSmartPlaylists(List<SmartPlaylistDef> defs) async {
    await (await SharedPreferences.getInstance()).setString('smartPlaylists', serializeSmartPlaylists(defs));
    notifyListeners();
  }

  Future<List<Song>> smartSongs(SmartPlaylistDef def) async {
    final j = jf;
    if (j == null) return const [];
    final r = await j.getMerged('/Items', {
      ..._user,
      'IncludeItemTypes': 'Audio',
      'Recursive': true,
      'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData,Genres,DateCreated,ProductionYear,SortName',
      ...toItemsQuery(def),
    });
    return applySmartPlaylistRules(r, def, DateTime.now().millisecondsSinceEpoch).map(j.song).toList();
  }

  /// Songs like this one, album or artist (Instant Mix).
  Future<List<Song>> instantMix(String id) async {
    final j = jf;
    if (j == null) return const [];
    final res = await j.get('/Items/$id/InstantMix', {'UserId': j.userId, 'Limit': 50, 'Fields': 'AlbumId,AlbumPrimaryImageTag'});
    return [for (final i in ((res as Map)['Items'] as List).cast<Item>()) j.song(i)];
  }

  /// An album's tracks in disc and track order, or a playlist's in its order.
  Future<List<Song>> tracksOf(Album a) async {
    final j = jf;
    if (j == null || a.id.isEmpty) return const [];
    final res = a.playlist
        ? await j.get('/Playlists/${a.id}/Items', {'userId': j.userId, 'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData'})
        : await j.get('/Items', {
            'userId': j.userId,
            'ParentId': a.id,
            'IncludeItemTypes': 'Audio',
            'Recursive': true,
            'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
            'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData,MediaSources',
          });
    return [for (final i in ((res as Map)['Items'] as List).cast<Item>()) j.song(i)];
  }

  Future<void> signOut() async {
    _retry?.cancel();
    error = null;
    await jf?.signOut();
    jf = null;
    demo = false;
    policy = null;
    musicLibs = movieLibs = showLibs = [];
    movieIds = showIds = [];
    recentlyPlayed = frequent = [];
    recentlyAdded = playlists = [];
    continueWatching = [];
    _cache.clear();
    notifyListeners();
  }
}
