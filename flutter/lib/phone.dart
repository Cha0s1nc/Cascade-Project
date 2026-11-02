// Android (and any narrow window): search bar, Home, mini player, navigation bar.
import 'package:flutter/material.dart';

import 'data.dart';
import 'player.dart';
import 'widgets.dart';

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
  int _tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: A.bg,
        body: _tab == 0 ? const _Home() : Center(child: Text('${_tabs[_tab].$1}: not in the prototype yet', style: ts(16, c: A.text2))),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.fromLTRB(8, 0, 8, 8), child: _MiniPlayer()),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            backgroundColor: A.nav,
            indicatorColor: A.indicator,
            height: 80,
            destinations: [
              for (final t in _tabs) NavigationDestination(icon: Icon(t.$2, color: A.text2), selectedIcon: Icon(t.$3, color: A.onIndicator), label: t.$1),
            ],
          ),
        ]),
      );
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) => DecoratedBox(
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
          child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
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
                    icon: const Badge(smallSize: 8, backgroundColor: K.accent, child: Icon(Icons.notifications_none_rounded, color: A.text)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(greeting('Cha0s'), style: ts(28, c: A.text)),
                const SizedBox(height: 2),
                Text(today(), style: ts(14, c: A.text2)),
              ]),
            ),
            const Padding(padding: EdgeInsets.fromLTRB(16, 20, 16, 0), child: HeroCard(compact: true, base: A.card, radius: 28)),
            _section('Recently played', 160, true, [
              for (var i = 0; i < recentlyPlayed.length; i += 3)
                SizedBox(width: 300, child: Column(spacing: 8, children: [for (final s in recentlyPlayed.skip(i).take(3)) SongTile(s)])),
            ]),
            _section('Continue watching', 176, false, [
              for (final v in continueWatching)
                SizedBox(
                  width: 220,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    VideoThumb(v, width: 220),
                    const SizedBox(height: 8),
                    Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(14, w: FontWeight.w600, c: A.text)),
                    Text('${v.episode} · ${v.left}', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(12, c: A.text2)),
                  ]),
                ),
            ]),
            _section('Recently added', 196, true, [for (final a in recentlyAdded) AlbumCard(a, width: 126)]),
            _section('Recent playlists', 196, true, [for (final a in recentPlaylists) AlbumCard(a, width: 126)]),
            _section('Frequently played', 160, false, [
              for (var i = 0; i < recentlyPlayed.length; i += 3)
                SizedBox(width: 300, child: Column(spacing: 8, children: [for (final s in recentlyPlayed.reversed.skip(i).take(3)) SongTile(s)])),
            ]),
          ]),
        ),
      );

  Widget _section(String title, double height, bool more, List<Widget> items) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(children: [
              Expanded(child: Text(title, style: ts(22, c: A.text))),
              if (more) TextButton(onPressed: () {}, child: Text('See all', style: ts(14, w: FontWeight.w500, c: K.accent))),
            ]),
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
        ]),
      );
}

class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer();

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    return Container(
      height: 64,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: A.mini, borderRadius: BorderRadius.circular(16), boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))]),
      child: Stack(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            Cover(p.song.art, size: 48, radius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(15, w: FontWeight.w500, c: A.text)),
                Text(p.song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(13, c: A.text2)),
              ]),
            ),
            PlayCircle(playing: p.playing, onTap: p.toggle, size: 44),
            IconButton(tooltip: 'Next', onPressed: p.next, icon: const Icon(Icons.skip_next_rounded, color: A.text)),
          ]),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: LinearProgressIndicator(value: p.position / p.song.seconds, minHeight: 3, color: K.accent, backgroundColor: Colors.white12),
        ),
      ]),
    );
  }
}
