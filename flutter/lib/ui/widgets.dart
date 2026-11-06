// Tokens and the pieces both layouts share, matching the Figma draft
// (https://www.figma.com/design/5jCQuhu85omAoJsBRC57rs).
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/ui/scopes.dart';

/// Personality v1: the Cascade library colors from the Penpot file "Cascade
/// Personality v1", shared with the Swift app. Desktop and Android use the
/// same set.
abstract final class K {
  static const root = Color(0xFF0A0E13); // bg
  static const panel = Color(0xFF111821); // surface
  static const surface = Color(0xFF18222E); // surface-2
  static const surface2 = Color(0xFF223041); // hover, a step above surface-2
  static const line = Color(0x14FFFFFF); // line, white at 8%
  static const text = Color(0xFFEEF3F8);
  static const text2 = Color(0xFFA7B4C4);
  static const text3 = Color(0xFF687789);
  static const accent = Color(0xFF7CC4FF);
  static const accentTint = Color(0x247CC4FF); // accent at 14%
  static const accentDeep = Color(0xFF2B6CB0);
  static const ink = Color(0xFF06121F); // text on accent
  static const foam = Color(0xFFD7EEFF);
  static const glass = Color(0xEB18222E); // surface-2 at 92%
  static const like = Color(0xFFFF6B8A);
  static const error = Color(0xFFFF453A);

  /// The deep blue wash at the top of every page.
  static const wash = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x612B6CB0), Color(0x002B6CB0)], stops: [0, 0.38]);
}

/// Android's names for the same colors.
abstract final class A {
  static const bg = K.root;
  static const card = K.panel;
  static const bar = K.glass;
  static const nav = K.panel;
  static const mini = K.glass;
  static const indicator = K.accentTint;
  static const onIndicator = K.text;
  static const text = K.text;
  static const text2 = K.text2;
}

String fmt(num seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String greeting(String name) {
  final h = DateTime.now().hour;
  return '${h < 12
      ? 'Good morning'
      : h < 18
      ? 'Good afternoon'
      : 'Good evening'}, $name';
}

String today() {
  const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  final d = DateTime.now();
  return '${days[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
}

/// Body text (font.body, Inter).
TextStyle ts(double size, {FontWeight w = FontWeight.w400, Color c = K.text, double? ls, double h = 1.25}) =>
    TextStyle(fontFamily: 'Inter', fontSize: size, fontWeight: w, color: c, letterSpacing: ls, height: h);

/// Display text (font.display, Hanken Grotesk): headings, titles, lyrics.
TextStyle ds(double size, {FontWeight w = FontWeight.w600, Color c = K.text, bool italic = false, double h = 1.15}) =>
    TextStyle(fontFamily: 'Hanken Grotesk', fontSize: size, fontWeight: w, fontStyle: italic ? FontStyle.italic : FontStyle.normal, color: c, height: h);

/// The type tokens (Penpot set "Cascade").
abstract final class Txt {
  static TextStyle hero([Color c = K.text]) => ds(44, c: c, h: 1.05);
  static TextStyle title([Color c = K.text]) => ds(30, c: c, h: 1.1);
  static TextStyle section([Color c = K.text]) => ds(21, c: c, h: 1.2);
  static TextStyle voice([Color c = K.text2]) => ds(17, w: FontWeight.w400, c: c, italic: true, h: 1.3);
  static TextStyle brand([Color c = K.text]) => ds(17, c: c, italic: true, h: 1.2);
  static TextStyle caps([Color c = K.text3]) => ts(11, w: FontWeight.w600, c: c, ls: 0.88, h: 1.2);
}

/// Hover state for desktop; on touch it just never lights up.
class Hover extends StatefulWidget {
  const Hover({super.key, required this.builder, this.onTap});
  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;

  @override
  State<Hover> createState() => _HoverState();
}

class _HoverState extends State<Hover> {
  bool _on = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    onEnter: (_) => setState(() => _on = true),
    onExit: (_) => setState(() => _on = false),
    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: widget.builder(context, _on)),
  );
}

/// Set by the app: a downloaded copy of an image URL's cover, if there is one.
String? Function(String url)? localArt;
String? _local(String url) => localArt?.call(url);

/// A cover: the item's image over its placeholder gradient, which shows while
/// the image loads and stays when there is none.
class Cover extends StatelessWidget {
  const Cover(this.colors, {super.key, this.image, this.size, this.radius = 10, this.shadow = false});
  final List<Color> colors;
  final String? image;
  final double? size;
  final double radius;
  final bool shadow;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
      boxShadow: shadow ? const [BoxShadow(color: Color(0x73000000), blurRadius: 18, offset: Offset(0, 6))] : null,
    ),
    child: image == null
        ? null
        : _local(image!) != null
        ? Image.file(
            File(_local(image!)!),
            fit: BoxFit.cover,
            width: size,
            height: size,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          )
        : Image.network(
            image!,
            headers: LibraryScope.read(context).headers,
            fit: BoxFit.cover,
            width: size,
            height: size,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
  );
}

/// The solid accent play button with dark ink (Personality v1).
class PlayCircle extends StatelessWidget {
  const PlayCircle({super.key, required this.playing, required this.onTap, this.size = 36});
  final bool playing;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: playing ? 'Pause' : 'Play',
    child: Hover(
      onTap: onTap,
      builder: (_, on) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? K.foam : K.accent,
          boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 12, offset: Offset(0, 4))],
        ),
        child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: K.ink, size: size * 0.55),
      ),
    ),
  );
}

/// The accent pill button: Play, Resume, Save. Not primary: a quiet one.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.icon, required this.onTap, this.primary = true});
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final fg = onTap == null ? K.text3 : (primary ? K.ink : K.text);
    return Semantics(
      button: true,
      label: label,
      child: Hover(
        onTap: onTap,
        builder: (_, on) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.fromLTRB(icon == null ? 16 : 12, 8, 16, 8),
          decoration: BoxDecoration(
            color: onTap == null
                ? K.surface
                : primary
                ? (on ? K.foam : K.accent)
                : (on ? K.surface2 : K.surface),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, color: fg, size: 17), const SizedBox(width: 6)],
              Text(
                label,
                style: ts(13, w: FontWeight.w600, c: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The stepped art stack: the current art with what comes next falling in
/// behind it, or the art alone (setting off, or nothing next).
class ArtStack extends StatelessWidget {
  const ArtStack(this.song, {super.key, this.next = const [], required this.size});
  final Song song;
  final List<Song> next;
  final double size;

  @override
  Widget build(BuildContext context) {
    final behind = PlayerScope.read(context).settings.showArtStack ? next.take(2).toList() : const <Song>[];
    final step = size * 0.14;
    return SizedBox(
      width: size + step * behind.length,
      height: size,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          for (var i = behind.length - 1; i >= 0; i--)
            Positioned(
              left: step * (i + 1),
              child: Opacity(
                opacity: 0.55 - i * 0.15,
                child: Cover(behind[i].art, image: behind[i].image, size: size * (0.86 - i * 0.08), radius: 10),
              ),
            ),
          Cover(song.art, image: song.image, size: size, radius: 10, shadow: true),
        ],
      ),
    );
  }
}

/// A small icon button with a hover wash and a tooltip.
class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, this.tip, this.onTap, {super.key, this.filled = false, this.badge = false, this.color = K.text2, this.size = 18});
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

/// A Recently played row: the song, then artist and album.
class SongTile extends StatelessWidget {
  const SongTile(this.song, {super.key, required this.queue, this.width});
  final Song song;
  final double? width;
  final List<Song> queue;

  @override
  Widget build(BuildContext context) {
    final current = PlayerScope.of(context).song == song;
    return Hover(
      onTap: () => PlayerScope.read(context).play(song, queue),
      builder: (_, on) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: width,
        height: 48,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: on ? K.surface2 : K.surface, borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Cover(song.art, image: song.image, size: 48, radius: 0),
                if (on || current)
                  Container(
                    width: 48,
                    height: 48,
                    color: const Color(0x66000000),
                    child: Icon(current ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 22),
                  ),
              ],
            ),
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
                    style: ts(13, w: FontWeight.w500, c: current ? K.accent : K.text),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${song.artist} · ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(12, c: K.text3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

class AlbumCard extends StatelessWidget {
  const AlbumCard(this.album, {super.key, this.width});
  final Album album;
  final double? width;

  @override
  Widget build(BuildContext context) => Hover(
    onTap: () async {
      final tracks = await LibraryScope.read(context).tracksOf(album);
      if (tracks.isNotEmpty && context.mounted) await PlayerScope.read(context).play(tracks.first, tracks);
    },
    builder: (_, on) => SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: [BoxShadow(color: on ? K.accent : Colors.transparent, spreadRadius: 2)],
              ),
              child: Cover(album.art, image: album.image, shadow: true),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            album.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ts(13, w: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(
            album.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts(12, c: K.text3),
          ),
        ],
      ),
    ),
  );
}

class VideoThumb extends StatelessWidget {
  const VideoThumb(this.video, {super.key, required this.width, this.accent = K.accent});
  final Video video;
  final double width;
  final Color accent;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: SizedBox(
      width: width,
      height: width * 9 / 16,
      child: Stack(
        children: [
          Positioned.fill(child: Cover(video.art, image: video.image, radius: 0)),
          if (video.progress > 0) ...[
            Positioned(left: 0, right: 0, bottom: 0, child: Container(height: 4, color: const Color(0x8C000000))),
            Positioned(
              left: 0,
              bottom: 0,
              child: Container(height: 4, width: width * video.progress, color: accent),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Home's card. With a queue (restored or playing) it is "Previously
/// queued": that song, where the queue came from, how many are left, and the
/// next songs in the art stack, with Resume. Without one it is "Last played":
/// the last song alone, with Play.
class HeroCard extends StatelessWidget {
  const HeroCard(this.lastPlayed, this.played, {super.key, required this.compact, this.radius = 16});
  final Song lastPlayed;
  final List<Song> played;
  final bool compact;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final queued = p.song != null && p.queue.length > 1;
    final song = queued ? p.song! : lastPlayed;
    final next = queued ? p.upNext : const <Song>[];
    final art = compact ? 96.0 : 140.0;
    final from = [if (queued && p.source != null) 'From ${p.source}', if (next.isNotEmpty) '${next.length} left'].join(' · ');
    return Container(
      constraints: BoxConstraints(minHeight: compact ? 168 : 230),
      padding: EdgeInsets.all(compact ? 18 : 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: K.line),
        color: K.panel,
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0x805A2A5E), Color(0x00111821)]),
      ),
      child: Row(
        children: [
          ArtStack(song, next: next, size: art),
          SizedBox(width: compact ? 16 : 22),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  !queued
                      ? 'LAST PLAYED'
                      : p.playing
                      ? 'NOW PLAYING'
                      : 'PREVIOUSLY QUEUED',
                  style: Txt.caps(K.text2),
                ),
                const SizedBox(height: 6),
                Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: compact ? ds(22) : Txt.title()),
                const SizedBox(height: 4),
                Text(
                  '${song.artist} · ${song.album}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(13, c: K.text2),
                ),
                if (from.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    from,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(12, c: K.text3),
                  ),
                ],
                SizedBox(height: compact ? 12 : 16),
                Wrap(
                  spacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (queued)
                      Pill(p.playing ? 'Pause' : 'Resume', icon: p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, onTap: p.toggle)
                    else
                      Pill('Play', icon: Icons.play_arrow_rounded, onTap: () => p.play(song, played)),
                    Hover(
                      onTap: () {
                        if (!p.shuffle) p.toggleShuffle();
                        if (!queued) p.play(song, played);
                      },
                      builder: (_, on) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.shuffle_rounded, color: on ? K.accent : K.text, size: 17),
                            const SizedBox(width: 6),
                            Text(
                              'Shuffle',
                              style: ts(13, w: FontWeight.w600, c: on ? K.accent : K.text),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Home's line when the server did not answer, with Try again.
class LoadError extends StatelessWidget {
  const LoadError({super.key, this.padding = EdgeInsets.zero});
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    if (lib.error == null) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(lib.error!, style: ts(13, c: K.error)),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: lib.loading ? null : lib.refresh, child: const Text('Try again')),
        ],
      ),
    );
  }
}

/// The thin seek and volume bars. Null [onChanged] shows it disabled.
class ThinBar extends StatelessWidget {
  const ThinBar({super.key, required this.value, required this.onChanged, this.color = K.accent});
  final double value;
  final ValueChanged<double>? onChanged;
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
      disabledActiveTrackColor: color,
      disabledInactiveTrackColor: Colors.white.withValues(alpha: 0.14),
      disabledThumbColor: Colors.transparent,
      thumbColor: Colors.white,
      overlayColor: color.withValues(alpha: 0.2),
    ),
    child: SizedBox(
      height: 20,
      child: Slider(value: value.clamp(0, 1), onChanged: onChanged, padding: const EdgeInsets.symmetric(horizontal: 6)),
    ),
  );
}
