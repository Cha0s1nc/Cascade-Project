// Now Playing on desktop: a layer over the window body that slides up from
// the player bar, with the art stack on the left and Lyrics or Queue on the
// right. The layout setting picks how much of the window it takes:
// 'bar' keeps the title bar and player bar, 'under' takes the whole window
// and moves the controls under the art, 'focus' gives the lyrics the window
// and hides the controls until the mouse moves.
import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/lyrics.dart';
import 'package:cascade/core/lyrics_fetch.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/core/playback.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/lyrics_editor.dart';
import 'package:cascade/ui/lyrics_view.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/controls.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/style_menu.dart';
import 'package:cascade/ui/widgets.dart';

enum NpPanel { lyrics, queue }

/// Whether Now Playing is open, and which panel it shows.
class NowPlaying extends ChangeNotifier {
  bool open = false;

  /// On screen: open, or still sliding down after closing. What it covers
  /// (the player bar's cover and title) waits for this to clear.
  bool get showing => open || _leaving;
  bool _leaving = false;

  /// The layer has slid all the way down.
  void settled() {
    if (!_leaving) return;
    _leaving = false;
    notifyListeners();
  }

  NpPanel panel = NpPanel.lyrics;

  /// The Style menu's tab while it is open beside the lyrics.
  String? editing;

  void editStyle(String tab) {
    editing = tab;
    open = true;
    notifyListeners();
  }

  void stopEditing() {
    editing = null;
    notifyListeners();
  }

  void toggle() => open ? close() : show(panel);

  /// Open on [p]; asking for the panel already showing closes it.
  void show(NpPanel p) {
    if (open && panel == p) return close();
    panel = p;
    open = true;
    notifyListeners();
  }

  void setPanel(NpPanel p) {
    panel = p;
    notifyListeners();
  }

  void close() {
    if (!open) return;
    open = false;
    _leaving = true;
    // In case no animation reports its end (nothing was showing): never
    // leave the bar waiting.
    Timer(const Duration(milliseconds: 900), settled);
    editing = null;
    notifyListeners();
  }
}

/// The window body with Now Playing over it. It slides up from the player
/// bar and back down, staying built until it is out of sight.
class NowPlayingLayer extends StatefulWidget {
  const NowPlayingLayer({super.key, required this.body});
  final Widget body;

  @override
  State<NowPlayingLayer> createState() => _NowPlayingLayerState();
}

class _NowPlayingLayerState extends State<NowPlayingLayer> {
  bool _built = false;

  @override
  Widget build(BuildContext context) {
    final np = NowPlayingScope.of(context);
    if (np.open) _built = true;
    return Stack(
      children: [
        Positioned.fill(child: widget.body),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !np.open,
            child: AnimatedSlide(
              // Reduce motion: it fades in place.
              offset: np.open || calm(context) ? Offset.zero : const Offset(0, 1),
              // The desktop's slide: 0.38 s on an ease in and out, both ways.
              // An ease-out put most of the rise in its first frames, which
              // also build the whole view, so it read as a fade, not a slide.
              duration: const Duration(milliseconds: 380),
              curve: const Cubic(.4, 0, .2, 1),
              onEnd: () {
                if (!np.open && _built) setState(() => _built = false);
                if (!np.open) np.settled();
              },
              // Only Reduce motion fades: otherwise it stays solid and slides.
              child: AnimatedOpacity(
                opacity: np.open || !calm(context) ? 1 : 0,
                // Reduce motion fades instead of sliding: this is what ends.
                onEnd: () {
                  if (!np.open) np.settled();
                },
                duration: np.open ? Motion.base : Motion.slow,
                child: _built ? const NowPlayingView() : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The cover, huge and blurred, dimmed under everything.
class ArtBackground extends StatelessWidget {
  const ArtBackground({super.key, required this.song, this.dim = 0.62, this.fade = const Duration(milliseconds: 700)});
  final Song? song;
  final double dim;

  /// How long the colors take to fade to the next song's.
  final Duration fade;

  // Clipped: the blur would otherwise spill over the title bar and player bar.
  @override
  Widget build(BuildContext context) => ClipRect(
    child: Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: K.root),
        AnimatedSwitcher(
          duration: fade,
          layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: song == null
              ? const SizedBox.expand()
              : ImageFiltered(
                  key: ValueKey(song!.id.isEmpty ? song!.title : song!.id),
                  imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70, tileMode: TileMode.decal),
                  child: Transform.scale(scale: 1.3, child: Cover(song!.art, image: song!.image, radius: 0)),
                ),
        ),
        ColoredBox(color: K.root.withValues(alpha: dim)),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [const Color(0x002B6CB0), K.root.withValues(alpha: 0.8)],
              stops: const [0.3, 1],
            ),
          ),
        ),
      ],
    ),
  );
}

class NowPlayingView extends StatefulWidget {
  const NowPlayingView({super.key});

  @override
  State<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends State<NowPlayingView> {
  bool _idle = false;
  Timer? _idleTimer;

  /// The song Now Playing opened on: later songs' lyrics roll in.
  late final String _openedOn = PlayerScope.read(context).song?.id ?? '';

  /// Whether the last song change went back, judged as the cover does
  /// (ArtStack): the song we left is up next again. The lyrics then roll
  /// the other way.
  bool _back = false;
  String? _lastId, _lastNextId;

  void _followDirection(Player p, Song song) {
    final next = p.upNext.firstOrNull?.id;
    if (_lastId != null && song.id != _lastId) _back = next == _lastId && _lastNextId != song.id;
    _lastId = song.id;
    _lastNextId = next;
  }

  @override
  void initState() {
    super.initState();
    _wake();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  /// Focus hides its controls after the tuned idle time; the mouse brings
  /// them back.
  void _wake() {
    if (_idle) setState(() => _idle = false);
    _idleTimer?.cancel();
    _idleTimer = Timer(
      Duration(milliseconds: (({...styleDesktop, ...PlayerScope.read(context).settings.lyricStyle}['controlsIdleSeconds'] ?? 3) * 1000).round()),
      () {
        if (mounted) setState(() => _idle = true);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final np = NowPlayingScope.of(context);
    final song = p.song;
    final layout = p.settings.nowPlayingLayout;
    if (song == null) return ColoredBox(color: K.root);
    _followDirection(p, song);
    // The Style menu and the usual view cross over as the menu opens and
    // closes, over the one background.
    return Stack(
      fit: StackFit.expand,
      children: [
        ArtBackground(song: song, dim: p.settings.bgDim, fade: _colorFade(p)),
        AnimatedSwitcher(
          duration: Motion.slow,
          reverseDuration: Motion.base,
          switchInCurve: editorCurve,
          switchOutCurve: editorCurve.flipped,
          layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: calm(context) ? c : ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(a), child: c),
          ),
          child: np.editing != null
              ? KeyedSubtree(key: const ValueKey('style'), child: _editor(context, p, np, song))
              : KeyedSubtree(key: const ValueKey('view'), child: _view(context, p, np, song, layout)),
        ),
      ],
    );
  }

  Widget _view(BuildContext context, Player p, NowPlaying np, Song song, String layout) {
    return MouseRegion(
      onHover: (_) => _wake(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (layout == 'focus') _focus(context, p, song) else _split(context, p, np, song, layout == 'under'),
          if (layout == 'under')
            Positioned(
              top: 16,
              right: 20,
              child: AnimatedOpacity(
                opacity: layout == 'focus' && _idle ? 0 : 1,
                duration: Motion.long,
                child: _TopRight(np: np, song: song, switcher: layout == 'under'),
              ),
            ),
        ],
      ),
    );
  }

  /// The Style menu inside Now Playing, as the desktop's: the art and
  /// transport in a narrow column, the menu, then the live lyrics.
  Widget _editor(BuildContext context, Player p, NowPlaying np, Song song) => LayoutBuilder(
    builder: (context, c) => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 72,
          child: Column(
            spacing: 14,
            children: [
              const SizedBox(height: 10),
              IconBtn(Icons.close_rounded, 'Close the Style menu', np.stopEditing),
              const Spacer(),
              Cover(song.art, image: song.image, size: 48, radius: 8),
              IconBtn(Icons.skip_previous_rounded, 'Previous', p.prev, color: K.text, size: 22),
              PlayCircle(playing: p.playing, onTap: p.toggle, size: 36),
              IconBtn(Icons.skip_next_rounded, 'Next', p.next, color: K.text, size: 22),
              const Spacer(),
            ],
          ),
        ),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Motion.long,
          curve: const Interval(0.22, 1, curve: editorCurve),
          builder: (_, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(offset: Offset(calm(context) ? 0 : -32 * (1 - t), 0), child: child),
          ),
          child: Container(
            width: (c.maxWidth * 0.34).clamp(380.0, 460.0),
            decoration: BoxDecoration(
              color: K.panel.withValues(alpha: 0.78),
              border: Border.symmetric(vertical: BorderSide(color: K.line)),
            ),
            padding: const EdgeInsets.only(top: 12),
            child: StyleMenu(tab: np.editing!, live: true, onClose: np.stopEditing, onTab: np.editStyle, showClose: false),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 56, 32, 24),
            // The Crossfade tab shows the cover change instead.
            child: np.editing == 'crossfade'
                ? _CoverPreview(song: song, next: p.upNext)
                : lyricsRoll(
                    LyricsPanel(key: ValueKey(song.id), song: song, rollIn: song.id != _openedOn, rollBack: _back),
                    back: _back,
                  ),
          ),
        ),
      ],
    ),
  );

  Duration _colorFade(Player p) => p.settings.colorFade ? Duration(milliseconds: (p.settings.colorFadeSeconds * 1000).round()) : Duration.zero;

  Widget _split(BuildContext context, Player p, NowPlaying np, Song song, bool under) => LayoutBuilder(
    builder: (context, c) {
      final art = (c.maxHeight * (under ? 0.36 : 0.42)).clamp(160.0, 340.0);
      final left = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ArtStack(song, next: p.upNext, size: art),
              Positioned(
                left: 0,
                top: 0,
                width: art,
                height: art,
                child: _ArtActions(song: song),
              ),
            ],
          ),
          const SizedBox(height: 26),
          _Link(
            onTap: song.albumId == null ? null : () => openPage(context, PageKind.album, [song.albumId]),
            builder: (on) => Text(
              song.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Txt.title().copyWith(decoration: on ? TextDecoration.underline : null, decorationColor: K.text3),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Flexible(
                child: _Link(
                  onTap: song.artistId == null ? null : () => openPage(context, PageKind.artist, [song.artistId]),
                  builder: (on) => Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(14, c: on ? K.text : K.text2),
                  ),
                ),
              ),
              Text(' · ', style: ts(14, c: K.text3)),
              Flexible(
                child: _Link(
                  onTap: song.albumId == null ? null : () => openPage(context, PageKind.album, [song.albumId]),
                  builder: (on) => Text(
                    song.album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(14, c: on ? K.text : K.text2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          QualityLine(song: song),
          if (under) ...[
            const SizedBox(height: 26),
            SizedBox(
              width: art + 60,
              child: _UnderControls(p: p),
            ),
          ],
        ],
      );
      return Padding(
        padding: EdgeInsets.fromLTRB(c.maxWidth * 0.06, 64, c.maxWidth * 0.04, under ? 24 : 0),
        child: Row(
          children: [
            Expanded(flex: 5, child: left),
            const SizedBox(width: 32),
            Expanded(
              flex: 7,
              // Lyrics and Queue slide a little, the way their tabs sit (Lyrics
              // left, Queue right); songs' lyrics roll (lyricsRoll).
              child: AnimatedSwitcher(
                duration: Motion.slow,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
                transitionBuilder: (c, a) => FadeTransition(
                  opacity: a,
                  child: calm(context)
                      ? c
                      : SlideTransition(
                          position: Tween(begin: Offset(c.key == const ValueKey('q') ? 0.08 : -0.08, 0), end: Offset.zero).animate(a),
                          child: c,
                        ),
                ),
                child: np.panel == NpPanel.queue
                    ? const QueuePanel(key: ValueKey('q'))
                    : KeyedSubtree(
                        key: const ValueKey('l'),
                        child: lyricsRoll(
                          LyricsPanel(key: ValueKey(song.id), song: song, rollIn: song.id != _openedOn, rollBack: _back),
                          back: _back,
                        ),
                      ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _focus(BuildContext context, Player p, Song song) => Stack(
    fit: StackFit.expand,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(80, 40, 80, 40),
        child: lyricsRoll(
          LyricsPanel(key: ValueKey(song.id), song: song, size: 54, center: true, showSource: !_idle, rollIn: song.id != _openedOn, rollBack: _back),
          back: _back,
        ),
      ),
      Positioned(
        top: 20,
        left: 24,
        child: Row(
          children: [
            Cover(song.art, image: song.image, size: 44, radius: 8),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(song.title, style: ts(14, w: FontWeight.w600)),
                Text(song.artist, style: ts(12, c: K.text2)),
              ],
            ),
          ],
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: LinearProgressIndicator(
          value: p.length > 0 ? (p.position / p.length).clamp(0, 1) : 0,
          minHeight: 2,
          color: K.accent,
          backgroundColor: K.tint.withValues(alpha: 0.1),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 12,
        child: AnimatedOpacity(
          opacity: _idle ? 0 : 1,
          duration: Motion.long,
          child: Center(
            child: SizedBox(width: 520, child: _UnderControls(p: p, compact: true)),
          ),
        ),
      ),
    ],
  );
}

/// The song's quality under its title: format, bit depth, sample rate and
/// bitrate, or what the server converts it to. Asked of the server once per
/// song (lists leave the file details out to stay small).
class QualityLine extends StatefulWidget {
  const QualityLine({super.key, required this.song});
  final Song song;

  @override
  State<QualityLine> createState() => _QualityLineState();
}

class _QualityLineState extends State<QualityLine> {
  static final _cache = <String, Map?>{};
  Map? _item;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(QualityLine old) {
    super.didUpdateWidget(old);
    if (old.song.id != widget.song.id) _load();
  }

  Future<void> _load() async {
    final id = widget.song.id;
    if (_cache.containsKey(id)) return setState(() => _item = _cache[id]);
    final item = await LibraryScope.read(context).item(id).catchError((_) => null);
    if (_cache.length > 200) _cache.clear();
    _cache[id] = item;
    if (mounted && widget.song.id == id) setState(() => _item = item);
  }

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.read(context);
    final q = qualityOf(_item, converted: p.converted, maxBitrate: p.settings.maxStreamingBitrate);
    return AnimatedOpacity(
      opacity: q.isEmpty ? 0 : 1,
      duration: Motion.slow,
      child: Wrap(
        spacing: 22,
        runSpacing: 10,
        children: [
          for (final (label, value) in q)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: ts(14, w: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(label.toUpperCase(), style: Txt.caps()),
              ],
            ),
        ],
      ),
    );
  }
}

/// The transport, seek bar and extras when they leave the player bar.
class _UnderControls extends StatelessWidget {
  const _UnderControls({required this.p, this.compact = false});
  final Player p;
  final bool compact;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(fmt(p.position), style: ts(11, c: K.text3, tab: true)),
          ),
          Expanded(
            child: ThinBar(value: p.length > 0 ? p.position / p.length : 0, onChanged: p.length > 0 ? (v) => p.seek(v * p.length) : null),
          ),
          SizedBox(
            width: 40,
            child: Text(
              fmt(p.length),
              textAlign: TextAlign.right,
              style: ts(11, c: K.text3, tab: true),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 20,
        children: [
          IconBtn(Icons.shuffle_rounded, 'Shuffle', p.toggleShuffle, color: p.shuffle ? K.accent : K.text2, size: 20),
          IconBtn(Icons.skip_previous_rounded, 'Previous', p.prev, color: K.text, size: 30),
          PlayCircle(playing: p.playing, onTap: p.toggle, size: compact ? 48 : 60),
          IconBtn(Icons.skip_next_rounded, 'Next', p.next, color: K.text, size: 30),
          IconBtn(
            p.repeat == Repeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
            'Repeat',
            p.toggleRepeat,
            color: p.repeat == Repeat.off ? K.text2 : K.accent,
            size: 20,
          ),
        ],
      ),
      if (!compact) ...[
        const SizedBox(height: 10),
        Row(
          children: [
            IconBtn(p.isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded, 'Like', p.toggleLike, color: p.isLiked ? K.like : K.text2),
            const Spacer(),
            IconBtn(p.volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, 'Mute', () => p.setVolume(p.volume == 0 ? 0.7 : 0)),
            SizedBox(
              width: 110,
              child: ThinBar(value: p.volume, onChanged: p.setVolume, color: K.text2, label: volumeLabel),
            ),
          ],
        ),
      ],
    ],
  );
}

/// Lyrics and Queue, only when the player bar (which has them) is gone.
/// Closing is the title bar's Now Playing title, Esc or Back.
class _TopRight extends StatelessWidget {
  const _TopRight({required this.np, required this.song, required this.switcher});
  final NowPlaying np;
  final Song song;
  final bool switcher;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 8,
    children: [
      if (switcher)
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: K.surface.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(10)),
          child: Row(
            children: [
              for (final (panel, label, icon) in [(NpPanel.lyrics, 'Lyrics', Icons.lyrics_outlined), (NpPanel.queue, 'Queue', Icons.queue_music_rounded)])
                Hover(
                  onTap: () => np.setPanel(panel),
                  builder: (_, on) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: np.panel == panel ? K.accentTint : Colors.transparent, borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      children: [
                        Icon(icon, size: 15, color: np.panel == panel ? K.accent : K.text2),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: ts(12, w: FontWeight.w500, c: np.panel == panel ? K.accent : K.text2),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
    ],
  );
}

/// One song's lyrics giving way to the next's: the old sheet glides up and
/// fades, moving with the new one (rollIn), which springs up from half a
/// panel below.
Widget lyricsRoll(Widget child, {bool back = false}) => Builder(builder: (context) => _lyricsRoll(context, child, back));

Widget _lyricsRoll(BuildContext context, Widget child, bool back) => AnimatedSwitcher(
  duration: const Duration(milliseconds: 550),
  reverseDuration: const Duration(milliseconds: 650),
  // The first 100 ms wait: the cover leads a song change, the lyrics follow.
  switchInCurve: const Interval(0.18, 1, curve: Curves.easeOut),
  // Mirrored, so the old sheet starts moving at once and eases to a stop,
  // as the new one's spring does.
  switchOutCurve: Curves.easeOutCubic.flipped,
  layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
  // One shape for both sheets: the old one switching shape as it left was
  // rebuilt from scratch mid-transition. Only the old sheet moves; forward it
  // glides up, back, down.
  transitionBuilder: (c, a) => FadeTransition(
    opacity: a,
    child: SlideTransition(
      position: Tween(begin: c.key == child.key || calm(context) ? Offset.zero : Offset(0, back ? 0.5 : -0.5), end: Offset.zero).animate(a),
      child: c,
    ),
  ),
  child: child,
);

/// The song's lyrics: fetched when it changes, with the source pill to force
/// another source.
class LyricsPanel extends StatefulWidget {
  const LyricsPanel({
    super.key,
    required this.song,
    this.size,
    this.center = false,
    this.phone = false,
    this.showSource = true,
    this.rollIn = false,
    this.rollBack = false,
  });
  final Song song;

  /// Null takes the desktop's size, from the window.
  final double? size;
  final bool center, phone;

  /// The sheet rolls up from below (playback moved on by itself).
  final bool rollIn;

  /// Rolling in from above, after going back a song.
  final bool rollBack;

  /// Focus hides the source pill with its other controls when idle.
  final bool showSource;

  @override
  State<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<LyricsPanel> {
  Future<Lyrics?>? _lyrics;
  String? _forced;

  Settings? _settings;
  String? _saved;
  bool _serverOnly = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_lyrics == null) {
      _settings = PlayerScope.read(context).settings..addListener(_settingsChanged);
      lyricsEdited.addListener(_edited);
      _saved = _settings!.lyricsSource;
      _serverOnly = _settings!.serverOnlyLyrics;
      _forced = lyricSources.contains(_saved) || serverLyricSources.contains(_saved) ? _saved : null;
      _lyrics = _fetch();
    }
  }

  @override
  void dispose() {
    _settings?.removeListener(_settingsChanged);
    lyricsEdited.removeListener(_edited);
    super.dispose();
  }

  /// The lyrics editor closed on this song: ask again, for what was saved.
  void _edited() {
    if (lyricsEdited.value == widget.song.id && mounted) _force(_forced);
  }

  /// The Style menu changed the source or the sizes: follow it live.
  void _settingsChanged() {
    final saved = _settings!.lyricsSource, only = _settings!.serverOnlyLyrics;
    if (saved != _saved || only != _serverOnly) {
      _saved = saved;
      _serverOnly = only;
      return _force(lyricSources.contains(saved) || serverLyricSources.contains(saved) ? saved : null);
    }
    setState(() {});
  }

  Future<Lyrics?> _fetch() async {
    final f = LibraryScope.read(context).lyrics;
    if (f == null) return _demo;
    f.serverOnly = _settings?.serverOnlyLyrics ?? false;
    final found = await f.fetch(widget.song, forced: _forced);
    // The next song's too, so its sheet is there the moment it starts.
    final next = mounted ? PlayerScope.read(context).upNext.firstOrNull : null;
    if (next != null && !next.live && !f.has(next.id)) f.fetch(next).ignore();
    return found;
  }

  void _force(String? source) => setState(() {
    _forced = source;
    _lyrics = _fetch();
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<Lyrics?>(
    future: _lyrics,
    // Fetched ahead (the next song's): drawn on the first frame, no wait.
    initialData: _forced == null ? LibraryScope.read(context).lyrics?.cached(widget.song.id) : null,
    builder: (context, snap) {
      final p = PlayerScope.read(context);
      final l = snap.data;
      Widget body;
      if (l == null && snap.connectionState != ConnectionState.done) {
        body = const SizedBox.shrink(); // usually a moment; a spinner would flash between songs
      } else if (l == null || l.lines.isEmpty) {
        body = Center(
          child: Text(l?.instrumental == true ? 'Instrumental' : 'No lyrics for this one.', style: widget.phone ? ds(22, c: K.text2) : Txt.section(K.text2)),
        );
      } else {
        body = LyricsView(
          player: p,
          lyrics: l,
          size: widget.size,
          scale: l.synced ? p.settings.lyricScale : p.settings.plainLyricScale,
          center: widget.center,
          phone: widget.phone,
          rollIn: widget.rollIn,
          rollBack: widget.rollBack,
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.center || l != null)
            AnimatedOpacity(
              opacity: widget.showSource ? 1 : 0,
              duration: Motion.long,
              child: Align(
                alignment: widget.center ? Alignment.center : Alignment.centerLeft,
                child: Padding(padding: const EdgeInsets.only(bottom: 8), child: _sourcePill(context, l)),
              ),
            ),
          Expanded(child: body),
          if (l?.credit case final c?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                // SpicyLyrics' terms: the provider, and a community sync's
                // uploader and maker, on screen wherever its lyrics show, not
                // only on hover as the source pill is.
                // ponytail: names only; links when the app gets a URL opener.
                [c.provider, if (c.uploader case final u?) 'Uploaded by ${u.name}', if (c.maker case final m?) 'Synced by ${m.name}'].join(' · '),
                textAlign: widget.center ? TextAlign.center : TextAlign.start,
                style: ts(11, c: K.text3),
              ),
            ),
        ],
      );
    },
  );

  Widget _sourcePill(BuildContext context, Lyrics? l) => PopupMenuButton<String>(
    popUpAnimationStyle: Motion.menu,
    tooltip: 'Lyrics source',
    onSelected: (v) => v == 'edit' ? openLyricsEditor(context, widget.song) : _force(v == 'auto' ? null : v),
    itemBuilder: (_) => [
      for (final (v, label) in [('auto', 'Best available'), for (final s in lyricSources) (s, s)])
        PopupMenuItem(
          value: v,
          height: 34,
          child: Row(
            children: [
              SizedBox(width: 22, child: (_forced ?? 'auto') == v ? Icon(Icons.check_rounded, size: 16, color: K.accent) : null),
              Text(label, style: ts(13)),
            ],
          ),
        ),
      if (!widget.song.live && canEditLyrics(context)) ...[
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'edit',
          height: 34,
          child: Row(
            children: [
              SizedBox(width: 22, child: Icon(Icons.edit_note_rounded, size: 16, color: K.text2)),
              Text('Edit lyrics…', style: ts(13)),
            ],
          ),
        ),
      ],
    ],
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: K.surface.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(99)),
      child: Text(
        l == null || l.lines.isEmpty
            ? 'Lyrics: ${_forced ?? 'none found'}'
            : '${l.karaoke
                  ? 'Word by word'
                  : l.synced
                  ? 'Synced'
                  : 'Plain'} · ${l.source}',
        style: ts(12, c: K.text2),
      ),
    ),
  );
}

/// The demo's lyrics, timed against the demo song.
final _demo = Lyrics([
  for (final (i, t) in [
    'I followed the river down past the mill',
    'Counting the stones that it carried for me',
    'Every bend was a song I already knew',
    'And the water kept moving the way that it does',
    'Nothing stays still if you give it the time',
    'So I let it go under and out to the sea',
  ].indexed)
    LyricLine((120 + i * 6) * 10000000, null, t, null),
], 'Demo');

/// The queue: what plays now, then up next, which can be reordered,
/// trimmed, cleared, or saved as a playlist.
class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key, this.phone = false});
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final next = p.upNext;
    final song = p.song;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Up next', style: Txt.section())),
            if (!LibraryScope.read(context).demo && song != null)
              TextButton(
                onPressed: () => addToPlaylistDialog(context, [song, ...next]),
                child: Text('Save as a playlist', style: ts(13, c: K.accent)),
              ),
            if (next.isNotEmpty)
              TextButton(
                onPressed: () {
                  final before = p.orderSnapshot;
                  p.clearUpNext();
                  toast(context, 'Cleared up next', action: ('Undo', () => p.restoreOrder(before)));
                },
                child: Text('Clear', style: ts(13, c: K.text2)),
              ),
          ],
        ),
        if (song != null) ...[
          const SizedBox(height: 6),
          Text('NOW PLAYING${p.source == null ? '' : ' FROM ${p.source!.toUpperCase()}'}', style: Txt.caps()),
          const SizedBox(height: 6),
          _QueueRow(song: song, current: true, onTap: p.toggle),
          const SizedBox(height: 14),
        ],
        Expanded(
          child: next.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(p.settings.autoMix ? 'Auto-mix keeps it going after this.' : 'Nothing after this.', style: ts(13, c: K.text3)),
                      // The way to keep it going.
                      if (!p.settings.autoMix && !LibraryScope.read(context).demo) ...[
                        const SizedBox(height: 12),
                        Pill('Turn on Auto-mix', icon: Icons.all_inclusive_rounded, primary: false, onTap: () => p.settings.setAutoMix(true)),
                      ],
                    ],
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: next.length,
                  onReorderItem: p.moveUpNext,
                  itemBuilder: (context, i) => Row(
                    key: ValueKey('${next[i].id}#$i'),
                    children: [
                      ReorderableDragStartListener(
                        index: i,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.drag_indicator_rounded, size: 18, color: K.text3),
                        ),
                      ),
                      Expanded(
                        // Moving without a drag: the menu, or Alt+Up and Alt+Down.
                        child: _QueueRow(
                          song: next[i],
                          onTap: () => p.jumpUpNext(i),
                          extra: [
                            if (i > 0) ('Move up', Icons.arrow_upward_rounded, () => p.moveUpNext(i, i - 1)),
                            if (i < next.length - 1) ('Move down', Icons.arrow_downward_rounded, () => p.moveUpNext(i, i + 1)),
                            ('Remove from queue', Icons.close_rounded, () => _remove(context, p, i)),
                          ],
                          keys: {
                            const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () => p.moveUpNext(i, i - 1),
                            const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () => p.moveUpNext(i, i + 1),
                            const SingleActivator(LogicalKeyboardKey.delete): () => _remove(context, p, i),
                          },
                        ),
                      ),
                      IconBtn(Icons.close_rounded, 'Remove', () => _remove(context, p, i), size: 16),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// Take the [i]th song out of up next, with an Undo.
void _remove(BuildContext context, Player p, int i) {
  final before = p.orderSnapshot, song = p.upNext[i];
  p.removeUpNext(i);
  toast(context, 'Removed ${song.title}', action: ('Undo', () => p.restoreOrder(before)));
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.song, required this.onTap, this.current = false, this.extra = const [], this.keys = const {}});
  final Song song;
  final VoidCallback onTap;
  final bool current;

  /// Its own menu entries and keys (moving it in the queue).
  final List<(String, IconData, VoidCallback)?> extra;
  final Map<ShortcutActivator, VoidCallback> keys;

  @override
  Widget build(BuildContext context) => MenuKeys(
    open: (at) => songMenu(context, song, at, extra: extra),
    also: keys,
    child: GestureDetector(
      onSecondaryTapUp: (d) => songMenu(context, song, d.globalPosition, extra: extra),
      child: Hover(
        onTap: onTap,
        builder: (_, on) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: current
                ? K.surface.withValues(alpha: 0.8)
                : on
                ? K.line
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Cover(song.art, image: song.image, size: 40, radius: 6),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(13, w: FontWeight.w500, c: current ? K.accent : K.text),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(12, c: K.text3),
                    ),
                  ],
                ),
              ),
              Text(song.seconds > 0 ? fmt(song.seconds) : '', style: ts(12, c: K.text3)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The Style menu's Crossfade tab: the cover change, played on Replay.
class _CoverPreview extends StatefulWidget {
  const _CoverPreview({required this.song, required this.next});
  final Song song;
  final List<Song> next;

  @override
  State<_CoverPreview> createState() => _CoverPreviewState();
}

class _CoverPreviewState extends State<_CoverPreview> {
  bool _swapped = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.song;
    // Nothing queued: the same cover stands in, as another song.
    final b = widget.next.firstOrNull ?? Song(a.title, a.artist, a.album, a.year, a.seconds, a.art, id: '${a.id}#preview', image: a.image);
    // Always forward: each one's next is the other.
    final (shown, then) = _swapped ? (b, a) : (a, b);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 28,
        children: [
          ArtStack(shown, next: [then, shown], size: 260),
          Pill('Replay', icon: Icons.replay_rounded, primary: false, onTap: () => setState(() => _swapped = !_swapped)),
        ],
      ),
    );
  }
}

/// Text that opens a page, underlined or brightened on hover.
class _Link extends StatelessWidget {
  const _Link({required this.onTap, required this.builder});
  final VoidCallback? onTap;
  final Widget Function(bool hovered) builder;

  @override
  Widget build(BuildContext context) => onTap == null ? builder(false) : Hover(onTap: onTap, builder: (_, on) => builder(on));
}

/// Over the cover on hover, as the desktop's: the art dims and Favorite,
/// Add to playlist and View album appear.
class _ArtActions extends StatefulWidget {
  const _ArtActions({required this.song});
  final Song song;

  @override
  State<_ArtActions> createState() => _ArtActionsState();
}

class _ArtActionsState extends State<_ArtActions> {
  bool _on = false;

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final song = widget.song;
    Widget btn(IconData icon, String tip, VoidCallback? onTap, {Color color = Colors.white}) => Tooltip(
      message: tip,
      child: Hover(
        onTap: onTap,
        builder: (_, on) => AnimatedScale(
          scale: on ? 1.06 : 1,
          duration: Motion.fast,
          child: AnimatedContainer(
            duration: Motion.fast,
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: on ? 0.28 : 0.16),
            ),
            child: Icon(icon, size: 22, color: color),
          ),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _on = true),
      onExit: (_) => setState(() => _on = false),
      child: AnimatedOpacity(
        opacity: _on ? 1 : 0,
        duration: Motion.base,
        child: IgnorePointer(
          ignoring: !_on,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(10)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 14,
              children: [
                btn(
                  p.isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  p.isLiked ? 'Unfavorite' : 'Favorite',
                  p.toggleLike,
                  color: p.isLiked ? K.like : Colors.white,
                ),
                if (!LibraryScope.read(context).demo) btn(Icons.add_rounded, 'Add to playlist', () => addToPlaylistDialog(context, [song])),
                btn(Icons.album_outlined, 'View album', song.albumId == null ? null : () => openPage(context, PageKind.album, [song.albumId])),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
