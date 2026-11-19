// Lyrics as the desktop draws them in Now Playing (desktop/renderer.js,
// lyric-karaoke.js, styles/np-overlay.css and karaoke.css), with the tuned
// look (shared/tuning-defaults.json plus the Style menu's changes):
//
// - The sheet moves on one spring (the shared stiffness and damping, stepped
//   in 1/240 s substeps) that puts the current block, the lit line and any
//   earlier line still overlapping it, at currentLinePosition of the panel.
// - Lines take their look by distance from that block: past ones dim, blurred
//   and shrunk, the next three stepping back, the rest hidden. Upcoming lines
//   change a ripple later each, so the stack cascades.
// - Words fill with a soft-edged wipe 0.6em wide, lift a little once reached,
//   and SpicyLyrics' held notes swell and glow letter by letter.
// - The wheel or a drag moves the sheet 1:1 and shows every line; 2.2 s after
//   the last move it springs back. A tap on a line seeks there.
// - Untimed lyrics are a page to read: every line shown, nothing followed.
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:cascade/core/lyric_clock.dart';
import 'package:cascade/core/lyric_style.dart';
import 'package:cascade/core/lyrics.dart';
import 'package:cascade/core/lyrics_fetch.dart';
import 'package:cascade/core/tuning_defaults.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/widgets.dart';

/// The shipped style for desktop and for phones (the Apple phone values).
/// ponytail: Flutter reads the desktop and iPhone columns of the shared file;
/// its own column there can come when its tuning first differs.
Map<String, double> styleDesktop = {}, stylePhone = {};

/// The scroll spring, from the shared file's motion section.
double springStiffness = 250, springDamping = 50;

/// The shipped file, kept for the Style menu's knobs.
String? tuningJson;

Future<void> loadTuning() async {
  try {
    final json = tuningJson = await rootBundle.loadString('assets/tuning-defaults.json');
    Map<String, double> nums(String platform, String section) => {
      for (final MapEntry(:key, :value) in TuningDefaults(json, platform: platform).section(section).entries)
        if (value is num) key: value.toDouble(),
    };
    styleDesktop = nums('desktop', 'style');
    stylePhone = nums('ios', 'style');
    final motion = nums('desktop', 'motion');
    springStiffness = motion['lyricSpringStiffness'] ?? springStiffness;
    springDamping = motion['lyricSpringDamping'] ?? springDamping;
  } catch (_) {}
}

double _s(Map<String, double> st, String k, double fallback) => st[k] ?? fallback;

/// The desktop's lyric line ease, cb(.16,1,.3,1).
const _lineCurve = Cubic(.16, 1, .3, 1);

/// The word lift's ease, cb(.25,.8,.25,1), over 0.6 s.
const _liftCurve = Cubic(.25, .8, .25, 1);

/// The desktop's lyric font: the system's own (SF on a Mac, Segoe UI on
/// Windows, the desktop's sans on Linux) at the Style menu's weight and
/// letter spacing ([st]; 800 and -0.015 em by default).
TextStyle lyricFont(double size, {FontWeight? weight, Color? color, Map<String, double> st = const {}}) => TextStyle(
  inherit: false,
  fontFamily: Platform.isMacOS || Platform.isIOS
      ? '.AppleSystemUIFont'
      : Platform.isWindows
      ? 'Segoe UI'
      : null,
  fontFamilyFallback: const ['Ubuntu', 'Cantarell', 'Noto Sans', 'DejaVu Sans', 'Roboto'],
  fontSize: size,
  fontWeight: weight ?? lyricWeight(st),
  letterSpacing: (st['lyricLetterSpacing'] ?? -0.015) * size,
  height: 1.25,
  color: color ?? K.lyric,
);

/// The lyric weight knob, [less] hundreds lighter (a background vocal's).
/// Windows draws 800 at 700: Segoe UI has no 800 and would jump to Black.
FontWeight lyricWeight(Map<String, double> st, {int less = 0}) {
  var w = (st['lyricWeight'] ?? 800).round();
  if (Platform.isWindows && w == 800) w = 700;
  return FontWeight.values[((w ~/ 100) - 1 - less).clamp(0, 8)];
}

class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.player,
    required this.lyrics,
    this.phone = false,
    this.size,
    this.scale = 1,
    this.center = false,
    this.rollIn = false,
    this.rollBack = false,
  });
  final Player player;
  final Lyrics lyrics;
  final bool phone, center;

  /// The text size; null takes the desktop's, from the window size.
  final double? size;

  /// The Style menu's text size (or plain lyrics size).
  final double scale;

  /// Playback moved on by itself: the sheet rolls up from below instead of
  /// appearing in place.
  final bool rollIn;

  /// Rolls in from above instead (after going back a song).
  final bool rollBack;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _clock = LyricClock();
  final _y = ValueNotifier<double>(0);
  final _now = ValueNotifier<int>(0);
  final _body = GlobalKey();
  late List<GlobalKey> _keys;

  /// The song's instrumental breaks, their dots' keys by the line they come
  /// before, and the break playing now (the dots the sheet centers on).
  late List<Interlude> _breaks;
  final _dotKeys = <int, GlobalKey>{};
  int? _gap;
  double _vel = 0, _panel = 0;
  Duration? _last, _placedAt;

  /// A rolling sheet waits this long for the cover to lead the song change.
  static const _rollDelay = Duration(milliseconds: 100);
  int _active = -1, _first = -1, _scan = 0, _prevNow = 0;
  int? _scrollTo, _scrollFirst;
  bool _browsing = false, _placed = false;
  Timer? _browseEnd;

  Map<String, double> get _st => {...(widget.phone ? stylePhone : styleDesktop), ...widget.player.settings.lyricStyle};
  bool get _synced => widget.lyrics.synced;

  @override
  void initState() {
    super.initState();
    _keys = [for (final _ in widget.lyrics.lines) GlobalKey()];
    _breaks = interludes(widget.lyrics.lines);
    _ticker = createTicker(_tick)..start();
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      _keys = [for (final _ in widget.lyrics.lines) GlobalKey()];
      _breaks = interludes(widget.lyrics.lines);
      _dotKeys.clear();
      _gap = null;
      _active = _first = -1;
      _scan = 0;
      _placed = false;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _browseEnd?.cancel();
    _y.dispose();
    _now.dispose();
    super.dispose();
  }

  /// The last line whose start has passed (line 0 before any has, as the
  /// desktop), scanning on from the last answer.
  int _base(int now) {
    final lines = widget.lyrics.lines;
    var i = _scan;
    if (i > 0 && (lines[i].start ?? 0) > now) i = 0; // seeked back
    var base = i;
    for (; i < lines.length; i++) {
      final s = lines[i].start;
      if (s == null) continue;
      if (s <= now) {
        base = i;
      } else {
        break;
      }
    }
    return _scan = base;
  }

  void _tick(Duration elapsed) {
    final dt = _last == null ? 0.0 : (elapsed - _last!).inMicroseconds / 1e6;
    _last = elapsed;
    final lines = widget.lyrics.lines;
    if (!_synced || lines.isEmpty) return;
    final st = _st;
    // What is heard: the player's clock, less the device's calibrated delay,
    // then the tuned lead.
    final heard = _clock.now(widget.player.position, widget.player.playing, elapsed) - widget.player.settings.audioDelay;
    final now = ((heard - _s(st, 'lyricsDelay', -0.05)) * 1e7).round();
    final seeked = (now - _prevNow).abs() > 20000000;
    _prevNow = now;
    _now.value = now;
    final g = _breaks.where((b) => now >= b.start && now < b.end).firstOrNull?.before;
    if (g != _gap) setState(() => _gap = g);
    var idx = currentLyricIndex(lines, _base(now), now);
    idx = tightScrollTarget(lines, idx, now, (_s(st, 'tightScrollLead', 0.25) * 1e7).round()) ?? idx;
    final first = activeLyricRange(lines, idx, now).$1;
    // Scroll ahead: the scroll alone heads for the line current that much
    // later, if it is past the lit one.
    int? to, toFirst;
    final lead = _s(st, 'scrollLead', 0);
    if (lead > 0) {
      final t = now + (lead * 1e7).round();
      final saved = _scan;
      final ahead = currentLyricIndex(lines, _base(t), t);
      _scan = saved;
      if (ahead > idx) (to, toFirst) = (ahead, activeLyricRange(lines, ahead, t).$1);
    }
    if (idx != _active || first != _first) {
      setState(() {
        _active = idx;
        _first = first;
      });
    }
    _scrollTo = to;
    _scrollFirst = toFirst;
    if (seeked && _placed && !_browsing) _jump();
    _step(dt, elapsed);
  }

  // The spring -------------------------------------------------------------

  double? _top(int i) {
    final col = _body.currentContext?.findRenderObject() as RenderBox?;
    final box = i >= 0 && i < _keys.length ? _keys[i].currentContext?.findRenderObject() as RenderBox? : null;
    if (col == null || box == null || !box.attached || !col.attached) return null;
    return box.localToGlobal(Offset.zero, ancestor: col).dy;
  }

  double _height(int i) => (_keys[i].currentContext?.findRenderObject() as RenderBox?)?.size.height ?? 0;

  /// Where the sheet sits with the current block at its tuned height:
  /// the block's point at that share of its own height lands at that share
  /// of the panel's. Measured each frame, so a background row opening under
  /// a line moves nothing off target.
  double? _target() {
    final pos = _s(_st, 'currentLinePosition', widget.phone ? 0.12 : 0.5);
    // In a break, the dots are what the sheet holds at the tuned height.
    final dots = _gap == null ? null : _dotKeys[_gap]?.currentContext?.findRenderObject() as RenderBox?;
    final col = _body.currentContext?.findRenderObject() as RenderBox?;
    if (dots != null && col != null && dots.attached && col.attached && dots.size.height > 0) {
      final top = dots.localToGlobal(Offset.zero, ancestor: col).dy;
      return _panel * pos - (top + dots.size.height * pos);
    }
    final last = _scrollTo ?? _active, first = _scrollFirst ?? _first;
    if (last < 0) return null;
    final top = _top(first < 0 ? last : first), lastTop = _top(last);
    if (top == null || lastTop == null) return null;
    final bottom = lastTop + _height(last);
    return _panel * pos - (top + (bottom - top) * pos);
  }

  /// The sheet position that centers line [i].
  double _centered(int i) => _panel / 2 - ((_top(i) ?? 0) + _height(i) / 2);

  void _jump() {
    final t = _target();
    if (t == null) return;
    _y.value = t;
    _vel = 0;
  }

  void _step(double dt, Duration elapsed) {
    if (_browsing) return;
    final t = _target();
    if (t == null) return;
    if (!_placed) {
      _placed = true;
      _placedAt = elapsed;
      _y.value = widget.rollIn && !calm(context) ? t + (widget.rollBack ? -0.5 : 0.5) * _panel : t;
      _vel = 0;
      return;
    }
    var pos = _y.value, vel = _vel;
    if (pos == t && vel == 0) return;
    if (widget.rollIn && _placedAt != null && elapsed - _placedAt! < _rollDelay) return;
    // Reduce motion: the sheet steps to each line instead of gliding.
    if (calm(context)) {
      _y.value = t;
      _vel = 0;
      return;
    }
    if (dt > 0.25) {
      // Nothing was drawn for a while: snap rather than replay a stale move.
      pos = t;
      vel = 0;
    } else {
      for (var left = dt; left > 1e-9; left -= 1 / 240) {
        final h = min(1 / 240, left);
        vel += ((t - pos) * springStiffness - vel * springDamping) * h;
        pos += vel * h;
      }
      if ((t - pos).abs() < 0.05 && vel.abs() < 0.05) {
        pos = t;
        vel = 0;
      }
    }
    _vel = vel;
    _y.value = pos;
  }

  /// The wheel or a drag: the sheet follows 1:1, between the first and the
  /// last line centered, and every line shows until it springs back.
  void _browse(double dy) {
    if (!_placed || widget.lyrics.lines.isEmpty) return;
    final a = _centered(widget.lyrics.lines.length - 1), b = _centered(0);
    _y.value = (_y.value - dy).clamp(min(a, b), max(a, b));
    _vel = 0;
    if (!_browsing) setState(() => _browsing = true);
    _browseEnd?.cancel();
    _browseEnd = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _browsing = false);
    });
  }

  // Drawing ----------------------------------------------------------------

  /// The desktop's size, clamp(22, min(3vw, 5.5vh), 50), or the plain
  /// lyrics' clamp(22, 3vw, 50); then the Style menu's scale.
  double _fontSize(Size win) {
    final base = widget.size ?? (_synced ? min(win.width * 0.03, win.height * 0.055) : win.width * 0.03).clamp(22.0, 50.0);
    return base * widget.scale;
  }

  @override
  Widget build(BuildContext context) {
    final win = MediaQuery.sizeOf(context);
    final fs = _fontSize(win);
    if (!_synced) return _plain(fs, win);
    final st = _st;
    final lines = widget.lyrics.lines;
    final emphasis = widget.lyrics.credit != null;
    return LayoutBuilder(
      builder: (context, c) {
        _panel = c.maxHeight;
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              GestureBinding.instance.pointerSignalResolver.register(e, (_) => _browse(e.scrollDelta.dy));
            }
          },
          onPointerPanZoomUpdate: (e) => _browse(-e.localPanDelta.dy),
          child: GestureDetector(
            onVerticalDragUpdate: (d) => _browse(-d.delta.dy),
            child: ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
                stops: [0, 0.08, 0.9, 1],
              ).createShader(r),
              blendMode: BlendMode.dstIn,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: ValueListenableBuilder<double>(
                      valueListenable: _y,
                      builder: (_, y, child) => Transform.translate(offset: Offset(0, y), child: child),
                      child: Column(
                        key: _body,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, line) in lines.indexed) ...[
                            for (final b in _breaks.where((b) => b.before == i))
                              _Dots(
                                key: _dotKeys.putIfAbsent(i, GlobalKey.new),
                                start: b.start,
                                end: b.end,
                                now: _now,
                                size: fs,
                                align: widget.center ? Alignment.center : Alignment.centerLeft,
                                inset: widget.phone ? 0 : (c.maxWidth * 0.04).clamp(28.0, 56.0),
                              ),
                            _line(i, line, fs, c.maxWidth, st, emphasis),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _line(int i, LyricLine line, double fs, double width, Map<String, double> st, bool emphasis) {
    // Signed distance from the current block: past below 0, upcoming above.
    final d = _active < 0
        ? i + 1
        : i < _first
        ? i - _first
        : i > _active
        ? i - _active
        : 0;
    final (double o, double b, double sc) = _browsing
        ? (d == 0 ? (1.0, 0.0, 1.0) : (_s(st, 'browsingOpacity', 0.8), _s(st, 'browsingBlur', 2.5), 1.0))
        : d == 0
        ? (1.0, 0.0, 1.0)
        : d < 0
        ? (_s(st, 'pastOpacity', 0.3), _s(st, 'pastBlur', 3.5), _s(st, 'pastScale', 0.75))
        : d == 1
        ? (_s(st, 'next1Opacity', 0.15), _s(st, 'next1Blur', 2.5), 1.0)
        : d == 2
        ? (_s(st, 'next2Opacity', 0.11), _s(st, 'next2Blur', 4), 1.0)
        : d == 3
        ? (_s(st, 'next3Opacity', 0.1), _s(st, 'next3Blur', 4), 1.0)
        : (0.0, _s(st, 'farBlur', 6), 1.0);
    final ripple = !_browsing && d > 0 && !calm(context) ? min(d, 3) * _s(st, 'rippleSeconds', 0.04) : 0.0;
    final active = d == 0;
    final align = line.opposite
        ? Alignment.centerRight
        : widget.center
        ? Alignment.center
        : Alignment.centerLeft;
    final wrap = line.opposite
        ? WrapAlignment.end
        : widget.center
        ? WrapAlignment.center
        : WrapAlignment.start;
    final style = lyricFont(fs, st: st);
    Widget text = line.words?.isNotEmpty ?? false
        ? _Karaoke(words: line.words!, style: style, align: wrap, active: active, now: _now, st: st, emphasis: emphasis)
        : Text(line.text, textAlign: line.opposite ? TextAlign.right : (widget.center ? TextAlign.center : TextAlign.left), style: style);
    if (line.background?.isNotEmpty ?? false) {
      final bg = lyricFont(fs * _s(st, 'backgroundVocalSize', 0.64), weight: lyricWeight(st, less: 2), st: st);
      text = Column(
        crossAxisAlignment: line.opposite
            ? CrossAxisAlignment.end
            : widget.center
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          text,
          // Background vocals open under the line only while it is current,
          // growing and fading together over 0.4 s (and closing the same
          // way), always laid out so nothing pops in or vanishes.
          TweenAnimationBuilder<double>(
            tween: Tween(end: active ? 1 : 0),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
            builder: (_, v, child) => ClipRect(
              child: Align(
                // Lined up with its line, not centered under it.
                alignment: line.opposite
                    ? Alignment.topRight
                    : widget.center
                    ? Alignment.topCenter
                    : Alignment.topLeft,
                heightFactor: v,
                child: Opacity(opacity: v * _s(st, 'backgroundVocalOpacity', 0.85), child: child),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.only(top: 0.3 * fs),
              child: _Karaoke(words: line.background!, style: bg, align: wrap, active: active, now: _now, st: st, emphasis: emphasis),
            ),
          ),
        ],
      );
    }
    final pad = (width * 0.04).clamp(28.0, 56.0);
    return Padding(
      key: _keys[i],
      padding: EdgeInsets.symmetric(vertical: _s(st, 'lineGap', 8) / 2),
      child: Align(
        alignment: align,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: min(900, width * 0.92)),
          child: MouseRegion(
            cursor: line.start == null ? MouseCursor.defer : SystemMouseCursors.click,
            child: GestureDetector(
              onTap: line.start == null ? null : () => widget.player.seek(line.start! / 1e7),
              child: _Look(
                opacity: o,
                blur: b,
                scale: sc,
                delay: Duration(microseconds: (ripple * 1e6).round()),
                duration: Duration(milliseconds: (_s(st, 'fadeSeconds', 1) * 1000).round()),
                origin: line.opposite ? Alignment.centerRight : (widget.center ? Alignment.center : Alignment.centerLeft),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: widget.phone ? 0 : pad),
                  child: text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Untimed lyrics: a page, every line at 0.92, scrolled like any page.
  Widget _plain(double fs, Size win) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(widget.phone ? 0 : (win.width * 0.04).clamp(28.0, 56.0), 40, 0, 120),
      child: Column(
        crossAxisAlignment: widget.center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          for (final line in widget.lyrics.lines)
            Padding(
              padding: EdgeInsets.symmetric(vertical: _s(_st, 'lineGap', 8) / 2),
              child: Opacity(
                opacity: 0.92,
                child: Text(
                  line.text,
                  textAlign: widget.center ? TextAlign.center : TextAlign.left,
                  style: lyricFont(fs, st: _st),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// The waiting dots of an instrumental break, as Apple Music shows them: they
/// open as the break starts, fill one by one across it while breathing a
/// little, and fold away as the next line comes. Closed, they take no room.
class _Dots extends StatelessWidget {
  const _Dots({super.key, required this.start, required this.end, required this.now, required this.size, required this.align, required this.inset});
  final int start, end;
  final ValueListenable<int> now;
  final double size, inset;
  final Alignment align;

  // Opening and folding take 0.4 s at each end of the break.
  static const _edge = 4000000;

  @override
  Widget build(BuildContext context) {
    final still = calm(context);
    return ValueListenableBuilder<int>(
      valueListenable: now,
      builder: (context, t, _) {
        final open = Curves.easeInOut.transform(min(((t - start) / _edge).clamp(0.0, 1.0), ((end - t) / _edge).clamp(0.0, 1.0)));
        if (open <= 0) return const SizedBox.shrink();
        final p = ((t - start) / (end - start)).clamp(0.0, 1.0);
        final dot = size * 0.32;
        final breathe = still ? 1.0 : 1 + 0.08 * sin(t / 1e7 * 2 * pi / 1.6);
        return SizedBox(
          height: size * 1.4 * open,
          child: Align(
            alignment: align,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: Opacity(
                opacity: open,
                child: Transform.scale(
                  scale: breathe * (0.6 + 0.4 * open),
                  alignment: align,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: dot * 0.7,
                    children: [
                      for (var k = 0; k < 3; k++)
                        Container(
                          width: dot,
                          height: dot,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: K.lyric.withValues(alpha: 0.25 + 0.75 * (p * 3 - k).clamp(0.0, 1.0)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A line's look (opacity, blur, scale), changing over the tuned fade with
/// the desktop's ease, after [delay] (the ripple).
class _Look extends StatefulWidget {
  const _Look({
    required this.opacity,
    required this.blur,
    required this.scale,
    required this.delay,
    required this.duration,
    required this.origin,
    required this.child,
  });
  final double opacity, blur, scale;
  final Duration delay, duration;
  final Alignment origin;
  final Widget child;

  @override
  State<_Look> createState() => _LookState();
}

class _LookState extends State<_Look> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.duration, value: 1);
  late (double, double, double) _from = (widget.opacity, widget.blur, widget.scale), _to = _from;
  Timer? _wait;

  (double, double, double) get _now {
    final t = _lineCurve.transform(_c.value);
    double l(double a, double b) => a + (b - a) * t;
    return (l(_from.$1, _to.$1), l(_from.$2, _to.$2), l(_from.$3, _to.$3));
  }

  @override
  void didUpdateWidget(_Look old) {
    super.didUpdateWidget(old);
    final next = (widget.opacity, widget.blur, widget.scale);
    if (next == _to) return;
    _wait?.cancel();
    void go() {
      _from = _now;
      _to = next;
      _c.duration = widget.duration;
      _c.forward(from: 0);
    }

    if (widget.delay == Duration.zero) {
      go();
    } else {
      _wait = Timer(widget.delay, () => mounted ? go() : null);
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, child) {
      // The same widgets every frame (blur switched off, not removed): a
      // change of shape would rebuild the line and restart its animations.
      final (o, b, s) = _now;
      return Opacity(
        opacity: o.clamp(0.0, 1.0),
        child: ImageFiltered(
          enabled: b >= 0.2,
          imageFilter: ImageFilter.blur(sigmaX: b, sigmaY: b),
          child: Transform.scale(scale: s, alignment: widget.origin, child: child),
        ),
      );
    },
    child: widget.child,
  );
}

// Karaoke ---------------------------------------------------------------------

/// Scripts written without spaces between words: their syllables wrap as
/// the script does instead of being held together.
final _noSpaceScript = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}]',
  unicode: true,
);

/// A karaoke line's words: each whole word (its syllables up to a trailing
/// space) kept on one line, a held word filled and swollen as one.
class _Karaoke extends StatelessWidget {
  const _Karaoke({
    required this.words,
    required this.style,
    required this.align,
    required this.active,
    required this.now,
    required this.st,
    required this.emphasis,
  });
  final List<LyricWord> words;
  final TextStyle style;
  final WrapAlignment align;
  final bool active, emphasis;
  final ValueNotifier<int> now;
  final Map<String, double> st;

  /// Groups of pieces, and whether a space follows each group.
  List<(List<(LyricWord, bool)>, bool)> _groups() {
    final out = <(List<(LyricWord, bool)>, bool)>[];
    var syls = <LyricWord>[];
    void close(bool space) {
      if (syls.isEmpty) return;
      final whole = LyricWord(syls.first.start, syls.last.end, syls.map((w) => w.text).join().trimRight());
      final held = emphasis && syls.length > 1 && syls.any(isEmphasisWord) && isEmphasisWord(whole);
      final pieces = held ? [(whole, true)] : [for (final w in syls) (LyricWord(w.start, w.end, w.text.trimRight()), emphasis && isEmphasisWord(w))];
      final wordLike = !_noSpaceScript.hasMatch(whole.text) && whole.text.characters.length <= 30;
      if (wordLike) {
        out.add((pieces, space));
      } else {
        for (final (j, p) in pieces.indexed) {
          out.add(([p], space && j == pieces.length - 1));
        }
      }
      syls = [];
    }

    for (final w in words) {
      syls.add(w);
      if (RegExp(r'\s$').hasMatch(w.text)) close(true);
    }
    close(false);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final space = (TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: TextDirection.ltr,
    )..layout()).width;
    final groups = _groups();
    // Becoming current, the words ease from plain white to the unsung dim
    // over 0.35 s; switched at once, the line blinked darker as it lit.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: active ? 1 : 0),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      builder: (context, lit, _) {
        Widget line(Widget Function((LyricWord, bool) p) piece) => Wrap(
          alignment: align,
          children: [
            for (final (pieces, gap) in groups)
              Padding(
                padding: EdgeInsets.only(right: gap ? space : 0),
                child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [for (final p in pieces) piece(p)]),
              ),
          ],
        );
        // Not current: the same layout, so the line keeps its wrap.
        if (!active) return line((p) => p.$2 ? _Held(word: p.$1, style: style, st: st) : Text(p.$1.text, style: style));
        // Current: two layers of solid text. See-through text draws each
        // letter on its own, and the tight spacing overlaps bold letters, so
        // overlaps came out brighter (seams, a line that looked bold). The dim
        // base is the whole line solid and made see-through once; the lit
        // layer above holds what has been sung and the word filling.
        final unsung = 1 - (1 - _s(st, 'unsungOpacity', 0.29)) * lit;
        return ValueListenableBuilder<int>(
          valueListenable: now,
          builder: (_, n, _) => Stack(
            children: [
              Opacity(
                opacity: unsung,
                child: line(
                  (p) => p.$2
                      ? Opacity(
                          opacity: 0,
                          child: _Held(word: p.$1, style: style, st: st),
                        )
                      : _Word(word: p.$1, style: style, now: n, st: st),
                ),
              ),
              line((p) => p.$2 ? _Held(word: p.$1, style: style, now: n, st: st, lit: lit) : _Word(word: p.$1, style: style, now: n, st: st, top: true)),
            ],
          ),
        );
      },
    );
  }
}

/// How far the fill is through [w] at [now], 0 to 1.
double _progress(LyricWord w, int now) {
  if (now < w.start) return 0;
  final end = w.end;
  if (end == null || now >= end) return 1;
  return (now - w.start) / max(1, end - w.start);
}

/// The fill's gradient over a box [width] wide in text [fs] tall: white to
/// the unsung dim with a 0.6em soft edge, its middle sliding from 0.3em
/// before the start to 0.3em past the end as [t] goes 0 to 1.
Shader _fill(Rect r, double t, double fs, double unsung) {
  final mid = t * r.width + (t * 0.6 - 0.3) * fs;
  final a = ((mid - 0.3 * fs) / r.width).clamp(0.0, 1.0), b = ((mid + 0.3 * fs) / r.width).clamp(0.0, 1.0);
  return LinearGradient(
    colors: [
      K.lyric,
      K.lyric,
      K.lyric.withValues(alpha: unsung),
      K.lyric.withValues(alpha: unsung),
    ],
    stops: [0, a, max(a, b), 1],
  ).createShader(r);
}

/// Widths of measured words, for the fill's gradient. Kept small: only the
/// lines on screen ask.
final _widths = <(String, double, FontWeight?, double?), double>{};

double _width(String text, TextStyle style) {
  final key = (text, style.fontSize!, style.fontWeight, style.letterSpacing);
  final known = _widths[key];
  if (known != null) return known;
  if (_widths.length > 400) _widths.clear();
  return _widths[key] = (TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout()).width;
}

/// [text] filled to [t]. The gradient is the glyphs' own paint, not a mask
/// over the word's box: the tight letter spacing lets the last letter's ink
/// run past that box, and a mask left that sliver plain white (the bright
/// edge at the end of a filling word).
Widget _filled(String text, TextStyle style, double t, double unsung) {
  if (t <= 0) {
    return Text(
      text,
      style: style.copyWith(color: K.lyric.withValues(alpha: unsung)),
    );
  }
  if (t >= 1) return Text(text, style: style);
  final fs = style.fontSize!;
  final box = Rect.fromLTWH(0, 0, _width(text, style), fs * (style.height ?? 1.25));
  return Text(
    text,
    style: TextStyle(
      inherit: false,
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      fontSize: fs,
      fontWeight: style.fontWeight,
      letterSpacing: style.letterSpacing,
      height: style.height,
      shadows: style.shadows,
      foreground: Paint()..shader = _fill(box, t, fs, unsung),
    ),
  );
}

/// One word of the current line: filling, and lifted a little once reached.
class _Word extends StatelessWidget {
  const _Word({required this.word, required this.style, required this.now, required this.st, this.top = false});
  final LyricWord word;
  final TextStyle style;
  final int now;
  final Map<String, double> st;

  /// The lit layer (sung, or the filling part) rather than the dim base,
  /// which is always the whole word in solid text.
  final bool top;

  @override
  Widget build(BuildContext context) {
    final since = (now - word.start) / 1e7;
    final lift = since < 0 || calm(context) ? 0.0 : _s(st, 'wordLift', 0.04) * style.fontSize! * _liftCurve.transform((since / 0.6).clamp(0.0, 1.0));
    final t = _progress(word, now);
    final text = Text(word.text, style: style);
    final Widget drawn = !top || t >= 1
        ? text
        // Not reached: nothing on the lit layer, the same size.
        : t <= 0
        ? Opacity(opacity: 0, child: text)
        // Filling: the solid word, shown up to the soft edge. Clipped to the
        // word's box: the last letter's ink overhangs it, and a mask leaves
        // what is outside its box untouched (that sliver showed full white).
        : ClipRect(
            child: ShaderMask(blendMode: BlendMode.dstIn, shaderCallback: (r) => _fillMask(r, t, style.fontSize!), child: text),
          );
    return Transform.translate(offset: Offset(0, -lift), child: drawn);
  }
}

/// The lit layer's mask over a filling word: solid up to the soft edge, then
/// clear, the edge sliding as _fill's does.
Shader _fillMask(Rect r, double t, double fs) {
  final mid = t * r.width + (t * 0.6 - 0.3) * fs;
  final a = ((mid - 0.3 * fs) / r.width).clamp(0.0, 1.0), b = ((mid + 0.3 * fs) / r.width).clamp(0.0, 1.0);
  return LinearGradient(colors: const [Colors.white, Colors.white, Color(0x00FFFFFF), Color(0x00FFFFFF)], stops: [0, a, max(a, b), 1]).createShader(r);
}

/// A held note (SpicyLyrics): each letter takes its share of the fill and
/// swells, rises and glows from when the fill reaches it, by heldSwell.
class _Held extends StatelessWidget {
  const _Held({required this.word, required this.style, this.now, required this.st, this.lit = 1});
  final LyricWord word;
  final TextStyle style;
  final double lit;

  /// Null when its line is not current: drawn plain, at the same size.
  final int? now;
  final Map<String, double> st;

  @override
  Widget build(BuildContext context) {
    final letters = word.text.characters.toList();
    final n = letters.length;
    final now = this.now;
    final prog = now == null ? 1.0 : _progress(word, now);
    final start = word.start / 1e7;
    final held = max(0.0, (word.end ?? word.start) / 1e7 - start);
    final t = (now ?? 0) / 1e7;
    final fs = style.fontSize!;
    final unsung = 1 - (1 - _s(st, 'unsungOpacity', 0.29)) * lit;
    final lift = _s(st, 'heldLift', 0.16), grow = _s(st, 'heldScale', 1.19);
    final swellStyle = {'heldFullSeconds': 1.4, 'heldMinStrength': 0.45, 'heldSettleSeconds': 0.4, ...styleDesktop, ...st};
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 0.06 * fs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < n; i++)
            Builder(
              builder: (_) {
                final share = (prog * n - i).clamp(0.0, 1.0);
                final litAt = start + held * i / n;
                final s = now == null || calm(context) ? 0.0 : heldSwell(t - litAt, start + held - litAt, held, swellStyle);
                final glow = s > 0.01
                    ? style.copyWith(
                        shadows: [
                          Shadow(
                            color: (K.dark ? Colors.white : K.accent).withValues(alpha: (K.dark ? 0.7 : 0.35) * s),
                            blurRadius: 0.35 * fs * s,
                          ),
                        ],
                      )
                    : style;
                return Transform.translate(
                  offset: Offset(0, -lift * fs * s),
                  child: Transform.scale(scale: 1 + (grow - 1) * s, child: _filled(letters[i], glow, share, unsung)),
                );
              },
            ),
        ],
      ),
    );
  }
}
