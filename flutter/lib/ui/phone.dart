// Android (and any narrow window): search bar, Home, mini player, navigation bar.
import 'package:flutter/material.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/ui/sign_in.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:cascade/ui/scopes.dart';

const _tabs = [
  ('Home', Icons.home_outlined, Icons.home_rounded),
  ('Library', Icons.library_music_outlined, Icons.library_music_rounded),
  ('Video', Icons.video_library_outlined, Icons.video_library_rounded),
  ('Downloads', Icons.download_outlined, Icons.download_rounded),
  ('Settings', Icons.settings_outlined, Icons.settings_rounded),
];

class PhoneShell extends StatefulWidget {
  const PhoneShell({super.key});

  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends State<PhoneShell> {
  /// Tabs are views named after their labels ('home', 'library', ...), each
  /// with its own page history.
  final _nav = Nav();

  int get _tab => _tabs.indexWhere((t) => t.$1.toLowerCase() == _nav.view);

  @override
  void dispose() {
    _nav.dispose();
    super.dispose();
  }

  // Android's Back: this tab's history first, then Home, then out of the app.
  @override
  Widget build(BuildContext context) => NavScope(
    nav: _nav,
    child: ListenableBuilder(
      listenable: _nav,
      builder: (context, _) => PopScope(
        canPop: !_nav.canBack && _nav.view == 'home',
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (!_nav.back()) _nav.show('home');
        },
        child: Scaffold(
          backgroundColor: A.bg,
          body: switch (_nav.view) {
            _ when _nav.top.page != null => Center(
              child: Text('${_nav.top.page!.name}: phase 2', style: ts(16, c: A.text2)),
            ),
            'home' => const _Home(),
            'settings' => const AccountPanel(color: A.text),
            _ => Center(
              child: Text('${_tabs[_tab].$1}: not in the prototype yet', style: ts(16, c: A.text2)),
            ),
          },
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _MiniPlayer(),
              NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) => _nav.show(_tabs[i].$1.toLowerCase()),
                backgroundColor: A.nav,
                indicatorColor: A.indicator,
                height: 80,
                destinations: [
                  for (final t in _tabs)
                    NavigationDestination(
                      icon: Icon(t.$2, color: A.text2),
                      selectedIcon: Icon(t.$3, color: A.onIndicator),
                      label: t.$1,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    final played = lib.recentlyPlayed;
    final tiles = played.skip(1).toList();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [K.accent.withValues(alpha: 0.18), K.accent.withValues(alpha: 0)],
          stops: const [0, 0.35],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: SearchBar(
                hintText: 'Search songs, albums, artists',
                elevation: const WidgetStatePropertyAll(0),
                backgroundColor: const WidgetStatePropertyAll(A.bar),
                hintStyle: WidgetStatePropertyAll(ts(16, c: A.text2)),
                textStyle: WidgetStatePropertyAll(ts(16, c: A.text)),
                padding: const WidgetStatePropertyAll(EdgeInsets.only(left: 18, right: 4)),
                leading: const Icon(Icons.search_rounded, color: A.text2),
                trailing: [
                  IconButton(
                    tooltip: 'Announcements',
                    onPressed: () {},
                    icon: const Badge(
                      smallSize: 8,
                      backgroundColor: K.accent,
                      child: Icon(Icons.notifications_none_rounded, color: A.text),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(greeting(lib.jf?.userName ?? 'Cha0s'), style: ts(28, c: A.text)),
                  const SizedBox(height: 2),
                  Text(today(), style: ts(14, c: A.text2)),
                ],
              ),
            ),
            if (lib.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(lib.error!, style: ts(13, c: const Color(0xFFFF453A))),
              ),
            if (lib.loading && played.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (played.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                child: HeroCard(played.first, played, compact: true, base: A.card, radius: 28),
              ),
            _section('Recently played', 160, true, _songColumns(tiles, played)),
            _section('Continue watching', 176, false, [
              for (final v in lib.continueWatching)
                SizedBox(
                  width: 220,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      VideoThumb(v, width: 220),
                      const SizedBox(height: 8),
                      Text(
                        v.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(14, w: FontWeight.w600, c: A.text),
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
            ]),
            _section('Recently added', 196, true, [for (final a in lib.recentlyAdded) AlbumCard(a, width: 126)]),
            _section('Recent playlists', 196, true, [for (final a in lib.playlists) AlbumCard(a, width: 126)]),
            _section('Frequently played', 160, false, _songColumns(lib.frequent, lib.frequent)),
          ],
        ),
      ),
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

  /// A titled, sideways-scrolling shelf; nothing at all when it has no items.
  Widget _section(String title, double height, bool more, List<Widget> items) => items.isEmpty
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
                    Expanded(
                      child: Text(title, style: ts(22, c: A.text)),
                    ),
                    if (more)
                      TextButton(
                        onPressed: () {},
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
}

class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer();

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final song = p.song;
    if (song == null) return const SizedBox.shrink();
    final length = p.length;
    return Container(
      height: 64,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: A.mini,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Cover(song.art, image: song.image, size: 48, radius: 8),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(15, w: FontWeight.w500, c: A.text),
                      ),
                      Text(
                        p.error ?? song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(13, c: p.error == null ? A.text2 : const Color(0xFFFF453A)),
                      ),
                    ],
                  ),
                ),
                PlayCircle(playing: p.playing, onTap: p.toggle, size: 44),
                IconButton(
                  tooltip: 'Next',
                  onPressed: p.next,
                  icon: const Icon(Icons.skip_next_rounded, color: A.text),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(value: length > 0 ? p.position / length : 0, minHeight: 3, color: K.accent, backgroundColor: Colors.white12),
          ),
        ],
      ),
    );
  }
}
