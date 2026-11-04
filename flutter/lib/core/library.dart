// The signed-in library: the server's libraries and which ones are chosen,
// what the user may do, and Home's shelves. Or the demo library. The queries
// and selection rules are the desktop's (renderer.js connect() and
// loadRecentlyPlayed and friends); the setting names are electron-store's.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';

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

  /// The libraries, the user's policy and the chosen libraries, then Home.
  /// A server that does not answer is tried again by itself, 5 s later and
  /// then less often (up to every minute), until it does.
  Future<void> refresh() async {
    final j = jf;
    if (j == null) return;
    _retry?.cancel();
    loading = true;
    error = null;
    notifyListeners();
    try {
      await _connect(j);
      await _loadHome(j);
      _attempt = 0;
      onLoaded?.call();
    } catch (e) {
      final wait = min(60, 5 << min(_attempt++, 4));
      error = 'Could not reach your server, trying again in $wait s ($e)';
      _retry = Timer(Duration(seconds: wait), refresh);
    }
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _retry?.cancel();
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
    policy = (user as Map)['Policy'] as Map?;

    final prefs = await SharedPreferences.getInstance();
    // Music: what was saved, minus libraries that vanished; all of them when
    // nothing was ever chosen or nothing saved is left.
    final saved = (prefs.getStringList('libraryIds') ?? const []).where((id) => musicLibs.any((l) => l['Id'] == id)).toList();
    j.libraryIds = saved.isNotEmpty ? saved : [for (final l in musicLibs) l['Id'] as String];
    movieIds = effectiveLibraryIds(movieLibs, prefs.getStringList('movieLibraryIds'));
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

  /// The Live TV channels, as radio.
  Future<List<Song>> radioChannels() async {
    final j = jf;
    if (j == null) return const [];
    final res = await j.get('/LiveTv/Channels', {'userId': j.userId});
    return [for (final c in ((res as Map)['Items'] as List).cast<Item>()) j.channel(c)];
  }

  /// An album's tracks in disc and track order, or a playlist's in its order.
  Future<List<Song>> tracksOf(Album a) async {
    final j = jf;
    if (j == null || a.id.isEmpty) return const [];
    final res = a.playlist
        ? await j.get('/Playlists/${a.id}/Items', {'userId': j.userId})
        : await j.get('/Items', {
            'userId': j.userId,
            'ParentId': a.id,
            'IncludeItemTypes': 'Audio',
            'Recursive': true,
            'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
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
    notifyListeners();
  }
}
