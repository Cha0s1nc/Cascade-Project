// What Home shows: the signed-in server's shelves, or the demo library.
// The queries are the desktop's (renderer.js loadRecentlyPlayed and friends),
// across every library rather than the chosen ones; there are no settings yet.
import 'package:flutter/widgets.dart';

import 'data.dart';
import 'jellyfin.dart';

class Library extends ChangeNotifier {
  Jellyfin? jf;
  bool demo = false, loading = false;
  String? error;
  List<Song> recentlyPlayed = [], frequent = [];
  List<Album> recentlyAdded = [], playlists = [];
  List<Video> continueWatching = [];

  bool get signedIn => demo || jf?.token != null;
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

  Future<void> refresh() async {
    final j = jf;
    if (j == null) return;
    loading = true;
    error = null;
    notifyListeners();
    Future<List<Map>> items(String path, Map<String, Object?> q) async => ((await j.get(path, {'userId': j.userId, ...q}))['Items'] as List).cast<Map>();
    const audio = {'IncludeItemTypes': 'Audio', 'Recursive': true, 'Filters': 'IsPlayed', 'SortOrder': 'Descending'};
    try {
      final r = await Future.wait([
        items('/Items', {...audio, 'SortBy': 'DatePlayed', 'Limit': 9}),
        items('/Items', {'IncludeItemTypes': 'MusicAlbum', 'Recursive': true, 'SortBy': 'DateCreated', 'SortOrder': 'Descending', 'Limit': 12}),
        items('/UserItems/Resume', {'MediaTypes': 'Video', 'Limit': 12}),
        items('/Items', {
          'IncludeItemTypes': 'Playlist',
          'Recursive': true,
          'SortBy': 'DatePlayed,SortName',
          'SortOrder': 'Descending',
          'Fields': 'ChildCount',
          'Limit': 12,
        }),
        items('/Items', {...audio, 'SortBy': 'PlayCount', 'Limit': 9}),
      ]);
      recentlyPlayed = r[0].map(j.song).toList();
      recentlyAdded = r[1].map(j.album).toList();
      continueWatching = r[2].map(j.video).toList();
      playlists = r[3].where((i) => i['MediaType'] != 'Video').map(j.album).toList();
      frequent = r[4].map(j.song).toList();
    } catch (e) {
      error = 'Could not load Home: $e';
    }
    loading = false;
    notifyListeners();
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
    return [for (final i in (res['Items'] as List).cast<Map>()) j.song(i)];
  }

  Future<void> signOut() async {
    await jf?.signOut();
    jf = null;
    demo = false;
    recentlyPlayed = frequent = [];
    recentlyAdded = playlists = [];
    continueWatching = [];
    notifyListeners();
  }
}

class LibraryScope extends InheritedNotifier<Library> {
  const LibraryScope({super.key, required Library library, required super.child}) : super(notifier: library);

  static Library of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LibraryScope>()!.notifier!;
  static Library read(BuildContext context) => context.getInheritedWidgetOfExactType<LibraryScope>()!.notifier!;
}
