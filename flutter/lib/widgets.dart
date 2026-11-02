// Tokens and the pieces both layouts share, matching the Figma draft
// (https://www.figma.com/design/5jCQuhu85omAoJsBRC57rs).
import 'package:flutter/material.dart';

import 'data.dart';
import 'player.dart';

/// Desktop colors, from the Electron app's theme plus the redesign's panels.
abstract final class K {
  static const root = Color(0xFF0B0B0C);
  static const panel = Color(0xFF141416);
  static const surface = Color(0xFF1C1C1F);
  static const surface2 = Color(0xFF2A2A2E);
  static const text = Color(0xFFF5F5F7);
  static const text2 = Color(0xFFAEAEB2);
  static const text3 = Color(0xFF8E8E93);
  static const accent = Color(0xFF7CC4FF);
  static const wash = Color(0xFFEF476F);
  static const grad = LinearGradient(colors: [Color(0xFF4ADE80), Color(0xFF7C3AED)], begin: Alignment.topLeft, end: Alignment.bottomRight);
}

/// Android colors: Material 3 dark surfaces seeded from the accent.
abstract final class A {
  static const bg = Color(0xFF101316);
  static const card = Color(0xFF1D2024);
  static const bar = Color(0xFF272A2E);
  static const nav = Color(0xFF1B1E21);
  static const mini = Color(0xFF26292D);
  static const indicator = Color(0xFF24435A);
  static const onIndicator = Color(0xFFCFE5FF);
  static const text = Color(0xFFE2E2E6);
  static const text2 = Color(0xFFC3C7CC);
}

String fmt(num seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String greeting(String name) {
  final h = DateTime.now().hour;
  return '${h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening'}, $name';
}

String today() {
  const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  final d = DateTime.now();
  return '${days[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
}

TextStyle ts(double size, {FontWeight w = FontWeight.w400, Color c = K.text, double? ls}) =>
    TextStyle(fontSize: size, fontWeight: w, color: c, letterSpacing: ls, height: 1.25);

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

class Cover extends StatelessWidget {
  const Cover(this.colors, {super.key, this.size, this.radius = 10, this.shadow = false});
  final List<Color> colors;
  final double? size;
  final double radius;
  final bool shadow;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
          boxShadow: shadow ? const [BoxShadow(color: Color(0x73000000), blurRadius: 18, offset: Offset(0, 6))] : null,
        ),
      );
}

class PlayCircle extends StatelessWidget {
  const PlayCircle({super.key, required this.playing, required this.onTap, this.size = 36});
  final bool playing;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Hover(
        onTap: onTap,
        builder: (_, on) => AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: on ? 0.85 : 1,
          child: Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(shape: BoxShape.circle, gradient: K.grad, boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 14, offset: Offset(0, 4))]),
            child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: size * 0.55),
          ),
        ),
      );
}

/// A Recently played row: the song, then artist and album.
class SongTile extends StatelessWidget {
  const SongTile(this.song, {super.key, this.width, this.queue = recentlyPlayed});
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
        child: Row(children: [
          Stack(alignment: Alignment.center, children: [
            Cover(song.art, size: 48, radius: 0),
            if (on || current)
              Container(
                width: 48,
                height: 48,
                color: const Color(0x66000000),
                child: Icon(current ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 22),
              ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(13, w: FontWeight.w500, c: current ? K.accent : K.text)),
              const SizedBox(height: 1),
              Text('${song.artist} · ${song.album}', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(12, c: K.text3)),
            ]),
          ),
          const SizedBox(width: 12),
        ]),
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
        onTap: () {},
        builder: (_, on) => SizedBox(
          width: width,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AspectRatio(
              aspectRatio: 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [BoxShadow(color: on ? K.accent : Colors.transparent, spreadRadius: 2)],
                ),
                child: Cover(album.art, shadow: true),
              ),
            ),
            const SizedBox(height: 9),
            Text(album.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(13, w: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(album.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(12, c: K.text3)),
          ]),
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
          child: Stack(children: [
            Positioned.fill(child: Cover(video.art, radius: 0)),
            if (video.progress > 0) ...[
              Positioned(left: 0, right: 0, bottom: 0, child: Container(height: 4, color: const Color(0x8C000000))),
              Positioned(left: 0, bottom: 0, child: Container(height: 4, width: width * video.progress, color: accent)),
            ],
          ]),
        ),
      );
}

/// The last played song, big, with Play and Shuffle.
class HeroCard extends StatelessWidget {
  const HeroCard({super.key, required this.compact, required this.base, this.radius = 16});
  final bool compact;
  final Color base;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.read(context);
    final art = compact ? 100.0 : 176.0;
    return Container(
      height: compact ? 132 : 216,
      padding: EdgeInsets.all(compact ? 16 : 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xF2B8452F), const Color(0xD95A2A5E), base],
          stops: const [0, 0.65, 1],
        ),
      ),
      child: Row(children: [
        Cover(reckoner.art, size: art, radius: compact ? 12 : 10, shadow: true),
        SizedBox(width: compact ? 16 : 20),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('LAST PLAYED', style: ts(compact ? 10 : 11, w: FontWeight.w600, c: Colors.white70, ls: 0.7)),
            const SizedBox(height: 4),
            Text(reckoner.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(compact ? 20 : 22, w: FontWeight.w700, c: Colors.white)),
            Text('${reckoner.artist} · ${reckoner.album}', maxLines: compact ? 1 : 2, overflow: TextOverflow.ellipsis, style: ts(compact ? 13 : 14, w: FontWeight.w500, c: Colors.white.withValues(alpha: 0.85))),
            if (!compact) Text('${reckoner.year} · ${fmt(reckoner.seconds)}', style: ts(12, c: Colors.white60)),
            SizedBox(height: compact ? 10 : 14),
            Row(children: [
              Hover(
                onTap: () => p.play(reckoner, const [reckoner, ...recentlyPlayed]),
                builder: (_, on) => Container(
                  padding: const EdgeInsets.fromLTRB(12, 7, 16, 7),
                  decoration: BoxDecoration(gradient: K.grad, borderRadius: BorderRadius.circular(99)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
                    const SizedBox(width: 4),
                    Text('Play', style: ts(13, w: FontWeight.w600, c: Colors.white)),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              Hover(
                onTap: () {
                  if (!p.shuffle) p.toggleShuffle();
                  p.play(reckoner, const [reckoner, ...recentlyPlayed]);
                },
                builder: (_, on) => Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: on ? 0.22 : 0.14), shape: BoxShape.circle),
                  child: const Icon(Icons.shuffle_rounded, color: Colors.white, size: 16),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
