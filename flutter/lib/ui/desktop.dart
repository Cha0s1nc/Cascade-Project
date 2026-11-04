// Windows and Linux layout: top bar, sidebar, Home, player bar.
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/library.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/settings_panel.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:cascade/ui/scopes.dart';

typedef NavItem = (String? section, String id, String label, IconData icon);

// Home is the Cascade logo above these (_HomeBrand).
const _navItems = <NavItem>[
  ('Library', 'albums', 'Albums', Icons.album_outlined),
  (null, 'artists', 'Artists', Icons.person_outline_rounded),
  (null, 'songs', 'Songs', Icons.music_note_outlined),
  (null, 'playlists', 'Playlists', Icons.queue_music_rounded),
  (null, 'genres', 'Genres', Icons.sell_outlined),
  ('Listening', 'history', 'History', Icons.history_rounded),
  (null, 'radio', 'Radio', Icons.radio_outlined),
  ('Video', 'movies', 'Movies', Icons.movie_outlined),
  (null, 'shows', 'TV Shows', Icons.tv_rounded),
];

/// The sidebar's rows that lead somewhere, each with the section header to
/// draw above it (only on a section's first shown row). Radio needs Live TV on
/// the server and the setting on; Movies and TV Shows a chosen library.
List<(String?, NavItem)> _visibleNav(Library lib, Settings s) {
  bool shown(NavItem i) => switch (i.$2) {
    'radio' => s.radioEnabled && lib.hasLiveTv,
    'movies' => lib.demo || lib.movieIds.isNotEmpty,
    'shows' => lib.demo || lib.showIds.isNotEmpty,
    _ => true,
  };
  final out = <(String?, NavItem)>[];
  String? section, last;
  for (final i in _navItems) {
    section = i.$1 ?? section;
    if (!shown(i)) continue;
    out.add((section != last ? section : null, i));
    last = section;
  }
  return out;
}

const _navBottom = <NavItem>[(null, 'downloads', 'Downloads', Icons.download_outlined), (null, 'settings', 'Settings', Icons.settings_outlined)];

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  final _nav = Nav();
  bool _collapsed = false;
  final _search = FocusNode();

  @override
  void dispose() {
    _nav.dispose();
    _search.dispose();
    super.dispose();
  }

  // Back and Forward: the title bar buttons, the mouse's side buttons, and
  // Alt+Left/Right (Cmd+[ and ] on a Mac), as on the desktop.
  @override
  Widget build(BuildContext context) => NavScope(
    nav: _nav,
    child: ListenableBuilder(listenable: _nav, builder: (context, _) => _shell()),
  );

  Widget _shell() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search.requestFocus,
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _search.requestFocus,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _nav.back,
      const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): _nav.forward,
      const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): _nav.back,
      const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true): _nav.forward,
    },
    child: Listener(
      onPointerDown: (e) {
        if (e.buttons & kBackMouseButton != 0) _nav.back();
        if (e.buttons & kForwardMouseButton != 0) _nav.forward();
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: K.root,
          body: Column(
            children: [
              _topBar(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      _Sidebar(view: _nav.view, collapsed: _collapsed, onGo: _nav.show),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _MainPanel(view: _nav.view, entry: _nav.top, onGo: _nav.show),
                      ),
                    ],
                  ),
                ),
              ),
              const _PlayerBar(),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _topBar() => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          SizedBox(
            width: 260,
            child: Row(
              children: [
                _IconBtn(Icons.view_sidebar_outlined, _collapsed ? 'Show sidebar' : 'Hide sidebar', () => setState(() => _collapsed = !_collapsed)),
                const SizedBox(width: 4),
                _IconBtn(Icons.chevron_left_rounded, 'Back', _nav.canBack ? _nav.back : null, filled: true),
                const SizedBox(width: 4),
                _IconBtn(Icons.chevron_right_rounded, 'Forward', _nav.canForward ? _nav.forward : null, filled: true),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: _SearchField(_search)),
            ),
          ),
          SizedBox(
            width: 260,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _IconBtn(Icons.notifications_none_rounded, 'Announcements', () {}, badge: true),
                const SizedBox(width: 4),
                _IconBtn(Icons.brush_outlined, 'Theme', () {}),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _IconBtn extends StatelessWidget {
  const _IconBtn(this.icon, this.tip, this.onTap, {this.filled = false, this.badge = false, this.color = K.text2, this.size = 18});
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  final bool filled, badge;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final i = Icon(icon, size: size, color: onTap == null ? K.text3.withValues(alpha: 0.5) : color);
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: Hover(
        onTap: onTap,
        builder: (_, on) => Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(
              alpha: on && onTap != null
                  ? 0.1
                  : filled
                  ? 0.06
                  : 0,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: badge ? Badge(smallSize: 7, backgroundColor: K.accent, child: i) : i,
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField(this.focus);
  final FocusNode focus;

  @override
  Widget build(BuildContext context) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return SizedBox(
      height: 32,
      child: TextField(
        focusNode: focus,
        style: ts(13),
        cursorColor: K.accent,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: K.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          prefixIcon: const Icon(Icons.search_rounded, size: 16, color: K.text3),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          hintText: 'Search songs, albums, artists…',
          hintStyle: ts(13, c: K.text3),
          suffixIcon: Center(
            widthFactor: 1,
            child: Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: K.surface2, borderRadius: BorderRadius.circular(5)),
              child: Text(
                mac ? '⌘K' : 'Ctrl K',
                style: ts(11, w: FontWeight.w500, c: K.text3),
              ),
            ),
          ),
          suffixIconConstraints: const BoxConstraints(minHeight: 32),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: K.surface2),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: K.accent),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.view, required this.collapsed, required this.onGo});
  final String view;
  final bool collapsed;
  final ValueChanged<String> onGo;

  @override
  // Rebuilt when the settings change too: Radio follows its switch.
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PlayerScope.read(context).settings,
    builder: (context, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: collapsed ? 60 : 232,
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
      decoration: BoxDecoration(color: K.panel, borderRadius: BorderRadius.circular(14)),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: collapsed ? 40 : 212,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HomeBrand(active: view == 'home', collapsed: collapsed, onGo: onGo),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (header, item) in _visibleNav(LibraryScope.of(context), PlayerScope.read(context).settings)) ...[
                        if (header != null)
                          collapsed
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                                  child: Divider(height: 1, color: K.surface2),
                                )
                              : Padding(
                                  padding: const EdgeInsets.fromLTRB(10, 14, 0, 6),
                                  child: Text(
                                    header.toUpperCase(),
                                    style: ts(11, w: FontWeight.w600, c: K.text3, ls: 0.6),
                                  ),
                                ),
                        _NavRow(item, active: view == item.$2, collapsed: collapsed, onGo: onGo),
                      ],
                    ],
                  ),
                ),
              ),
              for (final item in _navBottom) _NavRow(item, active: view == item.$2, collapsed: collapsed, onGo: onGo),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The Cascade logo is the Home button, labeled Your Cascade: hovering it
/// shows a home icon over the logo.
class _HomeBrand extends StatelessWidget {
  const _HomeBrand({required this.active, required this.collapsed, required this.onGo});
  final bool active, collapsed;
  final ValueChanged<String> onGo;

  @override
  Widget build(BuildContext context) {
    const fade = Duration(milliseconds: 150);
    final row = Hover(
      onTap: () => onGo('home'),
      builder: (_, on) => Stack(
        children: [
          Container(
            height: 42,
            margin: const EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 7 : 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(
                alpha: active
                    ? 0.08
                    : on
                    ? 0.05
                    : 0,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Image.asset('assets/icon.png', width: 26, height: 26),
                    AnimatedOpacity(
                      duration: fade,
                      opacity: on ? 1 : 0,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(7)),
                        child: const Icon(Icons.home_rounded, size: 17, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Your Cascade',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(15, w: FontWeight.w600),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (active)
            Positioned(
              left: 0,
              top: 13,
              child: Container(
                width: 3,
                height: 16,
                decoration: BoxDecoration(color: K.accent, borderRadius: BorderRadius.circular(2)),
              ),
            ),
        ],
      ),
    );
    return collapsed ? Tooltip(message: 'Your Cascade', waitDuration: const Duration(milliseconds: 300), child: row) : row;
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow(this.item, {required this.active, required this.collapsed, required this.onGo});
  final NavItem item;
  final bool active, collapsed;
  final ValueChanged<String> onGo;

  @override
  Widget build(BuildContext context) {
    final row = Hover(
      onTap: () => onGo(item.$2),
      builder: (_, on) => Stack(
        children: [
          Container(
            height: 34,
            margin: const EdgeInsets.only(bottom: 2),
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 11 : 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(
                alpha: active
                    ? 0.08
                    : on
                    ? 0.05
                    : 0,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  item.$4,
                  size: 18,
                  color: active
                      ? K.accent
                      : on
                      ? K.text
                      : K.text2,
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.$3,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: ts(13, w: active ? FontWeight.w600 : FontWeight.w500, c: active || on ? K.text : K.text2),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (active)
            Positioned(
              left: 0,
              top: 9,
              child: Container(
                width: 3,
                height: 16,
                decoration: BoxDecoration(color: K.accent, borderRadius: BorderRadius.circular(2)),
              ),
            ),
        ],
      ),
    );
    return collapsed ? Tooltip(message: item.$3, waitDuration: const Duration(milliseconds: 300), child: row) : row;
  }
}

class _MainPanel extends StatelessWidget {
  const _MainPanel({required this.view, required this.entry, required this.onGo});
  final String view;
  final NavEntry entry;
  final ValueChanged<String> onGo;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: DecoratedBox(
      decoration: const BoxDecoration(color: K.panel),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [K.wash.withValues(alpha: 0.16), K.wash.withValues(alpha: 0)],
            stops: const [0, 0.38],
          ),
        ),
        child: switch (view) {
          // Pages (an album, an artist) come in phase 2.
          _ when entry.page != null => _NotYet('${entry.page!.name[0].toUpperCase()}${entry.page!.name.substring(1)}'),
          'home' => _Home(onGo: onGo),
          'radio' => const _Radio(),
          'settings' => const SettingsPanel(),
          _ => _NotYet(_label(view)),
        },
      ),
    ),
  );

  static String _label(String id) => [..._navItems, ..._navBottom].firstWhere((n) => n.$2 == id).$3;
}

class _NotYet extends StatelessWidget {
  const _NotYet(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: ts(28, w: FontWeight.w700)),
        const SizedBox(height: 8),
        Text('Not in the prototype yet. Home is.', style: ts(14, c: K.text3)),
      ],
    ),
  );
}

class _Home extends StatelessWidget {
  const _Home({required this.onGo});
  final ValueChanged<String> onGo;

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    final played = lib.recentlyPlayed;
    final tiles = played.skip(1).take(8).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(greeting(lib.jf?.userName ?? 'Cha0s'), style: ts(30, w: FontWeight.w700, ls: -0.45)),
          const SizedBox(height: 4),
          Text(today(), style: ts(13, c: K.text3)),
          LoadError(padding: const EdgeInsets.only(top: 12)),
          if (lib.loading && played.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (played.isNotEmpty) ...[
            const SizedBox(height: 24),
            _Section(
              'Recently played',
              onMore: () => onGo('history'),
              child: LayoutBuilder(
                builder: (context, c) {
                  final grid = Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 16,
                    children: [
                      for (final half in [tiles.take(4), tiles.skip(4)])
                        Expanded(
                          child: Column(spacing: 8, children: [for (final s in half) SongTile(s, queue: played)]),
                        ),
                    ],
                  );
                  final hero = HeroCard(played.first, played, compact: false, base: K.surface);
                  return c.maxWidth >= 860
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 16,
                          children: [
                            SizedBox(width: c.maxWidth >= 1100 ? 420 : 340, child: hero),
                            Expanded(child: grid),
                          ],
                        )
                      : Column(spacing: 16, children: [hero, grid]);
                },
              ),
            ),
          ],
          if (lib.continueWatching.isNotEmpty) ...[
            const SizedBox(height: 24),
            _Section(
              'Continue watching',
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = (c.maxWidth - 32) / 3;
                  return Row(
                    spacing: 16,
                    children: [for (final v in lib.continueWatching.take(3)) SizedBox(width: w, child: _VideoCard(v))],
                  );
                },
              ),
            ),
          ],
          if (lib.recentlyAdded.isNotEmpty) ...[
            const SizedBox(height: 24),
            _Section(
              'Recently added',
              onMore: () => onGo('albums'),
              child: LayoutBuilder(
                builder: (context, c) {
                  final n = max(3, ((c.maxWidth + 16) / 146).floor());
                  final w = (c.maxWidth - 16 * (n - 1)) / n;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 16,
                    children: [for (final a in lib.recentlyAdded.take(n)) AlbumCard(a, width: w)],
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.child, this.onMore});
  final String title;
  final Widget child;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(title, style: ts(17, w: FontWeight.w600)),
          ),
          if (onMore != null)
            Hover(
              onTap: onMore,
              builder: (_, on) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: on ? 0.12 : 0.06),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  'See all',
                  style: ts(12, w: FontWeight.w500, c: on ? K.text : K.text2),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      child,
    ],
  );
}

class _VideoCard extends StatelessWidget {
  const _VideoCard(this.video);
  final Video video;

  @override
  Widget build(BuildContext context) => Hover(
    onTap: () {},
    builder: (_, on) => Row(
      children: [
        AnimatedScale(scale: on ? 1.03 : 1, duration: const Duration(milliseconds: 150), child: VideoThumb(video, width: 160)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                video.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(14, w: FontWeight.w600),
              ),
              const SizedBox(height: 3),
              Text(
                video.episode,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(12, c: K.text2),
              ),
              const SizedBox(height: 3),
              Text(
                video.left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(12, c: K.text3),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _PlayerBar extends StatelessWidget {
  const _PlayerBar();

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final song = p.song;
    final length = p.length;
    return SizedBox(
      height: 76,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
        child: Row(
          children: [
            SizedBox(
              width: 300,
              child: Row(
                children: [
                  Cover(song?.art ?? const [K.surface2, K.surface], image: song?.image, size: 52, radius: 8, shadow: song != null),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song?.title ?? 'Nothing playing',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(13, w: FontWeight.w600, c: song == null ? K.text3 : K.text),
                        ),
                        if (p.error != null)
                          Text(
                            p.error!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts(12, c: const Color(0xFFFF453A)),
                          )
                        else if (song != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${song.artist} · ${song.album}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts(12, c: K.text3),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (song != null)
                    _IconBtn(
                      p.isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      'Like',
                      p.toggleLike,
                      color: p.isLiked ? const Color(0xFFFF6B8A) : K.text3,
                      size: 17,
                    ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 14,
                    children: [
                      _IconBtn(Icons.shuffle_rounded, 'Shuffle', p.toggleShuffle, color: p.shuffle ? K.accent : K.text2),
                      _IconBtn(Icons.skip_previous_rounded, 'Previous', p.prev, color: K.text, size: 22),
                      PlayCircle(playing: p.playing, onTap: p.toggle),
                      _IconBtn(Icons.skip_next_rounded, 'Next', p.next, color: K.text, size: 22),
                      _IconBtn(
                        p.repeat == Repeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                        'Repeat',
                        p.toggleRepeat,
                        color: p.repeat == Repeat.off ? K.text2 : K.accent,
                      ),
                    ],
                  ),
                  LayoutBuilder(
                    builder: (context, c) {
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 36,
                            child: Text(
                              fmt(p.position),
                              textAlign: TextAlign.right,
                              style: ts(11, w: FontWeight.w500, c: K.text3),
                            ),
                          ),
                          SizedBox(
                            width: min(520, c.maxWidth - 92),
                            child: _Bar(value: length > 0 ? p.position / length : 0, onChanged: (v) => p.seek(v * length)),
                          ),
                          SizedBox(
                            width: 36,
                            child: Text(
                              fmt(length),
                              style: ts(11, w: FontWeight.w500, c: K.text3),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 300,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _IconBtn(Icons.lyrics_outlined, 'Lyrics', () {}),
                  _IconBtn(Icons.water_drop_outlined, 'Waterfall, listen together', () {}),
                  _IconBtn(Icons.picture_in_picture_alt_outlined, 'Miniplayer', () {}),
                  _IconBtn(Icons.cast_rounded, 'Connect to a device', () {}),
                  const SleepTimerButton(),
                  Container(width: 1, height: 18, margin: const EdgeInsets.symmetric(horizontal: 8), color: K.surface2),
                  _IconBtn(p.volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, 'Mute', () => p.setVolume(p.volume == 0 ? 0.7 : 0)),
                  SizedBox(
                    width: 96,
                    child: _Bar(value: p.volume, onChanged: p.setVolume, color: K.text2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The thin seek and volume bars.
class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.onChanged, this.color = K.accent});
  final double value;
  final ValueChanged<double> onChanged;
  final Color color;

  @override
  Widget build(BuildContext context) => SliderTheme(
    data: SliderThemeData(
      trackHeight: 4,
      trackShape: const RoundedRectSliderTrackShape(),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      activeTrackColor: color,
      inactiveTrackColor: Colors.white.withValues(alpha: 0.14),
      thumbColor: Colors.white,
      overlayColor: color.withValues(alpha: 0.2),
    ),
    child: SizedBox(
      height: 20,
      child: Slider(value: value.clamp(0, 1), onChanged: onChanged, padding: const EdgeInsets.symmetric(horizontal: 6)),
    ),
  );
}

/// Radio: the server's Live TV channels, played as audio.
class _Radio extends StatefulWidget {
  const _Radio();

  @override
  State<_Radio> createState() => _RadioState();
}

class _RadioState extends State<_Radio> {
  late final Future<List<Song>> _channels = LibraryScope.read(context).radioChannels();

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _channels,
    builder: (context, snap) {
      final channels = snap.data ?? const <Song>[];
      return ListView(
        padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
        children: [
          Text('Radio', style: ts(30, w: FontWeight.w700, ls: -0.45)),
          const SizedBox(height: 20),
          if (snap.hasError) Text('Could not load the channels: ${snap.error}', style: ts(13, c: const Color(0xFFFF453A))),
          if (snap.connectionState != ConnectionState.done) const Center(child: CircularProgressIndicator()),
          if (snap.connectionState == ConnectionState.done && channels.isEmpty && !snap.hasError)
            Text('No channels on your server.', style: ts(14, c: K.text3)),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final c in channels)
                Hover(
                  onTap: () => PlayerScope.read(context).play(c, channels),
                  builder: (_, on) => SizedBox(
                    width: 140,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Cover(c.art, image: c.image, size: 140, shadow: on),
                        const SizedBox(height: 8),
                        Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(13, w: FontWeight.w500),
                        ),
                        Text(
                          c.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(12, c: K.text3),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );
}
