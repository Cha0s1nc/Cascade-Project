import 'dart:io';
// Android (and any narrow window). Music and Video are separate modes, like
// the Swift iPhone app: a button in the search bar switches them, and the
// navigation bar follows (Music: Home, Library, Downloads, Settings; Video:
// Home, Movies, Shows, Downloads, Settings). Each tab keeps its own history.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:cascade/ui/desktop.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/browse_mode.dart';
import 'package:cascade/core/offline_index.dart' show downloadSections;
import 'package:cascade/core/data.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/ui/now_playing.dart';
import 'package:cascade/ui/pages/browse.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/pages/home.dart';
import 'package:cascade/ui/pages/library.dart';
import 'package:cascade/ui/pages/pages.dart';
import 'package:cascade/ui/phone_now_playing.dart';
import 'package:cascade/ui/settings_panel.dart';
import 'package:cascade/ui/video_player.dart' show videoBack, videoFull;
import 'package:cascade/ui/widgets.dart';
import 'package:cascade/ui/scopes.dart';

typedef _Tab = (String id, String label, IconData icon, IconData selected);

// Search is a tab (where Downloads was): Downloads are in Library as on the
// desktop's sidebar, switching Offline Mode, and managed in Settings > Offline.
const _musicTabs = <_Tab>[
  ('home', 'Home', Icons.home_outlined, Icons.home_rounded),
  ('search', 'Search', Icons.search_outlined, Icons.search_rounded),
  ('library', 'Library', Icons.library_music_outlined, Icons.library_music_rounded),
  ('settings', 'Settings', Icons.settings_outlined, Icons.settings_rounded),
];

const _videoTabs = <_Tab>[
  ('vhome', 'Home', Icons.home_outlined, Icons.home_rounded),
  ('search', 'Search', Icons.search_outlined, Icons.search_rounded),
  ('movies', 'Movies', Icons.movie_outlined, Icons.movie_rounded),
  ('shows', 'Shows', Icons.tv_outlined, Icons.tv_rounded),
  ('settings', 'Settings', Icons.settings_outlined, Icons.settings_rounded),
];

class PhoneShell extends StatefulWidget {
  const PhoneShell({super.key});

  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

/// The phone layout on a computer (a narrow window, chosen in the Style menu):
/// no system back, so it gets a back button, and no Movies and TV until wider.
final _computer = !(Platform.isAndroid || Platform.isIOS);

class _PhoneShellState extends State<PhoneShell> {
  final _nav = Nav();
  final _np = NowPlaying();
  final _query = TextEditingController();
  String _mode = 'music';

  @override
  void initState() {
    super.initState();
    final lib = LibraryScope.read(context);
    SharedPreferences.getInstance().then((p) {
      final m = resolveBrowseMode(p.getString('browseMode'), lib.hasVideo || lib.demo);
      // A computer's phone layout opens on music, whatever was last browsed.
      if (mounted && m != _mode && !(_computer && m == 'video')) _setMode(m, save: false);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _nav.dispose();
    _np.dispose();
    _query.dispose();
    super.dispose();
  }

  List<_Tab> get _tabs => _mode == 'video' ? _videoTabs : _musicTabs;
  int get _tab => _tabs.indexWhere((t) => t.$1 == _nav.view).clamp(0, _tabs.length - 1);

  void _setMode(String m, {bool save = true}) {
    // A computer shows Movies and TV in the desktop layout only.
    if (m == 'video' && _computer) {
      toast(context, 'Widen the window for Movies and TV');
      m = 'music';
      if (m == _mode) return;
    }
    setState(() => _mode = m);
    _nav.show(m == 'video' ? 'vhome' : 'home');
    if (save) SharedPreferences.getInstance().then((p) => p.setString('browseMode', m), onError: (_) => false);
  }

  /// A search bar tapped: the Search tab, its field ready to type in.
  bool _focusSearch = false;
  void _search() {
    _focusSearch = true;
    _nav.show('search');
  }

  // Android's Back: Now Playing first, then this tab's history, then Home,
  // then out of the app.
  @override
  Widget build(BuildContext context) {
    // Only video on this server: Video mode, and no way back to an empty Music.
    final lib = LibraryScope.of(context);
    if (!_computer && !lib.demo && !lib.loading && lib.jf != null && lib.musicLibs.isEmpty && lib.hasVideo && _mode == 'music') {
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _setMode('video', save: false) : null);
    }
    return _shell(context);
  }

  Widget _shell(BuildContext context) => NavScope(
    nav: _nav,
    child: NowPlayingScope(
      np: _np,
      child: SearchScope(
        query: _query,
        child: ListenableBuilder(
          listenable: Listenable.merge([_nav, _np, videoFull]),
          builder: (context, _) {
            final home = _mode == 'video' ? 'vhome' : 'home';
            // On a computer (a window narrowed into this layout) the
            // desktop's keys still work: Space, Ctrl+arrows, Esc.
            final keys = Platform.isAndroid || Platform.isIOS
                ? const <ShortcutActivator, VoidCallback>{}
                : {...playbackShortcuts(PlayerScope.read(context)), const SingleActivator(LogicalKeyboardKey.escape): _np.close};
            return CallbackShortcuts(
              bindings: keys,
              child: Focus(
                autofocus: keys.isNotEmpty,
                child: PopScope(
                  // A video filling the screen shrinks to its corner first.
                  canPop: !videoFull.value && !_np.open && !_nav.canBack && _nav.view == home,
                  onPopInvokedWithResult: (didPop, _) {
                    if (didPop || videoBack()) return;
                    if (_np.open) return _np.close();
                    if (!_nav.back()) _nav.show(home);
                  },
                  // A mouse's back button, as on the desktop layout.
                  child: Listener(
                    onPointerDown: (e) {
                      if (e.buttons & kBackMouseButton == 0) return;
                      if (_np.open) return _np.close();
                      if (!_nav.back()) _nav.show(home);
                    },
                    child: Stack(
                      children: [
                        Scaffold(
                          backgroundColor: A.bg,
                          body: DecoratedBox(
                            decoration: BoxDecoration(gradient: K.wash),
                            child: SafeArea(
                              bottom: false,
                              // Pages ease in from a little below as they change.
                              child: Column(
                                children: [
                                  // A computer has no system back: a button, when
                                  // there is somewhere to go back to.
                                  if (_computer && (_nav.canBack || _nav.view != home))
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                                        child: IconBtn(Icons.arrow_back_rounded, 'Back', () => _nav.back() ? null : _nav.show(home)),
                                      ),
                                    ),
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration: Motion.slow,
                                      reverseDuration: Motion.fast,
                                      switchInCurve: const Cubic(.2, .8, .2, 1),
                                      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
                                      transitionBuilder: (c, a) => FadeTransition(
                                        opacity: a,
                                        child: calm(context)
                                            ? c
                                            : SlideTransition(
                                                position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a),
                                                child: c,
                                              ),
                                      ),
                                      child: KeyedSubtree(key: ObjectKey(_nav.top), child: _body()),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          bottomNavigationBar: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const _MiniPlayer(),
                              NavigationBar(
                                selectedIndex: _tab,
                                onDestinationSelected: (i) => _nav.show(_tabs[i].$1),
                                backgroundColor: A.nav,
                                indicatorColor: A.indicator,
                                height: 72,
                                labelTextStyle: WidgetStatePropertyAll(ts(12, w: FontWeight.w500, c: A.text2)),
                                destinations: [
                                  for (final t in _tabs)
                                    NavigationDestination(
                                      icon: Icon(t.$3, color: A.text2),
                                      selectedIcon: Icon(t.$4, color: K.accent),
                                      label: t.$2,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (_np.open) const Positioned.fill(child: PhoneNowPlaying()),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _body() {
    final e = _nav.top;
    if (e.page != null) return pageFor(e);
    final focus = _focusSearch;
    _focusSearch = false;
    return switch (_nav.view) {
      'search' => _PhoneSearch(query: _query, autofocus: focus),
      'home' => _Home(onSearch: _search, onMode: () => _setMode('video')),
      'vhome' => _VideoHome(onSearch: _search, onMode: () => _setMode('music')),
      'library' => const _LibraryHub(),
      'settings' => const SettingsPanel(),
      final v => viewFor(v),
    };
  }
}

/// The search bar at the top of Home, with the mode switch and the bell.
class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onSearch, required this.onMode, required this.video});
  final VoidCallback onSearch, onMode;
  final bool video;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: Hover(
      onTap: onSearch,
      builder: (_, _) => Container(
        height: 56,
        padding: const EdgeInsets.only(left: 18, right: 4),
        decoration: BoxDecoration(color: A.bar, borderRadius: BorderRadius.circular(28)),
        child: Row(
          children: [
            Icon(Icons.search_rounded, color: A.text2),
            const SizedBox(width: 12),
            Expanded(
              child: Text(video ? 'Search movies and shows' : 'Search songs, albums, artists', style: ts(16, c: A.text2)),
            ),
            if (LibraryScope.of(context).demo || (LibraryScope.of(context).hasVideo && LibraryScope.of(context).musicLibs.isNotEmpty))
              IconButton(
                tooltip: video ? 'Music' : 'Movies and TV',
                onPressed: onMode,
                icon: Icon(video ? Icons.music_note_rounded : Icons.videocam_outlined, color: A.text),
              ),
          ],
        ),
      ),
    ),
  );
}

class _Home extends StatelessWidget {
  const _Home({required this.onSearch, required this.onMode});
  final VoidCallback onSearch, onMode;

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    final played = lib.recentlyPlayed;
    final tiles = played.skip(1).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _SearchBar(onSearch: onSearch, onMode: onMode, video: false),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(today().toUpperCase(), style: Txt.caps()),
              const SizedBox(height: 6),
              Text(greeting(lib.jf?.userName ?? 'Cha0s'), style: ds(28)),
              const SizedBox(height: 4),
              FutureBuilder(
                future: lib.stats(),
                builder: (context, snap) => Text(snap.hasData && snap.data!.week > 0 ? '${snap.data!.week} songs played this week.' : '', style: Txt.voice()),
              ),
            ],
          ),
        ),
        LoadError(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0)),
        if (lib.loading && played.isEmpty)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          ),
        if (played.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 0), child: HeroCard(played.first, played, compact: true, radius: 28)),
        _shelf(context, 'Recently played', 160, () => NavScope.read(context).open(PageKind.view, ['history']), _songColumns(tiles, played)),
        _shelf(context, 'Recently added', 196, () => NavScope.read(context).open(PageKind.view, ['albums']), [
          for (final a in lib.recentlyAdded) SizedBox(width: 132, height: 184, child: albumCard(context, a)),
        ]),
        _shelf(context, 'Recent playlists', 196, () => NavScope.read(context).open(PageKind.view, ['playlists']), [
          for (final a in lib.playlists) SizedBox(width: 132, height: 184, child: albumCard(context, a)),
        ]),
        _shelf(context, 'Frequently played', 160, null, _songColumns(lib.frequent, lib.frequent)),
      ],
    );
  }

  /// Songs three to a column, the columns side by side.
  List<Widget> _songColumns(List<Song> songs, List<Song> queue) => [
    for (var i = 0; i < songs.length; i += 3)
      SizedBox(
        width: 300,
        child: Column(spacing: 8, children: [for (final s in songs.skip(i).take(3)) SongTile(s, queue: queue)]),
      ),
  ];
}

/// A titled, sideways-scrolling shelf; nothing at all when it has no items.
Widget _shelf(BuildContext context, String title, double height, VoidCallback? more, List<Widget> items) => items.isEmpty
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  Expanded(child: Text(title, style: Txt.section())),
                  if (more != null)
                    TextButton(
                      onPressed: more,
                      child: Text(
                        'See all',
                        style: ts(14, w: FontWeight.w500, c: K.accent),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: height,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, i) => Align(alignment: Alignment.topLeft, child: items[i]),
              ),
            ),
          ],
        ),
      );

/// Video mode's Home: Continue watching, then into Movies and Shows.
class _VideoHome extends StatelessWidget {
  const _VideoHome({required this.onSearch, required this.onMode});
  final VoidCallback onSearch, onMode;

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _SearchBar(onSearch: onSearch, onMode: onMode, video: true),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Movies and TV', style: ds(28)),
        ),
        _shelf(context, 'Continue watching', 190, null, [
          for (final v in lib.continueWatching)
            Hover(
              onTap: () => openVideo(context, v),
              builder: (_, _) => SizedBox(
                width: 240,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    VideoThumb(v, width: 240),
                    const SizedBox(height: 8),
                    Text(
                      v.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(14, w: FontWeight.w600),
                    ),
                    Text(
                      '${v.episode} · ${v.left}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(12, c: A.text2),
                    ),
                  ],
                ),
              ),
            ),
        ]),
        if (lib.continueWatching.isEmpty) const Empty('Nothing in progress.', icon: Icons.movie_outlined),
      ],
    );
  }
}

/// The Library tab: one row per view, then Recently added.
class _LibraryHub extends StatelessWidget {
  const _LibraryHub();

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    final nav = NavScope.read(context);
    final held = downloadSections(DownloadsScope.of(context).index);
    final rows = [
      ('albums', 'Albums', Icons.album_outlined),
      ('artists', 'Artists', Icons.person_outline_rounded),
      ('songs', 'Songs', Icons.music_note_outlined),
      ('playlists', 'Playlists', Icons.queue_music_rounded),
      ('genres', 'Genres', Icons.sell_outlined),
      ('history', 'History', Icons.history_rounded),
      if (PlayerScope.read(context).settings.radioEnabled && lib.hasLiveTv) ('radio', 'Radio', Icons.radio_outlined),
      ('rediscover', 'Rediscover', Icons.auto_awesome_outlined),
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text('Library', style: Txt.title()),
        ),
        for (final (id, label, icon) in rows)
          Hover(
            onTap: () => nav.open(PageKind.view, [id]),
            builder: (_, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: K.surface, borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, size: 20, color: K.accent),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(label, style: ts(15, w: FontWeight.w500)),
                  ),
                  if (held[id] case final d?) DownloadMark(d),
                  if (id == 'rediscover')
                    Text(
                      'New',
                      style: ts(12, w: FontWeight.w500, c: K.accent),
                    ),
                ],
              ),
            ),
          ),
        // Downloads switch Offline Mode (only your downloads, still signed in),
        // as on the desktop's sidebar; they are managed in Settings > Offline.
        if (!lib.demo)
          Hover(
            onTap: () => lib.setOfflineMode(!lib.offline),
            label: lib.offline ? 'Offline Mode is on: only your downloads. Tap to go back online.' : 'Offline Mode: only your downloads',
            builder: (_, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: lib.offline ? K.accentTint : K.surface, borderRadius: BorderRadius.circular(12)),
                    child: Icon(Icons.download_outlined, size: 20, color: K.accent),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text('Downloads', style: ts(15, w: FontWeight.w500)),
                  ),
                  Text(
                    lib.offline ? 'Offline' : 'Online',
                    style: ts(12, w: FontWeight.w500, c: lib.offline ? K.accent : K.text3),
                  ),
                ],
              ),
            ),
          ),
        _shelf(context, 'Recently added', 196, () => nav.open(PageKind.view, ['albums']), [
          for (final a in lib.recentlyAdded) SizedBox(width: 132, height: 184, child: albumCard(context, a)),
        ]),
      ],
    );
  }
}

/// Search with its own field, since phones have no title bar.
class _PhoneSearch extends StatelessWidget {
  const _PhoneSearch({required this.query, this.autofocus = false});
  final TextEditingController query;

  /// Opened from a search bar: the field ready to type in.
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: query,
                autofocus: autofocus,
                style: ts(16),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search your library',
                  hintStyle: ts(16, c: A.text2),
                  filled: true,
                  fillColor: A.bar,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
      const Expanded(child: SearchPage()),
    ],
  );
}

class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer();

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final song = p.song;
    if (song == null) return const SizedBox.shrink();
    final length = p.length;
    return GestureDetector(
      onTap: NowPlayingScope.read(context).toggle,
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -200) NowPlayingScope.read(context).show(NpPanel.lyrics);
      },
      child: Container(
        height: 64,
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: A.mini,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Cover(song.art, image: song.image, size: 46, radius: 8),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FullText(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(15, w: FontWeight.w500, c: A.text),
                        ),
                        Text(
                          p.error ?? song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(13, c: p.error == null ? A.text2 : K.error),
                        ),
                      ],
                    ),
                  ),
                  PlayCircle(playing: p.playing, onTap: p.toggle, size: 44),
                  IconButton(
                    tooltip: 'Next',
                    onPressed: p.next,
                    icon: Icon(Icons.skip_next_rounded, color: A.text),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                value: length > 0 ? p.position / length : 0,
                minHeight: 2,
                color: K.accent,
                backgroundColor: K.tint.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
