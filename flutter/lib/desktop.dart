// Windows and Linux layout: top bar, sidebar, Home, player bar.
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';
import 'player.dart';
import 'widgets.dart';

typedef NavItem = (String? section, String id, String label, IconData icon);

const _nav = <NavItem>[
  (null, 'home', 'Home', Icons.home_outlined),
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
const _navBottom = <NavItem>[
  (null, 'downloads', 'Downloads', Icons.download_outlined),
  (null, 'settings', 'Settings', Icons.settings_outlined),
];

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  String _view = 'home';
  final _back = <String>[], _fwd = <String>[];
  bool _collapsed = false;
  final _search = FocusNode();

  void _go(String v) {
    if (v == _view) return;
    setState(() {
      _back.add(_view);
      _fwd.clear();
      _view = v;
    });
  }

  void _step(List<String> from, List<String> to) => setState(() {
        to.add(_view);
        _view = from.removeLast();
      });

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search.requestFocus,
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _search.requestFocus,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: K.root,
            body: Column(children: [
              _topBar(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    _Sidebar(view: _view, collapsed: _collapsed, onGo: _go),
                    const SizedBox(width: 8),
                    Expanded(child: _MainPanel(view: _view, onGo: _go)),
                  ]),
                ),
              ),
              const _PlayerBar(),
            ]),
          ),
        ),
      );

  Widget _topBar() => SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            SizedBox(
              width: 260,
              child: Row(children: [
                _IconBtn(Icons.view_sidebar_outlined, _collapsed ? 'Show sidebar' : 'Hide sidebar', () => setState(() => _collapsed = !_collapsed)),
                const SizedBox(width: 4),
                _IconBtn(Icons.chevron_left_rounded, 'Back', _back.isEmpty ? null : () => _step(_back, _fwd), filled: true),
                const SizedBox(width: 4),
                _IconBtn(Icons.chevron_right_rounded, 'Forward', _fwd.isEmpty ? null : () => _step(_fwd, _back), filled: true),
              ]),
            ),
            Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: _SearchField(_search)))),
            SizedBox(
              width: 260,
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                _IconBtn(Icons.notifications_none_rounded, 'Announcements', () {}, badge: true),
                const SizedBox(width: 4),
                _IconBtn(Icons.brush_outlined, 'Theme', () {}),
              ]),
            ),
          ]),
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
            color: Colors.white.withValues(alpha: on && onTap != null ? 0.1 : filled ? 0.06 : 0),
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
              child: Text(mac ? '⌘K' : 'Ctrl K', style: ts(11, w: FontWeight.w500, c: K.text3)),
            ),
          ),
          suffixIconConstraints: const BoxConstraints(minHeight: 32),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: K.surface2)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: K.accent)),
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
  Widget build(BuildContext context) => AnimatedContainer(
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: EdgeInsets.only(left: collapsed ? 7 : 8, bottom: 12),
                child: Row(children: [
                  Image.asset('assets/icon.png', width: 26, height: 26),
                  if (!collapsed) ...[const SizedBox(width: 10), Text('Cascade', style: ts(15, w: FontWeight.w600))],
                ]),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final item in _nav) ...[
                      if (item.$1 != null)
                        collapsed
                            ? const Padding(padding: EdgeInsets.symmetric(vertical: 10, horizontal: 8), child: Divider(height: 1, color: K.surface2))
                            : Padding(
                                padding: const EdgeInsets.fromLTRB(10, 14, 0, 6),
                                child: Text(item.$1!.toUpperCase(), style: ts(11, w: FontWeight.w600, c: K.text3, ls: 0.6)),
                              ),
                      _NavRow(item, active: view == item.$2, collapsed: collapsed, onGo: onGo),
                    ],
                  ]),
                ),
              ),
              for (final item in _navBottom) _NavRow(item, active: view == item.$2, collapsed: collapsed, onGo: onGo),
            ]),
          ),
        ),
      );
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
      builder: (_, on) => Stack(children: [
        Container(
          height: 34,
          margin: const EdgeInsets.only(bottom: 2),
          padding: EdgeInsets.symmetric(horizontal: collapsed ? 11 : 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: active ? 0.08 : on ? 0.05 : 0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(item.$4, size: 18, color: active ? K.accent : on ? K.text : K.text2),
            if (!collapsed) ...[
              const SizedBox(width: 12),
              Expanded(child: Text(item.$3, maxLines: 1, overflow: TextOverflow.clip, style: ts(13, w: active ? FontWeight.w600 : FontWeight.w500, c: active || on ? K.text : K.text2))),
            ],
          ]),
        ),
        if (active)
          Positioned(
            left: 0,
            top: 9,
            child: Container(width: 3, height: 16, decoration: BoxDecoration(color: K.accent, borderRadius: BorderRadius.circular(2))),
          ),
      ]),
    );
    return collapsed ? Tooltip(message: item.$3, waitDuration: const Duration(milliseconds: 300), child: row) : row;
  }
}

class _MainPanel extends StatelessWidget {
  const _MainPanel({required this.view, required this.onGo});
  final String view;
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
            child: view == 'home' ? _Home(onGo: onGo) : _NotYet(_label(view)),
          ),
        ),
      );

  static String _label(String id) => [..._nav, ..._navBottom].firstWhere((n) => n.$2 == id).$3;
}

class _NotYet extends StatelessWidget {
  const _NotYet(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: ts(28, w: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Not in the prototype yet. Home is.', style: ts(14, c: K.text3)),
        ]),
      );
}

class _Home extends StatelessWidget {
  const _Home({required this.onGo});
  final ValueChanged<String> onGo;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(greeting('Cha0s'), style: ts(30, w: FontWeight.w700, ls: -0.45)),
          const SizedBox(height: 4),
          Text(today(), style: ts(13, c: K.text3)),
          const SizedBox(height: 24),
          _Section('Recently played', onMore: () => onGo('history'), child: LayoutBuilder(builder: (context, c) {
            final grid = Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 16, children: [
              for (final half in [recentlyPlayed.sublist(0, 4), recentlyPlayed.sublist(4)])
                Expanded(child: Column(spacing: 8, children: [for (final s in half) SongTile(s)])),
            ]);
            const hero = HeroCard(compact: false, base: K.surface);
            return c.maxWidth >= 860
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 16, children: [SizedBox(width: c.maxWidth >= 1100 ? 420 : 340, child: hero), Expanded(child: grid)])
                : Column(spacing: 16, children: [hero, grid]);
          })),
          const SizedBox(height: 24),
          _Section('Continue watching', child: LayoutBuilder(builder: (context, c) {
            final w = (c.maxWidth - 32) / 3;
            return Row(spacing: 16, children: [for (final v in continueWatching) SizedBox(width: w, child: _VideoCard(v))]);
          })),
          const SizedBox(height: 24),
          _Section('Recently added', onMore: () => onGo('albums'), child: LayoutBuilder(builder: (context, c) {
            final n = ((c.maxWidth + 16) / 146).floor().clamp(3, recentlyAdded.length);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 16, children: [for (final a in recentlyAdded.take(n)) Expanded(child: AlbumCard(a))]);
          })),
        ]),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.child, this.onMore});
  final String title;
  final Widget child;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: ts(17, w: FontWeight.w600))),
          if (onMore != null)
            Hover(
              onTap: onMore,
              builder: (_, on) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: on ? 0.12 : 0.06), borderRadius: BorderRadius.circular(99)),
                child: Text('See all', style: ts(12, w: FontWeight.w500, c: on ? K.text : K.text2)),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        child,
      ]);
}

class _VideoCard extends StatelessWidget {
  const _VideoCard(this.video);
  final Video video;

  @override
  Widget build(BuildContext context) => Hover(
        onTap: () {},
        builder: (_, on) => Row(children: [
          AnimatedScale(scale: on ? 1.03 : 1, duration: const Duration(milliseconds: 150), child: VideoThumb(video, width: 160)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(video.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(14, w: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(video.episode, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(12, c: K.text2)),
              const SizedBox(height: 3),
              Text(video.left, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(12, c: K.text3)),
            ]),
          ),
        ]),
      );
}

class _PlayerBar extends StatelessWidget {
  const _PlayerBar();

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    return SizedBox(
      height: 76,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
        child: Row(children: [
          SizedBox(
            width: 300,
            child: Row(children: [
              Cover(p.song.art, size: 52, radius: 8, shadow: true),
              const SizedBox(width: 12),
              Flexible(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(13, w: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('${p.song.artist} · ${p.song.album}', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(12, c: K.text3)),
                ]),
              ),
              const SizedBox(width: 6),
              _IconBtn(p.isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded, 'Like', p.toggleLike, color: p.isLiked ? const Color(0xFFFF6B8A) : K.text3, size: 17),
            ]),
          ),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, spacing: 14, children: [
                _IconBtn(Icons.shuffle_rounded, 'Shuffle', p.toggleShuffle, color: p.shuffle ? K.accent : K.text2),
                _IconBtn(Icons.skip_previous_rounded, 'Previous', p.prev, color: K.text, size: 22),
                PlayCircle(playing: p.playing, onTap: p.toggle),
                _IconBtn(Icons.skip_next_rounded, 'Next', p.next, color: K.text, size: 22),
                _IconBtn(Icons.repeat_rounded, 'Repeat', p.toggleRepeat, color: p.repeat ? K.accent : K.text2),
              ]),
              LayoutBuilder(builder: (context, c) {
                return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  SizedBox(width: 36, child: Text(fmt(p.position), textAlign: TextAlign.right, style: ts(11, w: FontWeight.w500, c: K.text3))),
                  SizedBox(width: min(520, c.maxWidth - 92), child: _Bar(value: p.position / p.song.seconds, onChanged: (v) => p.seek(v * p.song.seconds))),
                  SizedBox(width: 36, child: Text(fmt(p.song.seconds), style: ts(11, w: FontWeight.w500, c: K.text3))),
                ]);
              }),
            ]),
          ),
          SizedBox(
            width: 300,
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              _IconBtn(Icons.lyrics_outlined, 'Lyrics', () {}),
              _IconBtn(Icons.water_drop_outlined, 'Waterfall, listen together', () {}),
              _IconBtn(Icons.picture_in_picture_alt_outlined, 'Miniplayer', () {}),
              _IconBtn(Icons.cast_rounded, 'Connect to a device', () {}),
              Container(width: 1, height: 18, margin: const EdgeInsets.symmetric(horizontal: 8), color: K.surface2),
              _IconBtn(p.volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, 'Mute', () => p.setVolume(p.volume == 0 ? 0.7 : 0)),
              SizedBox(width: 96, child: _Bar(value: p.volume, onChanged: p.setVolume, color: K.text2)),
            ]),
          ),
        ]),
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
        child: SizedBox(height: 20, child: Slider(value: value.clamp(0, 1), onChanged: onChanged, padding: const EdgeInsets.symmetric(horizontal: 6))),
      );
}
