// Lyrics as the apps draw them, with the tuned look (shared/tuning-defaults
// .json): the current line at its tuned height, lines before it smaller,
// dimmer and blurred, the next three stepping back, words filling as they
// are sung. Scrolling by hand pauses the follow for a few seconds and shows
// every line at the browsing look.
import 'dart:async';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:cascade/core/lyrics.dart';
import 'package:cascade/core/lyrics_fetch.dart';
import 'package:cascade/core/tuning_defaults.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/widgets.dart';

/// The shipped style for desktop and for phones (the Apple phone values).
/// ponytail: Flutter reads the desktop and iPhone columns of the shared file;
/// its own column there can come when its tuning first differs.
Map<String, double> styleDesktop = {}, stylePhone = {};

Future<void> loadTuning() async {
  try {
    final json = await rootBundle.loadString('assets/tuning-defaults.json');
    Map<String, double> nums(String platform) => {
      for (final MapEntry(:key, :value) in TuningDefaults(json, platform: platform).section('style').entries)
        if (value is num) key: value.toDouble(),
    };
    styleDesktop = nums('desktop');
    stylePhone = nums('ios');
  } catch (_) {}
}

double _s(Map<String, double> st, String k, double fallback) => st[k] ?? fallback;

/// The song's position now, smoothed between the player's updates.
class _Clock {
  double _pos = 0;
  Duration _at = Duration.zero;
  double now(Player p, Duration elapsed) {
    if (p.position != _pos) {
      _pos = p.position;
      _at = elapsed;
    }
    if (!p.playing) return _pos;
    return _pos + min(1.0, (elapsed - _at).inMicroseconds / 1e6);
  }
}

class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.player, required this.lyrics, this.phone = false, this.size = 34, this.center = false});
  final Player player;
  final Lyrics lyrics;
  final bool phone, center;
  final double size;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _clock = _Clock();
  final _scroll = ScrollController();
  late List<GlobalKey> _keys;
  int _active = -1;
  int _nowTicks = 0;
  bool _browsing = false;
  Timer? _browseEnd;

  Map<String, double> get _st => widget.phone ? stylePhone : styleDesktop;

  @override
  void initState() {
    super.initState();
    _keys = [for (final _ in widget.lyrics.lines) GlobalKey()];
    _ticker = createTicker(_tick)..start();
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      _keys = [for (final _ in widget.lyrics.lines) GlobalKey()];
      _active = -1;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scroll.dispose();
    _browseEnd?.cancel();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final lines = widget.lyrics.lines;
    if (!widget.lyrics.synced) return;
    final delay = _s(_st, 'lyricsDelay', -0.05);
    final now = ((_clock.now(widget.player, elapsed) - delay) * 1e7).round();
    var base = -1;
    for (var i = 0; i < lines.length; i++) {
      if ((lines[i].start ?? 0) <= now) {
        base = i;
      } else {
        break;
      }
    }
    final active = currentLyricIndex(lines, base, now);
    final karaoke = active >= 0 && (lines[active].words?.isNotEmpty ?? false);
    if (active != _active) {
      setState(() {
        _active = active;
        _nowTicks = now;
      });
      if (!_browsing) _follow();
    } else if (karaoke) {
      setState(() => _nowTicks = now);
    }
  }

  void _follow() {
    if (_active < 0 || _active >= _keys.length) return;
    final ctx = _keys[_active].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: _s(_st, 'currentLinePosition', widget.phone ? 0.12 : 0.5),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
    );
  }

  void _userScrolled() {
    setState(() => _browsing = true);
    _browseEnd?.cancel();
    _browseEnd = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _browsing = false);
      _follow();
    });
  }

  /// Opacity and blur for a line [d] lines from the current one.
  (double, double) _look(int d) {
    final st = _st;
    if (!widget.lyrics.synced) return (1, 0);
    if (_browsing) return (d == 0 ? 1 : _s(st, 'browsingOpacity', 0.8), d == 0 ? 0 : _s(st, 'browsingBlur', 2.5));
    if (d == 0) return (1, 0);
    if (d < 0) return (_s(st, 'pastOpacity', 0.3), _s(st, 'pastBlur', 3.5));
    if (d == 1) return (_s(st, 'next1Opacity', 0.15), _s(st, 'next1Blur', 2.5));
    if (d == 2) return (_s(st, 'next2Opacity', 0.11), _s(st, 'next2Blur', 4));
    return (_s(st, 'next3Opacity', 0.1), d == 3 ? _s(st, 'next3Blur', 4) : _s(st, 'farBlur', 6));
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lyrics.lines;
    final fade = Duration(milliseconds: (_s(_st, 'fadeSeconds', 1) * 450).round());
    return LayoutBuilder(
      builder: (context, c) => NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is UserScrollNotification || (n is ScrollUpdateNotification && n.dragDetails != null)) _userScrolled();
          return false;
        },
        child: ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0, 0.08, 0.9, 1],
          ).createShader(r),
          blendMode: BlendMode.dstIn,
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.symmetric(vertical: c.maxHeight * 0.5),
            children: [for (final (i, line) in lines.indexed) KeyedSubtree(key: _keys[i], child: _line(i, line, fade))],
          ),
        ),
      ),
    );
  }

  Widget _line(int i, LyricLine line, Duration fade) {
    final d = _active < 0 ? i + 1 : i - _active;
    final (opacity, blur) = _look(d);
    final current = d == 0 && widget.lyrics.synced;
    final gap = _s(_st, 'lineGap', 8);
    final align = line.opposite ? CrossAxisAlignment.end : (widget.center ? CrossAxisAlignment.center : CrossAxisAlignment.start);
    final style = ds(widget.size, w: FontWeight.w700, h: 1.2);
    Widget text = current && (line.words?.isNotEmpty ?? false)
        ? _karaoke(line.words!, style)
        : Text(line.text, textAlign: line.opposite ? TextAlign.right : (widget.center ? TextAlign.center : TextAlign.left), style: style);
    if (line.background != null && line.background!.isNotEmpty) {
      final bg = style.copyWith(fontSize: widget.size * _s(_st, 'backgroundVocalSize', 0.64), fontWeight: FontWeight.w500);
      text = Column(
        crossAxisAlignment: align,
        children: [
          text,
          Opacity(
            opacity: _s(_st, 'backgroundVocalOpacity', 0.85),
            child: current ? _karaoke(line.background!, bg) : Text(line.background!.map((w) => w.text).join(), style: bg),
          ),
        ],
      );
    }
    final past = d < 0 && widget.lyrics.synced && !_browsing;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: gap),
      child: GestureDetector(
        onTap: line.start == null ? null : () => widget.player.seek(line.start! / 1e7),
        child: MouseRegion(
          cursor: line.start == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: AnimatedOpacity(
            opacity: opacity,
            duration: fade,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: blur),
              duration: fade,
              builder: (_, b, child) => b < 0.2
                  ? child!
                  : ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: b, sigmaY: b),
                      child: child,
                    ),
              child: AnimatedScale(
                scale: past ? _s(_st, 'pastScale', 0.75) : 1,
                alignment: line.opposite ? Alignment.centerRight : (widget.center ? Alignment.center : Alignment.centerLeft),
                duration: fade,
                child: Align(alignment: line.opposite ? Alignment.centerRight : (widget.center ? Alignment.center : Alignment.centerLeft), child: text),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Words light up as they are sung: unsung at the tuned dim, filling to
  /// full across each word's time. ponytail: a word fades as a whole rather
  /// than wiping letter by letter.
  Widget _karaoke(List<LyricWord> words, TextStyle style) {
    final unsung = _s(_st, 'unsungOpacity', 0.29);
    return Text.rich(
      TextSpan(
        children: [
          for (final w in words)
            TextSpan(
              text: w.text,
              style: style.copyWith(
                color: K.foam.withValues(
                  alpha: unsung + (1 - unsung) * (((_nowTicks - w.start) / max(1, (w.end ?? w.start + 3000000) - w.start)).clamp(0.0, 1.0)),
                ),
              ),
            ),
        ],
      ),
      textAlign: widget.center ? TextAlign.center : TextAlign.left,
    );
  }
}
