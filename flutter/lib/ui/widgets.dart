// Tokens and the pieces both layouts share, matching the Figma draft
// (https://www.figma.com/design/5jCQuhu85omAoJsBRC57rs).
import 'dart:async';
import 'dart:io';

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/glass_button.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';

/// One theme's colors. Personality v1 (the Penpot file "Cascade
/// Personality v1", shared with the Swift app) for dark; light takes the
/// desktop's light neutrals (styles/theme.css) with the Personality blue
/// deepened to read on white.
class Palette {
  const Palette({
    required this.dark,
    required this.root,
    required this.panel,
    required this.surface,
    required this.surface2,
    required this.line,
    required this.text,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.accentTint,
    required this.accentDeep,
    required this.ink,
    required this.foam,
    required this.glass,
    required this.like,
    required this.error,
    required this.wash,
  });
  final bool dark;
  final Color root, panel, surface, surface2, line, text, text2, text3, accent, accentTint, accentDeep, ink, foam, glass, like, error;
  final LinearGradient wash;
}

const darkPalette = Palette(
  dark: true,
  root: Color(0xFF0A0E13), // bg
  panel: Color(0xFF111821), // surface
  surface: Color(0xFF18222E), // surface-2
  surface2: Color(0xFF223041), // hover, a step above surface-2
  line: Color(0x14FFFFFF), // white at 8%
  text: Color(0xFFEEF3F8),
  text2: Color(0xFFA7B4C4),
  text3: Color(0xFF8A99AB), // 4.6:1 on surface-2 hover, 6.7:1 on bg
  accent: Color(0xFF7CC4FF),
  accentTint: Color(0x247CC4FF), // accent at 14%
  accentDeep: Color(0xFF2B6CB0),
  ink: Color(0xFF06121F), // text on accent
  foam: Color(0xFFD7EEFF),
  glass: Color(0xEB18222E), // surface-2 at 92%
  like: Color(0xFFFF6B8A),
  error: Color(0xFFFF453A),
  wash: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x612B6CB0), Color(0x002B6CB0)], stops: [0, 0.38]),
);

// Every text color here is at least 4.5:1 on root, panel and surface2.
const lightPalette = Palette(
  dark: false,
  root: Color(0xFFF2F2F7),
  panel: Color(0xFFFFFFFF),
  surface: Color(0xFFFFFFFF),
  surface2: Color(0xFFE8E8ED),
  line: Color(0x1A000000), // black at 10%
  text: Color(0xFF1C1C1E),
  text2: Color(0xFF48484A),
  text3: Color(0xFF636366),
  accent: Color(0xFF2B6CB0), // 4.9:1 on root; white on it 5.4:1
  accentTint: Color(0x242B6CB0),
  accentDeep: Color(0xFF1E4F86),
  ink: Color(0xFFFFFFFF),
  foam: Color(0xFF3A7FC6),
  glass: Color(0xEBFFFFFF),
  like: Color(0xFFC2255C),
  error: Color(0xFFD70015),
  wash: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x2E2B6CB0), Color(0x002B6CB0)], stops: [0, 0.38]),
);

/// The colors in use, by name; [current] switches the theme (see
/// [rebuildAll]).
abstract final class K {
  static Palette current = darkPalette;
  static bool get dark => current.dark;
  static Color get root => current.root;
  static Color get panel => current.panel;
  static Color get surface => current.surface;
  static Color get surface2 => current.surface2;
  static Color get line => current.line;
  static Color get text => current.text;
  static Color get text2 => current.text2;
  static Color get text3 => current.text3;
  static Color get accent => current.accent;
  static Color get accentTint => current.accentTint;
  static Color get accentDeep => current.accentDeep;
  static Color get ink => current.ink;
  static Color get foam => current.foam;
  static Color get glass => current.glass;
  static Color get like => current.like;
  static Color get error => current.error;

  /// The blue wash at the top of every page.
  static LinearGradient get wash => current.wash;

  /// Over album art (and the dark scrims on it): white in both themes.
  static const onArt = Colors.white;

  /// For washes and hairlines over the theme's surfaces: white on dark,
  /// black on light (used at low alpha).
  static Color get tint => dark ? Colors.white : Colors.black;

  /// The lyrics' ink: white on dark, the text color on light.
  static Color get lyric => dark ? Colors.white : current.text;
}

/// Rebuild every widget, so a theme change reaches all of them in place,
/// without losing where you are (pages, Now Playing, scroll positions).
void rebuildAll() {
  void mark(Element e) {
    e.markNeedsBuild();
    e.visitChildren(mark);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(mark);
}

abstract final class A {
  static Color get bg => K.root;
  static Color get card => K.panel;
  static Color get bar => K.glass;
  static Color get nav => K.panel;
  static Color get mini => K.glass;
  static Color get indicator => K.accentTint;
  static Color get onIndicator => K.text;
  static Color get text => K.text;
  static Color get text2 => K.text2;
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
/// Body text (Inter). [tab]: fixed-width digits, for numbers that change in
/// place (times, percentages), so they do not shuffle about as they tick.
TextStyle ts(double size, {FontWeight w = FontWeight.w400, Color? c, double? ls, double h = 1.25, bool tab = false}) => TextStyle(
  fontFamily: 'Inter',
  fontSize: size,
  fontWeight: w,
  color: c ?? K.text,
  letterSpacing: ls,
  height: h,
  fontFeatures: tab ? const [FontFeature.tabularFigures()] : null,
);

/// Display text (font.display, Hanken Grotesk): headings, titles, lyrics.
TextStyle ds(double size, {FontWeight w = FontWeight.w600, Color? c, bool italic = false, double h = 1.15}) => TextStyle(
  fontFamily: 'Hanken Grotesk',
  fontSize: size,
  fontWeight: w,
  fontStyle: italic ? FontStyle.italic : FontStyle.normal,
  color: c ?? K.text,
  height: h,
);

/// The type tokens (Penpot set "Cascade").
abstract final class Txt {
  static TextStyle hero([Color? c]) => ds(44, c: c ?? K.text, h: 1.05);
  static TextStyle title([Color? c]) => ds(30, c: c ?? K.text, h: 1.1);
  static TextStyle section([Color? c]) => ds(21, c: c ?? K.text, h: 1.2);
  static TextStyle voice([Color? c]) => ds(17, w: FontWeight.w400, c: c ?? K.text2, italic: true, h: 1.3);
  static TextStyle brand([Color? c]) => ds(17, c: c ?? K.text, h: 1.2);
  static TextStyle caps([Color? c]) => ts(11, w: FontWeight.w600, c: c ?? K.text3, ls: 0.88, h: 1.2);
}

/// The app's motion lengths, so things move in one rhythm: [fast] for hover
/// and press, [base] for toggles and small fades, [slow] for panes, pages
/// and panels, [long] for the big moves (Now Playing, the Style menu).
/// Exits take the next length down. Effects tuned to the desktop's own
/// timings (the glass buttons, the lyrics, the cover change) keep theirs.
abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 320);
  static const long = Duration(milliseconds: 450);

  /// Every dropdown and popup menu: quicker than Material's 300 ms, whose
  /// items also fade in one after another, which read as slow.
  static const menu = AnimationStyle(duration: Duration(milliseconds: 130), reverseDuration: Duration(milliseconds: 90));
}

/// Motion kept to fades and cuts: the system's reduce motion setting, unless
/// the Style menu's Reduce motion says otherwise.
bool calm(BuildContext context) => switch (PlayerScope.maybeRead(context)?.settings.reduceMotion) {
  'on' => true,
  'off' => false,
  _ => MediaQuery.maybeDisableAnimationsOf(context) ?? false,
};

/// Enter and Space press the focused control, before the window's own
/// Space (play and pause) sees them.
const activateKeys = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
};

/// The ring around the control that has keyboard focus (shown only while
/// moving by keyboard, never on a click).
Widget focusRing(Widget child, {required bool on, double radius = 8}) => on
    ? DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: K.accent, width: 2),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      )
    : child;

/// The base of the app's own buttons and rows: a pointer cursor and hover
/// state with the mouse, and with the keyboard a place in the Tab order,
/// Enter or Space to press, and a focus ring (which also lights the hover
/// look). Screen readers hear a button. Without [onTap] it is inert.
class Hover extends StatefulWidget {
  const Hover({super.key, required this.builder, this.onTap, this.label, this.radius = 8});
  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;

  /// What a screen reader says, when the control shows no text of its own.
  final String? label;

  /// The focus ring's corner radius, to follow the control's shape.
  final double radius;

  @override
  State<Hover> createState() => _HoverState();
}

class _HoverState extends State<Hover> {
  bool _hover = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return Semantics(
      button: on,
      enabled: on,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: on,
        mouseCursor: on ? SystemMouseCursors.click : MouseCursor.defer,
        shortcuts: activateKeys,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: focusRing(widget.builder(context, _hover || _focus), on: _focus, radius: widget.radius),
        ),
      ),
    );
  }
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
            // A small cover is decoded at the size it shows, not the 300 px
            // the server sends: a list of rows decodes far less.
            cacheWidth: size == null || size! >= 150 ? null : (size! * MediaQuery.devicePixelRatioOf(context)).ceil(),
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
  Widget build(BuildContext context) => Hover(
    onTap: onTap,
    label: playing ? 'Pause' : 'Play',
    radius: size / 2,
    builder: (_, on) => AnimatedContainer(
      duration: Motion.fast,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? K.accent.withValues(alpha: 0.85) : K.accent,
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: K.ink, size: size * 0.55),
    ),
  );
}

/// The accent pill button: Play, Resume, Save. Not primary: a quiet one.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.icon, required this.onTap, this.primary = true, this.danger = false});
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;

  /// Something hard to undo (Sign out): red text.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final fg = onTap == null ? K.text3 : (primary ? K.ink : (danger ? K.error : K.text));
    return Hover(
      onTap: onTap,
      radius: 99,
      builder: (_, on) => AnimatedContainer(
        duration: Motion.fast,
        padding: EdgeInsets.fromLTRB(icon == null ? 16 : 12, 8, 16, 8),
        decoration: BoxDecoration(
          color: onTap == null
              ? K.surface
              : primary
              ? (on ? K.foam : K.accent)
              : (on ? K.surface2 : K.surface),
          borderRadius: BorderRadius.circular(99),
          // A quiet one gets an edge, or on light it is a white pill on a white card.
          border: primary || onTap == null ? null : Border.all(color: K.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, color: fg, size: 17), const SizedBox(width: 6)],
            // Squeezed (a narrow panel), the label shortens rather than overflows.
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts(13, w: FontWeight.w600, c: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The stepped art stack: the current art with what comes next falling in
/// behind it, or the art alone (setting off, or nothing next).
class ArtStack extends StatefulWidget {
  const ArtStack(this.song, {super.key, this.next = const [], required this.size, this.soft = false});
  final Song song;
  final List<Song> next;
  final double size;

  /// The phone's: the covers behind peek less and are fainter, so the art
  /// stands centered on its own.
  final bool soft;

  @override
  State<ArtStack> createState() => _ArtStackState();
}

/// The cover changes to the next song by the Style menu's cover animation:
/// 'swipe' (shown as Toss) tosses the cover off to the left with a slight
/// tilt while the next one springs up from behind; going back plays it in
/// reverse. 'push' slides them across, 'fade' crossfades, 'none' cuts.
/// The toss's tilt (5 degrees), travel (0.55 of the cover) and spring
/// bounce were tuned by eye in a side-by-side mock-up, 2026-11-06.
const _tossTilt = 5 * pi / 180, _tossTravel = 0.55, _tossBounce = 0.09;

/// Held through a crossfade, the toss stops with the old cover this far
/// along (of the cover's width) and fully tilted, the next one up behind it
/// with its right side and top corner showing.
const _holdShift = 0.12;

class _ArtStackState extends State<ArtStack> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, value: 1)..addListener(() => setState(() {}));
  Song? _from;
  bool _back = false;

  /// A crossfade is carrying this change: the toss goes partway (the next
  /// cover showing behind the old one), holds while the crossfade lasts, a
  /// pause included, and finishes as it ends.
  bool _held = false;
  Timer? _finish;
  Player? _xf; // listened to while held
  bool? _timedPlaying; // the play state _finish was timed for
  Duration _half = Duration.zero;

  static bool _same(Song a, Song b) => a.id.isNotEmpty ? a.id == b.id : a.title == b.title;

  @override
  void didUpdateWidget(ArtStack old) {
    super.didUpdateWidget(old);
    if (_same(old.song, widget.song)) return;
    final s = PlayerScope.read(context).settings;
    if (s.coverAnim == 'none') {
      _from = null;
      _c.value = 1;
      return;
    }
    _from = old.song;
    // Back: the song we left is next again.
    _back = widget.next.isNotEmpty && _same(widget.next.first, old.song) && !(old.next.isNotEmpty && _same(old.next.first, widget.song));
    final full = Duration(milliseconds: (s.coverAnimSeconds * 1000).round());
    _unhold();
    final player = PlayerScope.read(context);
    final left = player.crossfadeLeft;
    _held = !_back && left != null && left > const Duration(milliseconds: 300) && !calm(context);
    if (!_held) {
      _c.duration = full;
      _c.forward(from: 0);
      return;
    }
    // Each half takes half the animation, or half the crossfade if shorter;
    // the second ends as the crossfade does.
    _half = Duration(microseconds: min(full.inMicroseconds, left!.inMicroseconds) ~/ 2);
    _c.value = 0;
    _c.animateTo(0.5, duration: _half);
    _xf = player..addListener(_schedule);
    _timedPlaying = null;
    _schedule();
  }

  /// Times the second half to end with the crossfade, again when play or
  /// pause changes: paused, it waits; the fade over or cut short, it goes.
  void _schedule() {
    final p = _xf;
    if (p == null) return;
    final left = p.crossfadeLeft;
    if (left == null) return _release();
    if (p.playing == _timedPlaying) return;
    _timedPlaying = p.playing;
    _finish?.cancel();
    if (!p.playing) return;
    final wait = left - _half;
    _finish = Timer(wait.isNegative ? Duration.zero : wait, _release);
  }

  void _release() {
    _unhold();
    if (mounted && _c.value < 1) _c.animateTo(1, duration: _half);
  }

  void _unhold() {
    _finish?.cancel();
    _xf?.removeListener(_schedule);
    _xf = null;
  }

  @override
  void dispose() {
    _unhold();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = PlayerScope.read(context).settings;
    final behind = settings.showArtStack ? widget.next.take(3).toList() : const <Song>[];
    final soft = widget.soft;
    final size = widget.size, peek = size * (soft ? 0.045 : 0.07);
    final t = _c.value;
    final from = t < 1 ? _from : null;
    // Reduce motion: the covers crossfade, nothing flies.
    final anim = calm(context) ? 'fade' : settings.coverAnim;

    Widget card(
      Song s, {
      required double left,
      required double scale,
      required double opacity,
      double dx = 0,
      double dy = 0,
      double turn = 0,
      bool shadow = false,
    }) => Positioned(
      left: left + dx,
      top: dy,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: turn,
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: size,
            height: size,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Cover(s.art, image: s.image, size: size * scale, radius: 10, shadow: shadow),
            ),
          ),
        ),
      ),
    );

    // The behind slots: i = 0 is the first one back, the next song. Each is
    // a little smaller and shows a [peek] further right than the one in front
    // of it. (The first used to end flush with the front cover, hidden, so
    // the stack showed the song after next.)
    double slotScale(int i) => soft ? 0.94 - i * 0.04 : 0.9 - i * 0.07;
    double slotLeft(int i) => size * (1 - slotScale(i)) + peek * (i + 1);
    double slotOpacity(int i) => soft ? 0.34 - i * 0.1 : 0.6 - i * 0.15;

    final children = <Widget>[
      for (var i = behind.length - 1; i >= 0; i--)
        // Going back, the first slot is where the left song is heading.
        if (!(from != null && _back && anim == 'swipe' && i == 0))
          card(
            behind[i],
            left: slotLeft(i),
            scale: slotScale(i),
            opacity: slotOpacity(i) * (from == null || anim != 'swipe' ? 1 : Curves.easeOut.transform(t)),
          ),
    ];
    if (from == null) {
      children.add(card(widget.song, left: 0, scale: 1, opacity: 1, shadow: true));
    } else {
      final e = Curves.easeOutCubic.transform(t);
      double lerp(double a, double b, double k) => a + (b - a) * k;
      switch (anim) {
        case 'push':
          final dir = _back ? -1.0 : 1.0;
          children
            ..add(card(from, left: 0, scale: 1, opacity: 1 - t, dx: -dir * size * 1.15 * e, shadow: true))
            ..add(card(widget.song, left: 0, scale: 1, opacity: t * 2, dx: dir * size * 1.15 * (1 - e), shadow: true));
        case 'fade':
          children
            ..add(card(from, left: 0, scale: 1, opacity: 1, shadow: true))
            ..add(card(widget.song, left: 0, scale: 1, opacity: Curves.easeInOut.transform(t), shadow: true));
        default: // toss
          // The cover is tossed off to the left, tilting a little and gone
          // in the first 60% of the time, while the next one springs up
          // from the first behind slot. Going back plays it in reverse.
          final p = _back ? 1 - t : t;
          final (gone, rising) = _back ? (widget.song, from) : (from, widget.song);
          if (_held) {
            // Held through a crossfade: the first half tosses the old cover
            // partway, tilted, still whole, while the next one comes up to
            // the front behind it; the second half finishes the toss.
            final h = Curves.easeOutCubic.transform((p / 0.5).clamp(0.0, 1.0));
            final k = Curves.easeInCubic.transform(((p - 0.5) / 0.5).clamp(0.0, 1.0));
            children
              ..add(card(rising, left: lerp(slotLeft(0), 0, h), scale: lerp(slotScale(0), 1, h), opacity: lerp(slotOpacity(0), 1, h), shadow: true))
              ..add(
                card(
                  gone,
                  left: 0,
                  scale: 1,
                  opacity: 1 - k,
                  dx: -size * lerp(_holdShift * h, _tossTravel, k),
                  dy: size * 0.04 * k,
                  turn: -_tossTilt * h,
                  shadow: true,
                ),
              );
            break;
          }
          final k = Curves.easeInCubic.transform((p / 0.6).clamp(0.0, 1.0));
          final up = p >= 1 ? 1.0 : 1 - exp(-7 * p) * cos(_tossBounce * 14 * p);
          children
            ..add(
              card(
                rising,
                left: lerp(slotLeft(0), 0, up),
                scale: lerp(slotScale(0), 1, up),
                opacity: lerp(slotOpacity(0), 1, up).clamp(0.0, 1.0),
                shadow: true,
              ),
            )
            ..add(card(gone, left: 0, scale: 1, opacity: 1 - k, dx: -size * _tossTravel * k, dy: size * 0.04 * k, turn: -_tossTilt * k, shadow: true));
      }
    }
    return SizedBox(
      width: size + peek * behind.length,
      height: size,
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.centerLeft, children: children),
    );
  }
}

/// A small icon button with a hover wash and a tooltip.
class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, this.tip, this.onTap, {super.key, this.filled = false, this.badge = false, this.color, this.size = 18});
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  final bool filled, badge;

  /// Text-2 unless given (the accent, say, for an active one).
  final Color? color;
  final double size;

  Color get _c => color ?? K.text2;

  @override
  Widget build(BuildContext context) {
    if (context.dependOnInheritedWidgetOfExactType<BareIcons>() != null) return _bare();
    final i = Icon(icon, size: size, color: onTap == null ? K.text3.withValues(alpha: 0.5) : _c);
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: Hover(
        onTap: onTap,
        // A touch screen gets a 44 px target round the same small icon.
        builder: (context, on) => ConstrainedBox(
          constraints: narrow(context) ? const BoxConstraints(minWidth: 44, minHeight: 44) : const BoxConstraints(),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: K.tint.withValues(
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
        ),
      ),
    );
  }

  /// The desktop player bar's kind: no box, text-3 brightening to text on
  /// hover; a colored (active) one keeps its color.
  Widget _bare() => Tooltip(
    message: tip,
    waitDuration: const Duration(milliseconds: 500),
    child: Hover(
      onTap: onTap,
      builder: (_, on) {
        final c = onTap == null
            ? K.text3.withValues(alpha: 0.5)
            : _c != K.text2 && _c != K.text
            ? _c
            : on
            ? K.text
            : (_c == K.text ? K.text2 : K.text3);
        return Padding(
          padding: const EdgeInsets.all(6),
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: c),
            duration: Motion.fast,
            builder: (_, c, _) {
              final i = Icon(icon, size: size, color: c);
              return badge ? Badge(smallSize: 7, backgroundColor: K.accent, child: i) : i;
            },
          ),
        );
      },
    ),
  );
}

/// IconBtns under this draw bare, as the desktop player bar's buttons.
class BareIcons extends InheritedWidget {
  const BareIcons({super.key, required super.child});

  @override
  bool updateShouldNotify(BareIcons old) => false;
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
    void menu(Offset at) => songMenu(context, song, at, queue: queue);
    return MenuKeys(
      open: menu,
      child: GestureDetector(
        onSecondaryTapUp: (d) => menu(d.globalPosition),
        onLongPressStart: (d) => menu(d.globalPosition),
        child: Hover(
          onTap: () => PlayerScope.read(context).play(song, queue),
          builder: (_, on) => AnimatedContainer(
            duration: Motion.fast,
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
                      FullText(
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
              duration: Motion.fast,
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
  const VideoThumb(this.video, {super.key, required this.width, this.accent});
  final Video video;
  final double width;
  final Color? accent;

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
              child: Container(height: 4, width: width * video.progress, color: accent ?? K.accent),
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

  // The compact look also when the card itself is narrow (the window's
  // in-between widths), or Play and Shuffle wrap onto two rows.
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) => _card(context, compact || c.maxWidth < 460));

  Widget _card(BuildContext context, bool compact) {
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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [K.dark ? const Color(0x805A2A5E) : const Color(0x335A2A5E), K.panel.withValues(alpha: 0)],
        ),
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
                FullText(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: compact ? ds(22) : Txt.title()),
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
                    // The glass buttons, as on album and artist pages.
                    if (queued)
                      GlassBtn(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, p.playing ? 'Pause' : 'Resume', p.toggle, primary: true)
                    else
                      GlassBtn(Icons.play_arrow_rounded, 'Play', () => p.play(song, played), primary: true),
                    GlassBtn(Icons.shuffle_rounded, 'Shuffle', () {
                      if (!p.shuffle) p.toggleShuffle();
                      if (!queued) p.play(song, played);
                    }),
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

/// Every Slider goes through this. Flutter 3.44's Slider keeps an
/// OverlayPortal open for its value bubble, tagging its own semantics as a
/// "traversal parent" and the bubble as a "traversal child" that lives in the
/// app's Overlay. That grafting goes wrong on desktop: a Slider in a hidden
/// pane, or sharing a node with a Tooltip's portal, orphans the bubble, the
/// Windows and macOS engines reject the update, and closing a dialog with a
/// screen reader on crashes the app. So the Slider's own semantics are
/// dropped (a local Overlay keeps the bubble under that exclusion) and this
/// gives the one slider node a screen reader needs.
// ponytail: Flutter master reworked the grafting; retest without this on the
// next Flutter upgrade (test/semantics_traversal_test.dart).
Widget safeSlider(Slider slider) => _SafeSlider(slider);

class _SafeSlider extends StatefulWidget {
  const _SafeSlider(this.slider);
  final Slider slider;

  @override
  State<_SafeSlider> createState() => _SafeSliderState();
}

class _SafeSliderState extends State<_SafeSlider> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.slider;
    final on = s.onChanged != null;
    final span = s.max - s.min;
    // Slider's own step for a screen reader's increase and decrease.
    final unit = s.divisions != null ? 1 / s.divisions! : (Theme.of(context).platform == TargetPlatform.macOS ? 0.1 : 0.05);
    final t = span == 0 ? 0.0 : ((s.value - s.min) / span).clamp(0.0, 1.0);
    String pct(double v) => '${(v * 100).round()}%';
    void step(double by) => s.onChanged!(s.min + (t + by).clamp(0.0, 1.0) * span);
    return Semantics(
      container: true,
      slider: true,
      enabled: on,
      focusable: on,
      focused: _focused,
      value: pct(t),
      increasedValue: pct((t + unit).clamp(0, 1)),
      decreasedValue: pct((t - unit).clamp(0, 1)),
      onIncrease: on ? () => step(unit) : null,
      onDecrease: on ? () => step(-unit) : null,
      child: ExcludeSemantics(
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (v) => setState(() => _focused = v),
          child: Overlay.wrap(clipBehavior: Clip.none, alwaysSizeToContent: true, child: s),
        ),
      ),
    );
  }
}

/// The thin seek and volume bars. Null [onChanged] shows it disabled.
class ThinBar extends StatelessWidget {
  const ThinBar({super.key, required this.value, required this.onChanged, this.color, this.label});
  final double value;
  final ValueChanged<double>? onChanged;
  final Color? color;

  /// Shown in a bubble over the handle while it is dragged (a volume's %).
  final String Function(double value)? label;

  @override
  Widget build(BuildContext context) => SliderTheme(
    data: SliderThemeData(
      trackHeight: 4,
      trackShape: const RoundedRectSliderTrackShape(),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      activeTrackColor: color ?? K.accent,
      inactiveTrackColor: K.tint.withValues(alpha: 0.14),
      disabledActiveTrackColor: color ?? K.accent,
      disabledInactiveTrackColor: K.tint.withValues(alpha: 0.14),
      disabledThumbColor: Colors.transparent,
      thumbColor: K.dark ? Colors.white : K.text,
      overlayColor: (color ?? K.accent).withValues(alpha: 0.2),
      showValueIndicator: ShowValueIndicator.onDrag,
      valueIndicatorShape: const RectangularSliderValueIndicatorShape(),
      valueIndicatorColor: K.surface,
      valueIndicatorTextStyle: ts(11, c: K.text, tab: true),
    ),
    child: SizedBox(
      height: 20,
      child: safeSlider(
        Slider(value: value.clamp(0, 1), onChanged: onChanged, label: label?.call(value.clamp(0, 1)), padding: const EdgeInsets.symmetric(horizontal: 6)),
      ),
    ),
  );
}

/// A volume slider's bubble: 0 to 1 as a percentage.
String volumeLabel(double v) => '${(v * 100).round()}%';

/// Draws [child] [scale] times its size: it lays out in a smaller (or larger)
/// window and is scaled to fill the real one, so everything, text, icons and
/// spacing, grows together, as a browser's zoom.
class UiScale extends StatelessWidget {
  const UiScale({super.key, required this.scale, required this.child});
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (scale == 1) return child;
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        size: mq.size / scale,
        devicePixelRatio: mq.devicePixelRatio * scale,
        padding: mq.padding / scale,
        viewPadding: mq.viewPadding / scale,
        viewInsets: mq.viewInsets / scale,
      ),
      child: LayoutBuilder(
        builder: (context, c) => FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.topLeft,
          child: SizedBox(width: c.maxWidth / scale, height: c.maxHeight / scale, child: child),
        ),
      ),
    );
  }
}

/// Text cut off with an ellipsis when it does not fit, and then the whole of
/// it in a tooltip, so a long title can still be read.
class FullText extends StatelessWidget {
  const FullText(this.data, {super.key, this.style, this.maxLines = 1, this.textAlign, this.overflow = TextOverflow.ellipsis});
  final String data;
  final TextStyle? style;
  final int maxLines;
  final TextAlign? textAlign;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final text = Text(data, maxLines: maxLines, overflow: overflow, textAlign: textAlign, style: style);
      if (!c.maxWidth.isFinite) return text;
      final painter = TextPainter(
        text: TextSpan(text: data, style: DefaultTextStyle.of(context).style.merge(style)),
        maxLines: maxLines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: c.maxWidth);
      final cut = painter.didExceedMaxLines;
      painter.dispose();
      return cut ? Tooltip(message: data, waitDuration: const Duration(milliseconds: 400), child: text) : text;
    },
  );
}

/// Tells a screen reader when a new song starts ("Now playing X by Y"),
/// without moving focus. Silent with no screen reader running.
class SongAnnouncer extends StatefulWidget {
  const SongAnnouncer({super.key, required this.player, required this.child});
  final Player player;
  final Widget child;

  @override
  State<SongAnnouncer> createState() => _SongAnnouncerState();
}

class _SongAnnouncerState extends State<SongAnnouncer> {
  String? _last;

  @override
  void initState() {
    super.initState();
    _last = widget.player.song?.id;
    widget.player.addListener(_check);
  }

  @override
  void dispose() {
    widget.player.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final s = widget.player.song;
    final id = s == null ? null : (s.id.isEmpty ? s.title : s.id);
    if (id == _last) return;
    _last = id;
    if (s == null || !mounted) return;
    SemanticsService.sendAnnouncement(View.of(context), 'Now playing ${s.title} by ${s.artist}', Directionality.maybeOf(context) ?? TextDirection.ltr);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
