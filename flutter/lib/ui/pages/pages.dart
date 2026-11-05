// Which page a desktop tab or a page step shows.
import 'package:flutter/material.dart';

import 'package:cascade/core/nav.dart';
import 'package:cascade/ui/pages/browse.dart';
import 'package:cascade/ui/pages/detail.dart';
import 'package:cascade/ui/pages/downloads.dart';
import 'package:cascade/ui/pages/home.dart';
import 'package:cascade/ui/pages/library.dart';
import 'package:cascade/ui/pages/smart.dart';
import 'package:cascade/ui/pages/theme.dart';
import 'package:cascade/ui/settings_panel.dart';
import 'package:cascade/ui/widgets.dart';

/// A tab's own page.
Widget viewFor(String view) => switch (view) {
  'home' => const HomePage(),
  'albums' => Builder(builder: (c) => GridPage(albumsSpec(c))),
  'artists' => Builder(builder: (c) => GridPage(artistsSpec(c))),
  'playlists' => Builder(builder: (c) => GridPage(playlistsSpec(c))),
  'songs' => const SongsPage(),
  'genres' => const GenresPage(),
  'history' => const HistoryPage(),
  'radio' => const RadioPage(),
  'rediscover' => const RediscoverPage(),
  'search' => const SearchPage(),
  'movies' => const VideoGridPage(shows: false),
  'shows' => const VideoGridPage(shows: true),
  'settings' => const SettingsPanel(),
  'downloads' => const DownloadsPage(),
  'theme' => const ThemePage(),
  _ => _Missing(view),
};

/// A page opened inside a tab: an album, an artist, a playlist...
Widget pageFor(NavEntry e) {
  final id = e.args.isEmpty ? '' : '${e.args.first}';
  return switch (e.page!) {
    PageKind.album => AlbumPage(id),
    PageKind.artist => ArtistPage(id),
    PageKind.playlist => PlaylistPage(id),
    PageKind.smart => SmartPlaylistPage(id),
    PageKind.genre => GenrePage(id, e.args.length > 1 ? '${e.args[1]}' : 'Genre'),
    PageKind.movie || PageKind.series => VideoPage(id),
    PageKind.view => viewFor(id),
  };
}

class _Missing extends StatelessWidget {
  const _Missing(this.view);
  final String view;

  @override
  Widget build(BuildContext context) => Center(
    child: Text('$view is not built yet.', style: ts(14, c: K.text3)),
  );
}
