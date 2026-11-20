// Now Playing on phones, Apple Music's shape: it grows out of the mini player
// and shrinks back into it (dragged down, or the back gesture). The art stands
// large and centered, the next covers faintly behind; under it the title, the
// seek bar, the controls (moved up into reach), the volume, and Lyrics,
// devices and Queue. Lyrics and Queue take the art's place, which shrinks to a
// header with the title. Swiping the art skips, the art following the finger.
import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/desktop.dart' show LikeButton;
import 'package:cascade/ui/now_playing.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/panels.dart' show DevicesButton;
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/settings_panel.dart';
import 'package:cascade/ui/widgets.dart';

/// Now Playing over the phone layout: grows out of the mini player ([pill]) as
/// it opens and shrinks back into it as it closes, following a finger that
/// drags it down. Reduce motion: it fades instead.
class PhoneNowPlayingSheet extends StatefulWidget {
  const PhoneNowPlayingSheet({super.key, required this.pill});

  /// The mini player, where it grows from and shrinks back to.
  final GlobalKey pill;

  @override
  State<PhoneNowPlayingSheet> createState() => _PhoneNowPlayingSheetState();
}

class _PhoneNowPlayingSheetState extends State<PhoneNowPlayingSheet> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420))..addListener(() => setState(() {}));
  NowPlaying? _np;
  bool _open = false;

  /// The mini player, in this box's coordinates, when it last opened or closed.
  Rect? _from;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final np = NowPlayingScope.read(context);
    if (identical(np, _np)) return;
    _np?.removeListener(_sync);
    _np = np..addListener(_sync);
    _open = np.open;
    _c.value = np.open ? 1 : 0;
  }

  @override
  void dispose() {
    _np?.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  void _sync() {
    if (_np!.open == _open) return;
    _open = _np!.open;
    _from = _pill() ?? _from;
    if (_open) {
      _c.animateTo(1, curve: const Cubic(.2, .9, .25, 1));
    } else {
      _c.animateBack(0, duration: const Duration(milliseconds: 320), curve: const Cubic(.4, 0, .2, 1));
    }
  }

  Rect? _pill() {
    final pill = widget.pill.currentContext?.findRenderObject() as RenderBox?;
    final me = context.findRenderObject() as RenderBox?;
    if (pill == null || me == null || !pill.attached || !me.attached || !pill.hasSize) return null;
    return pill.localToGlobal(Offset.zero, ancestor: me) & pill.size;
  }

  void _drag(double dy) {
    final h = context.size?.height ?? 800;
    _c.value = (_c.value - dy / h).clamp(0.0, 1.0);
  }

  void _release(double vy) {
    if (vy > 700 || _c.value < 0.7) {
      _np!.close();
    } else {
      _c.animateTo(1, curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_c.value == 0 && !_open) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        final full = Offset.zero & c.biggest;
        final t = _c.value;
        final content = PhoneNowPlaying(onDrag: _drag, onRelease: _release);
        if (calm(context)) return Opacity(opacity: t, child: content);
        final from = _from ?? Rect.fromLTWH(8, full.height - 150, full.width - 16, 64);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: Rect.lerp(from, full, t)!,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(lerpDouble(18, 0, t)!),
                child: ColoredBox(
                  color: A.mini,
                  // Laid out full size and uncovered as it grows, so nothing
                  // squeezes into the pill's size.
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minWidth: full.width,
                    maxWidth: full.width,
                    minHeight: full.height,
                    maxHeight: full.height,
                    child: Opacity(opacity: ((t - 0.1) / 0.5).clamp(0.0, 1.0), child: content),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class PhoneNowPlaying extends StatefulWidget {
  const PhoneNowPlaying({super.key, this.onDrag, this.onRelease});

  /// A finger dragging it down (by this much), and letting go (this fast).
  final ValueChanged<double>? onDrag, onRelease;

  @override
  State<PhoneNowPlaying> createState() => _PhoneNowPlayingState();
}

class _PhoneNowPlayingState extends State<PhoneNowPlaying> {
  /// null: the art; else that panel takes its place.
  NpPanel? _panel;

  /// How far the art is being swiped sideways.
  double _swipe = 0;
  bool _swiping = false;

  /// Dragging down closes, from the grabber, the header or the art.
  Widget _grab(Widget child, {Key? key}) => GestureDetector(
    key: key,
    behavior: HitTestBehavior.opaque,
    onVerticalDragUpdate: widget.onDrag == null ? null : (d) => widget.onDrag!(d.delta.dy),
    onVerticalDragEnd: widget.onRelease == null ? null : (d) => widget.onRelease!(d.primaryVelocity ?? 0),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final np = NowPlayingScope.of(context);
    final song = p.song;
    if (song == null) return const SizedBox.shrink();
    final moving = !calm(context);
    return Material(
      color: K.root,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ArtBackground(song: song, dim: 0.55),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Column(
                children: [
                  _grab(
                    Hover(
                      onTap: np.close,
                      label: 'Close',
                      builder: (_, _) => SizedBox(
                        height: 30,
                        width: double.infinity,
                        child: Center(
                          child: Container(
                            width: 38,
                            height: 5,
                            decoration: BoxDecoration(color: K.text.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(3)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: Motion.slow,
                      switchInCurve: const Cubic(.2, .8, .2, 1),
                      // One shape both ways (a fade with a slide, zero without
                      // motion), so the leaving one is never rebuilt mid-way.
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(begin: Offset(0, moving ? 0.04 : 0), end: Offset.zero).animate(a),
                          child: child,
                        ),
                      ),
                      child: _panel == null ? _art(p, song) : _panelView(p, song, _panel!),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_panel == null) _title(p, song),
                  const SizedBox(height: 10),
                  ThinBar(value: p.length > 0 ? p.position / p.length : 0, onChanged: p.length > 0 ? (v) => p.seek(v * p.length) : null),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(fmt(p.position), style: ts(12, c: K.text3, tab: true)),
                        Text(fmt(p.length), style: ts(12, c: K.text3, tab: true)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconBtn(Icons.shuffle_rounded, 'Shuffle', p.toggleShuffle, color: p.shuffle ? K.accent : K.text2, size: 22),
                      IconBtn(Icons.skip_previous_rounded, 'Previous', p.prev, color: K.text, size: 42),
                      PlayCircle(playing: p.playing, onTap: p.toggle, size: 76),
                      IconBtn(Icons.skip_next_rounded, 'Next', p.next, color: K.text, size: 42),
                      IconBtn(
                        p.repeat == Repeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                        'Repeat',
                        p.toggleRepeat,
                        color: p.repeat == Repeat.off ? K.text2 : K.accent,
                        size: 22,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.volume_mute_rounded, size: 18, color: K.text3),
                      Expanded(
                        child: ThinBar(value: p.volume, onChanged: p.setVolume, color: K.text2, label: volumeLabel),
                      ),
                      Icon(Icons.volume_up_rounded, size: 18, color: K.text3),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _tab(Icons.lyrics_outlined, 'Lyrics', NpPanel.lyrics),
                      const DevicesButton(),
                      _tab(Icons.queue_music_rounded, 'Queue', NpPanel.queue),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The art, centered with the next covers faintly behind; swiped sideways
  /// it follows the finger and skips, dragged down it closes.
  Widget _art(Player p, Song song) => GestureDetector(
    key: const ValueKey('art'),
    behavior: HitTestBehavior.opaque,
    onVerticalDragUpdate: widget.onDrag == null ? null : (d) => widget.onDrag!(d.delta.dy),
    onVerticalDragEnd: widget.onRelease == null ? null : (d) => widget.onRelease!(d.primaryVelocity ?? 0),
    onHorizontalDragStart: (_) => setState(() => _swiping = true),
    onHorizontalDragUpdate: (d) => setState(() => _swipe += d.delta.dx),
    onHorizontalDragEnd: (d) {
      final v = d.primaryVelocity ?? 0;
      if (_swipe < -80 || v < -700) {
        p.next();
      } else if (_swipe > 80 || v > 700) {
        p.prev();
      }
      setState(() {
        _swiping = false;
        _swipe = 0;
      });
    },
    child: LayoutBuilder(
      builder: (context, c) {
        final size = min(c.maxWidth, c.maxHeight) * 0.94;
        return Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: _swipe),
            duration: _swiping ? Duration.zero : Motion.base,
            curve: Curves.easeOutCubic,
            builder: (_, dx, child) => Transform.translate(
              offset: Offset(dx, 0),
              child: Transform.rotate(angle: dx / 2400, child: child),
            ),
            // Centered on the art itself; the covers behind spill to the right.
            child: SizedBox(
              width: size,
              height: size,
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: size * 1.2,
                child: ArtStack(song, next: p.upNext, size: size, soft: true),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _title(Player p, Song song) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ds(22)),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ts(16, c: K.text2),
            ),
          ],
        ),
      ),
      LikeButton(p: p, size: 24),
      IconBtn(Icons.more_horiz_rounded, 'More', () => _more(context, p), size: 24),
    ],
  );

  /// Lyrics or Queue in the art's place, the art a header with the title.
  Widget _panelView(Player p, Song song, NpPanel panel) => Column(
    key: ValueKey(panel),
    children: [
      _grab(
        Row(
          children: [
            Cover(song.art, image: song.image, size: 56, radius: 8, shadow: true),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(16, w: FontWeight.w600),
                  ),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(14, c: K.text2),
                  ),
                ],
              ),
            ),
            LikeButton(p: p, size: 22),
            IconBtn(Icons.more_horiz_rounded, 'More', () => _more(context, p), size: 22),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: panel == NpPanel.lyrics ? LyricsPanel(key: ValueKey(song.id), song: song, size: 26, phone: true) : const QueuePanel(phone: true),
      ),
    ],
  );

  Widget _tab(IconData icon, String label, NpPanel panel) =>
      IconBtn(icon, label, () => setState(() => _panel = _panel == panel ? null : panel), color: _panel == panel ? K.accent : K.text2, size: 24);

  void _more(BuildContext context, Player p) {
    final song = p.song!;
    final lib = LibraryScope.read(context);
    final np = NowPlayingScope.read(context);
    final nav = NavScope.read(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: K.panel,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Cover(song.art, image: song.image, size: 44, radius: 6),
              title: Text(song.title, style: ts(15, w: FontWeight.w600)),
              subtitle: Text('${song.artist} · ${song.album}', style: ts(13, c: K.text2)),
            ),
            Divider(color: K.line),
            if (!lib.demo) _item(ctx, Icons.playlist_add_rounded, 'Add to playlist', () => addToPlaylistDialog(context, [song])),
            if (song.albumId != null)
              _item(ctx, Icons.album_outlined, 'Go to album', () {
                np.close();
                nav.open(PageKind.album, [song.albumId]);
              }),
            if (song.artistId != null)
              _item(ctx, Icons.person_outline_rounded, 'Go to artist', () {
                np.close();
                nav.open(PageKind.artist, [song.artistId]);
              }),
            // The sleep timer, here since the bottom row holds Lyrics, devices and Queue.
            const ListTile(leading: SleepTimerButton(), title: Text('Sleep timer')),
            _item(ctx, Icons.tune_rounded, 'Equalizer', () {
              np.close();
              nav.show('settings');
            }),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext ctx, IconData icon, String label, VoidCallback onTap) => ListTile(
    leading: Icon(icon, color: K.text2),
    title: Text(label, style: ts(15)),
    onTap: () {
      Navigator.pop(ctx);
      onTap();
    },
  );
}
