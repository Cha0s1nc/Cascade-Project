// Windows and Linux layout: the in-line title bar, the sidebar, the page and
// the player bar. The pages themselves are in ui/pages/.
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cascade/core/library.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/now_playing.dart';
import 'package:cascade/ui/pages/pages.dart';
import 'package:cascade/ui/panels.dart';
import 'package:cascade/ui/settings_panel.dart';
import 'package:cascade/ui/title_bar.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:cascade/ui/controls.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/style_menu.dart';

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
  (null, 'rediscover', 'Rediscover', Icons.auto_awesome_outlined),
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
    // A server with only movies and shows: no music side at all.
    _ => lib.demo || lib.loading || lib.musicLibs.isNotEmpty,
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
  final _np = NowPlaying();
  final _search = FocusNode();
  final _query = TextEditingController();

  /// The rail is slid out under the mouse (the 'hover' sidebar).
  bool _railOut = false;

  /// The title bar's right-hand buttons, measured so tucked search sits
  /// right beside them.
  final _rightButtons = GlobalKey();
  double _rightWidth = 0;

  @override
  void initState() {
    super.initState();
    // Search opens and closes with focus and text.
    _search.addListener(_searchChanged);
    _query.addListener(_searchChanged);
  }

  bool _searchOpen = false;
  void _searchChanged() {
    final open = _search.hasFocus || _query.text.isNotEmpty;
    if (open != _searchOpen) setState(() => _searchOpen = open);
  }

  /// Expanded, then a rail that slides out, then a plain rail.
  void _cycleSidebar() {
    final s = PlayerScope.read(context).settings;
    s.setSidebarMode(switch (s.sidebarMode) {
      'expanded' => 'hover',
      'hover' => 'rail',
      _ => 'expanded',
    });
    setState(() => _railOut = false);
  }

  @override
  void dispose() {
    _nav.dispose();
    _np.dispose();
    _search.dispose();
    _query.dispose();
    super.dispose();
  }

  // Back and Forward: the title bar buttons, the mouse's side buttons, and
  // Alt+Left/Right, as on the desktop. Now Playing, when open, closes first.
  void _back() {
    if (_np.open) return _np.close();
    _nav.back();
  }

  void _go(String view) {
    _np.close();
    _nav.show(view);
  }

  @override
  Widget build(BuildContext context) => NavScope(
    nav: _nav,
    child: NowPlayingScope(
      np: _np,
      child: SearchScope(
        query: _query,
        child: ListenableBuilder(listenable: Listenable.merge([_nav, _np, PlayerScope.read(context).settings]), builder: (context, _) => _shell(context)),
      ),
    ),
  );

  Widget _shell(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search.requestFocus,
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): _search.requestFocus,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _back,
      const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): _nav.forward,
      const SingleActivator(LogicalKeyboardKey.escape): _np.close,
      ...playbackShortcuts(PlayerScope.read(context)),
    },
    child: Listener(
      onPointerDown: (e) {
        if (e.buttons & kBackMouseButton != 0) _back();
        if (e.buttons & kForwardMouseButton != 0) _nav.forward();
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: K.root,
          body: Column(
            children: [
              _topBar(context),
              Expanded(
                child: NowPlayingLayer(
                  body: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _body(context)),
                ),
              ),
              const PlayerBar(),
            ],
          ),
        ),
      ),
    ),
  );

  /// The sidebar and the page. A 'hover' sidebar keeps a rail's room and
  /// slides out over the page, which dims under it, as the desktop's does.
  Widget _body(BuildContext context) {
    final mode = PlayerScope.read(context).settings.sidebarMode;
    final out = mode == 'expanded' || (mode == 'hover' && _railOut);
    const ease = Cubic(.4, 0, .2, 1), time = Duration(milliseconds: 180);
    return Stack(
      children: [
        Row(
          // Stretched, so a short page still fills the panel.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedContainer(duration: time, curve: ease, width: mode == 'expanded' ? _Sidebar.wide : _Sidebar.rail),
            const SizedBox(width: 8),
            Expanded(
              child: _MainPanel(
                view: _nav.view,
                entry: _nav.top,
                // Where the page sits, for which way it slides in: the
                // sidebar's order, then how deep into that section.
                rank: (
                  _nav.view == 'home'
                      ? -1
                      : [
                          for (final (_, i) in _visibleNav(LibraryScope.read(context), PlayerScope.read(context).settings)) i.$2,
                          for (final i in _navBottom) i.$2,
                        ].indexOf(_nav.view),
                  _nav.stack(_nav.view).length,
                ),
              ),
            ),
          ],
        ),
        if (mode == 'hover')
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: time,
                opacity: _railOut ? 1 : 0,
                child: const ColoredBox(color: Color(0x85000000)),
              ),
            ),
          ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: MouseRegion(
            onEnter: mode == 'hover' ? (_) => setState(() => _railOut = true) : null,
            onExit: mode == 'hover' ? (_) => setState(() => _railOut = false) : null,
            child: _Sidebar(view: _nav.view, collapsed: !out, overlay: mode == 'hover' && _railOut, onGo: _go),
          ),
        ),
      ],
    );
  }

  /// Both side groups are the same width, so search stays centered on the
  /// window whatever the window buttons take. With Now Playing in a full
  /// window layout, the bar keeps only its close button and the window's.
  Widget _topBar(BuildContext context) {
    final side = max(260.0, windowButtonsWidth + 182);
    final full = _np.open && PlayerScope.read(context).settings.nowPlayingLayout != 'bar';
    return SizedBox(
      height: 48,
      child: LayoutBuilder(
        builder: (context, c) => Stack(
          children: [
            const Positioned.fill(child: TitleBarDrag(child: SizedBox.expand())),
            Row(
              children: [
                SizedBox(
                  width: side,
                  child: full
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: Row(
                            spacing: 4,
                            children: [
                              IconBtn(Icons.view_sidebar_outlined, switch (PlayerScope.read(context).settings.sidebarMode) {
                                'expanded' => 'Sidebar: slide out on hover',
                                'hover' => 'Sidebar: icons only',
                                _ => 'Sidebar: expanded',
                              }, _cycleSidebar),
                              IconBtn(Icons.chevron_left_rounded, 'Back', _nav.canBack || _np.open ? _back : null),
                              IconBtn(Icons.chevron_right_rounded, 'Forward', _nav.canForward ? _nav.forward : null),
                            ],
                          ),
                        ),
                ),
                Expanded(
                  child: Center(
                    child: full
                        ? Hover(
                            onTap: _np.close,
                            builder: (_, on) => Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  PlayerScope.read(context).source == null ? 'Now Playing' : 'Playing from ${PlayerScope.read(context).source}',
                                  style: ts(13, w: FontWeight.w500, c: on ? K.text : K.text2),
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: on ? K.text : K.text2),
                              ],
                            ),
                          )
                        : null,
                  ),
                ),
                SizedBox(
                  width: side,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      key: _rightButtons,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!full && LibraryScope.of(context).offline)
                          Tooltip(
                            message: 'Offline Mode: only your downloads',
                            child: Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: K.accentTint, borderRadius: BorderRadius.circular(99)),
                              child: Text(
                                'Offline',
                                style: ts(12, w: FontWeight.w600, c: K.accent),
                              ),
                            ),
                          ),
                        if (!full) ...[
                          const AnnouncementsButton(),
                          const SizedBox(width: 4),
                          IconBtn(Icons.brush_outlined, 'Style', () => openStyleMenu(context)),
                        ],
                        SizedBox(width: inlineTitleBar ? 8 : 12),
                        const WindowButtons(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (!full) _searchBox(c.maxWidth, side),
          ],
        ),
      ),
    );
  }

  /// Search as the desktop's: centered on Home when there is room, otherwise
  /// tucked into a small Search pill beside the right-hand buttons that
  /// widens while in use. It slides between the two.
  Widget _searchBox(double width, double side) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final w = (_rightButtons.currentContext?.findRenderObject() as RenderBox?)?.size.width;
      if (w != null && mounted && (w - _rightWidth).abs() > 0.5) setState(() => _rightWidth = w);
    });
    final centeredW = min(340.0, width * 0.36);
    final centered = _nav.view == 'home' && !_np.open && width - 2 * side >= centeredW;
    final open = _searchOpen || _nav.view == 'search';
    final w = centered
        ? centeredW
        : open
        ? min(300.0, width * 0.4)
        : 86.0;
    final left = centered ? (width - w) / 2 : width - _rightWidth - w - 8;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 280),
      curve: const Cubic(.4, 0, .2, 1),
      left: left,
      width: w,
      top: 10,
      height: 28,
      child: SearchField(focus: _search, wide: centered || open, onSearch: () => _go('search')),
    );
  }
}

/// The title bar's search field. Typing opens the Search page.
class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.focus, required this.onSearch, this.wide = true});
  final FocusNode focus;
  final VoidCallback onSearch;

  /// Room for the full hint and the shortcut; tucked, it reads Search.
  final bool wide;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 28,
    child: TextField(
      focusNode: focus,
      controller: SearchScope.of(context),
      onChanged: (_) => onSearch(),
      onSubmitted: (_) => onSearch(),
      style: ts(13),
      cursorColor: K.accent,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: K.surface2,
        contentPadding: const EdgeInsets.symmetric(vertical: 6),
        prefixIcon: const Icon(Icons.search_rounded, size: 15, color: K.text3),
        prefixIconConstraints: const BoxConstraints(minWidth: 30),
        hintText: wide ? 'Search your library' : 'Search',
        hintMaxLines: 1,
        hintStyle: ts(12.5, c: K.text3),
        suffixIcon: !wide
            ? null
            : Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    'Ctrl K',
                    style: ts(11, w: FontWeight.w500, c: K.text3),
                  ),
                ),
              ),
        suffixIconConstraints: const BoxConstraints(minHeight: 28),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: K.accent),
        ),
      ),
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.view, required this.collapsed, required this.onGo, this.overlay = false});
  final String view;
  final bool collapsed;
  final ValueChanged<String> onGo;

  /// Slid out over the page: it casts a shadow.
  final bool overlay;

  static const wide = 232.0, rail = 60.0;

  @override
  // Rebuilt when the settings change too: Radio follows its switch.
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PlayerScope.read(context).settings,
    builder: (context, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: const Cubic(.4, 0, .2, 1),
      width: collapsed ? rail : wide,
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      decoration: BoxDecoration(
        color: K.panel,
        borderRadius: BorderRadius.circular(14),
        boxShadow: overlay ? const [BoxShadow(color: Color(0x66000000), blurRadius: 20, offset: Offset(0, 4))] : null,
      ),
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
                                  child: Divider(height: 1, color: K.line),
                                )
                              : Padding(
                                  padding: const EdgeInsets.fromLTRB(10, 14, 0, 8),
                                  child: Text(header.toUpperCase(), style: Txt.caps()),
                                ),
                        _NavRow(item, active: view == item.$2, collapsed: collapsed, onGo: onGo, badge: item.$2 == 'rediscover' ? 'New' : null),
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
    final row = Hover(
      onTap: () => onGo('home'),
      builder: (_, on) => Container(
        height: 42,
        margin: const EdgeInsets.only(bottom: 6),
        padding: EdgeInsets.symmetric(horizontal: collapsed ? 7 : 8),
        decoration: BoxDecoration(
          color: active
              ? K.accentTint
              : on
              ? K.line
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Image.asset('assets/icon.png', width: 26, height: 26),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
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
                child: Text('Your Cascade', maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.brand()),
              ),
            ],
          ],
        ),
      ),
    );
    return collapsed ? Tooltip(message: 'Your Cascade', waitDuration: const Duration(milliseconds: 300), child: row) : row;
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow(this.item, {required this.active, required this.collapsed, required this.onGo, this.badge});
  final NavItem item;
  final bool active, collapsed;
  final ValueChanged<String> onGo;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final row = Hover(
      onTap: () => onGo(item.$2),
      builder: (_, on) => Container(
        height: 34,
        margin: const EdgeInsets.only(bottom: 2),
        padding: EdgeInsets.symmetric(horizontal: collapsed ? 11 : 10),
        decoration: BoxDecoration(
          color: active
              ? K.accentTint
              : on
              ? K.line
              : Colors.transparent,
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
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: K.accentTint, borderRadius: BorderRadius.circular(6)),
                  child: Text(
                    badge!,
                    style: ts(11, w: FontWeight.w500, c: K.accent),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
    return collapsed ? Tooltip(message: item.$3, waitDuration: const Duration(milliseconds: 300), child: row) : row;
  }
}

class _MainPanel extends StatefulWidget {
  const _MainPanel({required this.view, required this.entry, required this.rank});
  final String view;
  final NavEntry entry;
  final (int, int) rank;

  @override
  State<_MainPanel> createState() => _MainPanelState();
}

/// Pages slide as they change: up when going further down the sidebar or
/// deeper into a section, down when going back up, as Settings' tabs slide
/// sideways.
class _MainPanelState extends State<_MainPanel> {
  double _dir = 1;

  @override
  void didUpdateWidget(_MainPanel old) {
    super.didUpdateWidget(old);
    if (old.entry == widget.entry) return;
    final (a, b) = (old.rank, widget.rank);
    _dir = b.$1 > a.$1 || (b.$1 == a.$1 && b.$2 >= a.$2) ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    final key = ObjectKey(widget.entry);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: K.root,
          border: Border.all(color: K.line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(gradient: K.wash),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            reverseDuration: const Duration(milliseconds: 160),
            switchInCurve: settingsCurve,
            layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
            transitionBuilder: (c, a) => c.key != key
                ? FadeTransition(opacity: a, child: c)
                : FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                      position: Tween(begin: Offset(0, 0.035 * _dir), end: Offset.zero).animate(a),
                      child: c,
                    ),
                  ),
            child: KeyedSubtree(key: key, child: widget.entry.page != null ? pageFor(widget.entry) : viewFor(widget.view)),
          ),
        ),
      ),
    );
  }
}

/// The player bar: the song, the transport and seek bar, and the extras.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final np = NowPlayingScope.of(context);
    final song = p.song;
    // The full window layouts take the controls into Now Playing.
    if (np.open && p.settings.nowPlayingLayout != 'bar') return const SizedBox.shrink();
    return Container(
      height: 76,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: K.line)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
      child: BareIcons(
        child: Row(
          children: [
            SizedBox(
              width: 300,
              child: Row(
                children: [
                  Expanded(
                    child: Hover(
                      onTap: song == null ? null : np.toggle,
                      builder: (_, on) => Row(
                        children: [
                          Cover(song?.art ?? const [K.surface2, K.surface], image: song?.image, size: 48, radius: 8, shadow: song != null),
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
                                  style: ts(13, w: FontWeight.w600, c: song == null ? K.text3 : (on ? K.accent : K.text)),
                                ),
                                if (p.error != null)
                                  Text(
                                    p.error!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ts(12, c: K.error),
                                  )
                                else if (song != null) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    '${song.artist} · ${song.album}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ts(12, c: K.text2),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (song != null) LikeButton(p: p),
                ],
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Transport(p: p),
                  SeekBar(p: p, maxWidth: 520),
                ],
              ),
            ),
            SizedBox(
              width: 340,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconBtn(
                    Icons.lyrics_outlined,
                    'Lyrics',
                    song == null ? null : () => np.show(NpPanel.lyrics),
                    color: np.open && np.panel == NpPanel.lyrics ? K.accent : K.text2,
                  ),
                  IconBtn(
                    Icons.queue_music_rounded,
                    'Queue',
                    song == null ? null : () => np.show(NpPanel.queue),
                    color: np.open && np.panel == NpPanel.queue ? K.accent : K.text2,
                  ),
                  const WaterfallButton(),
                  const MiniplayerButton(),
                  const DevicesButton(),
                  const SleepTimerButton(),
                  Container(width: 1, height: 18, margin: const EdgeInsets.symmetric(horizontal: 8), color: K.line),
                  VolumeControl(p: p),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LikeButton extends StatelessWidget {
  const LikeButton({super.key, required this.p, this.size = 17});
  final Player p;
  final double size;

  @override
  Widget build(BuildContext context) => IconBtn(
    p.isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
    p.isLiked ? 'Unlike' : 'Like',
    p.toggleLike,
    color: p.isLiked ? K.like : K.text2,
    size: size,
  );
}

/// Shuffle, previous, play, next, repeat.
class Transport extends StatelessWidget {
  const Transport({super.key, required this.p, this.big = false});
  final Player p;
  final bool big;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    spacing: big ? 22 : 14,
    children: [
      IconBtn(Icons.shuffle_rounded, 'Shuffle', p.toggleShuffle, color: p.shuffle ? K.accent : K.text2, size: big ? 22 : 16),
      IconBtn(Icons.skip_previous_rounded, 'Previous', p.prev, color: K.text, size: big ? 30 : 20),
      PlayCircle(playing: p.playing, onTap: p.toggle, size: big ? 60 : 32),
      IconBtn(Icons.skip_next_rounded, 'Next', p.next, color: K.text, size: big ? 30 : 20),
      IconBtn(
        p.repeat == Repeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
        'Repeat',
        p.toggleRepeat,
        color: p.repeat == Repeat.off ? K.text2 : K.accent,
        size: big ? 22 : 16,
      ),
    ],
  );
}

/// Elapsed, the seek bar, the length.
class SeekBar extends StatelessWidget {
  const SeekBar({super.key, required this.p, this.maxWidth = double.infinity});
  final Player p;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final length = p.length;
    return LayoutBuilder(
      builder: (context, c) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 40,
            child: Text(
              fmt(p.position),
              textAlign: TextAlign.right,
              style: ts(11, w: FontWeight.w500, c: K.text3),
            ),
          ),
          SizedBox(
            width: max(40, min(maxWidth, c.maxWidth - 92)),
            child: ThinBar(value: length > 0 ? p.position / length : 0, onChanged: length > 0 ? (v) => p.seek(v * length) : null),
          ),
          SizedBox(
            width: 40,
            child: Text(
              fmt(length),
              style: ts(11, w: FontWeight.w500, c: K.text3),
            ),
          ),
        ],
      ),
    );
  }
}

class VolumeControl extends StatelessWidget {
  const VolumeControl({super.key, required this.p});
  final Player p;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconBtn(
        p.volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
        p.volume == 0 ? 'Unmute' : 'Mute',
        () => p.setVolume(p.volume == 0 ? 0.7 : 0),
      ),
      SizedBox(
        width: 96,
        child: ThinBar(value: p.volume, onChanged: p.setVolume, color: K.text2),
      ),
    ],
  );
}

/// Space plays and pauses, Ctrl+Left/Right skip, Ctrl+Up/Down change the
/// volume, as on the desktop. Space is left to text fields.
Map<ShortcutActivator, VoidCallback> playbackShortcuts(Player p) => {
  const SingleActivator(LogicalKeyboardKey.space): p.toggle,
  const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): p.next,
  const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): p.prev,
  const SingleActivator(LogicalKeyboardKey.arrowUp, control: true): () => p.setVolume(min(1, p.volume + 0.05)),
  const SingleActivator(LogicalKeyboardKey.arrowDown, control: true): () => p.setVolume(max(0, p.volume - 0.05)),
};
