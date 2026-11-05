// The full-screen lyrics' look as user settings: the knobs, their ranges, and
// the held-note swell curve. Pure. Ported from desktop/src/core/lyric-style.ts
// (the Apple app's Style Tuning keys). Defaults come from a TuningDefaults.
// Only knobs the user changed are stored; stored values are untrusted and
// clamped to their range. The `css` and `unit` fields are the desktop's custom
// property names, kept so a style can move between apps.
import 'dart:math';

import 'tuning_defaults.dart';

/// One adjustable lyric knob. [value] is the shipped default.
class LyricKnob {
  final String key, section, label;
  final double min, max, step, value;
  final String? css, unit;
  const LyricKnob(this.key, this.section, this.label, this.min, this.max, this.step, {this.value = 0, this.css, this.unit});

  LyricKnob withValue(double v) => LyricKnob(key, section, label, min, max, step, value: v, css: css, unit: unit);
}

const _specs = <LyricKnob>[
  LyricKnob('currentLinePosition', 'Layout', 'Current line position', 0.1, 0.6, 0.01),
  LyricKnob('lineGap', 'Layout', 'Line gap', 0, 40, 1, css: '--ly-line-gap', unit: 'px'),
  LyricKnob('pastScale', 'Past lines', 'Size', 0.4, 1, 0.01, css: '--ly-past-scale'),
  LyricKnob('pastOpacity', 'Past lines', 'Opacity', 0, 1, 0.01, css: '--ly-past-opacity'),
  LyricKnob('pastBlur', 'Past lines', 'Blur', 0, 8, 0.5, css: '--ly-past-blur', unit: 'px'),
  LyricKnob('next1Opacity', 'Upcoming lines', 'Next opacity', 0, 1, 0.01, css: '--ly-next1-opacity'),
  LyricKnob('next1Blur', 'Upcoming lines', 'Next blur', 0, 8, 0.5, css: '--ly-next1-blur', unit: 'px'),
  LyricKnob('next2Opacity', 'Upcoming lines', 'Second opacity', 0, 1, 0.01, css: '--ly-next2-opacity'),
  LyricKnob('next2Blur', 'Upcoming lines', 'Second blur', 0, 8, 0.5, css: '--ly-next2-blur', unit: 'px'),
  LyricKnob('next3Opacity', 'Upcoming lines', 'Third opacity', 0, 1, 0.01, css: '--ly-next3-opacity'),
  LyricKnob('next3Blur', 'Upcoming lines', 'Third blur', 0, 8, 0.5, css: '--ly-next3-blur', unit: 'px'),
  LyricKnob('farBlur', 'Upcoming lines', 'Blur further out', 0, 12, 0.5, css: '--ly-far-blur', unit: 'px'),
  LyricKnob('browsingOpacity', 'Upcoming lines', 'Opacity while scrolling', 0, 1, 0.01, css: '--ly-browsing-opacity'),
  LyricKnob('browsingBlur', 'Upcoming lines', 'Blur while scrolling', 0, 8, 0.5, css: '--ly-browsing-blur', unit: 'px'),
  LyricKnob('unsungOpacity', 'Karaoke', 'Unsung word opacity', 0, 1, 0.01, css: '--ly-unsung-opacity'),
  LyricKnob('wordLift', 'Karaoke', 'Word lift (em)', 0, 0.2, 0.005, css: '--word-lift', unit: 'em'),
  LyricKnob('heldFullSeconds', 'Karaoke', 'Held note: full swell after (s)', 1, 8, 0.1),
  LyricKnob('heldMinStrength', 'Karaoke', 'Held note: short note strength', 0, 1, 0.05),
  LyricKnob('heldLift', 'Karaoke', 'Held note lift (em)', 0, 0.4, 0.01, css: '--emph-lift', unit: 'em'),
  LyricKnob('heldScale', 'Karaoke', 'Held note swell', 1, 1.4, 0.01, css: '--emph-scale'),
  LyricKnob('heldSettleSeconds', 'Karaoke', 'Held note release time (s)', 0, 2, 0.05),
  LyricKnob('backgroundVocalSize', 'Karaoke', 'Background vocal size', 0.4, 1, 0.01, css: '--ly-bg-vocal-size', unit: 'em'),
  LyricKnob('backgroundVocalOpacity', 'Karaoke', 'Background vocal opacity', 0, 1, 0.01, css: '--ly-bg-vocal-opacity'),
  LyricKnob('fadeSeconds', 'Motion', 'Line fade (s)', 0, 2, 0.05, css: '--ly-fade', unit: 's'),
  LyricKnob('rippleSeconds', 'Motion', 'Ripple per line (s)', 0, 0.4, 0.01),
  // Negative is earlier: a line takes its fade to light up, so one drawn exactly on the beat reads as late.
  LyricKnob('lyricsDelay', 'Motion', 'Lyrics timing (s)', -2, 2, 0.05),
  LyricKnob('scrollLead', 'Motion', 'Scroll ahead (s)', 0, 1, 0.05),
  // Only for a line that follows the one before closely; 0 turns it off.
  LyricKnob('tightScrollLead', 'Motion', 'Scroll ahead on tight lines (s)', 0, 1, 0.05),
  LyricKnob('bgSaturation', 'Background colors', 'Saturation', 0, 2, 0.05),
  LyricKnob('bgBrightness', 'Background colors', 'Brightness', -0.5, 0.5, 0.01),
  LyricKnob('bgIntensity', 'Background colors', 'Intensity', 0, 2, 0.05),
  LyricKnob('bgSpeed', 'Background colors', 'Drift speed', 0, 5, 0.1),
  LyricKnob('lyricsDimBase', 'Background colors', 'Dim behind lyrics', 0, 0.8, 0.01),
  LyricKnob('lyricsDimBright', 'Background colors', 'Extra dim for bright covers', 0, 0.8, 0.01),
  LyricKnob('lyricsDimFrom', 'Background colors', 'Counts as bright from', 0.3, 0.82, 0.01),
  LyricKnob('controlsIdleSeconds', 'Controls', 'Hide after (s)', 1, 20, 0.5),
];

/// A style: every knob key to its value.
typedef LyricStyle = Map<String, double>;

/// The knobs with their shipped defaults, plus everything that needs them.
class LyricStyleTuning {
  final TuningDefaults defaults;
  late final List<LyricKnob> knobs = [for (final k in _specs) k.withValue(defaults.shippedNumber('style', k.key))];
  late final Map<String, LyricKnob> _byKey = {for (final k in knobs) k.key: k};

  LyricStyleTuning(this.defaults);

  /// The latest defaults revision.
  int get revision => defaults.revision;

  /// The style keys each defaults revision moved.
  Map<int, List<String>> get changed => {for (var i = 1; i <= revision; i++) i: defaults.revisionKeysOf(i)};

  /// The knob for [key], or null.
  LyricKnob? knob(String key) => _byKey[key];

  double _clamp(LyricKnob k, Object? v) => v is num && v.isFinite ? v.toDouble().clamp(k.min, k.max) : k.value;

  /// Every knob's value: stored ones (clamped) over the defaults. Unknown keys and non-maps are ignored.
  LyricStyle lyricStyleFrom(Object? stored) {
    final s = stored is Map ? stored : const {};
    return {for (final k in knobs) k.key: s.containsKey(k.key) ? _clamp(k, s[k.key]) : k.value};
  }

  /// Only the knobs that differ from their defaults: what gets stored.
  LyricStyle lyricStyleChanges(LyricStyle style) {
    final out = <String, double>{};
    for (final k in knobs) {
      final v = _clamp(k, style[k.key]);
      if ((v - k.value).abs() > 1e-9) out[k.key] = v;
    }
    return out;
  }

  /// The custom properties a style sets, e.g. `{'--ly-past-blur': '3.5px'}`. JS-only knobs are left out.
  Map<String, String> lyricStyleCss(LyricStyle style) => {
    for (final k in knobs)
      if (k.css != null) k.css!: '${_num(_clamp(k, style[k.key]))}${k.unit ?? ''}',
  };

  /// The re-baked knobs this person changed since the defaults revision they last saw ([seen]; missing or junk counts as 1). Empty means nothing to ask.
  List<LyricKnob> lyricKnobsWithNewDefaults(Object? changes, Object? seen) {
    final from = seen is int && seen >= 1 ? seen : 1;
    if (from >= revision) return [];
    final moved = <String>{};
    final ch = changed;
    for (var r = from + 1; r <= revision; r++) {
      moved.addAll(ch[r] ?? const []);
    }
    final mine = lyricStyleChanges(lyricStyleFrom(changes));
    return [
      for (final k in knobs)
        if (moved.contains(k.key) && mine.containsKey(k.key)) k,
    ];
  }
}

/// A double the way JS prints a number: no trailing ".0".
String _num(double v) => v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();

/// CSS's (and SwiftUI's) ease-in-out, cubic-bezier(0.42, 0, 0.58, 1).
double easeInOut(double t) {
  if (!(t > 0)) return 0;
  if (t >= 1) return 1;
  // Solve x(u) = t for the curve parameter u (Newton), then return y(u).
  var u = t;
  for (var i = 0; i < 8; i++) {
    final x = 3 * 0.42 * pow(1 - u, 2) * u + 3 * 0.58 * (1 - u) * u * u + u * u * u - t;
    if (x.abs() < 1e-7) break;
    final dx = 3 * 0.42 * pow(1 - u, 2) + 6 * (0.58 - 0.42) * (1 - u) * u + 3 * (1 - 0.58) * u * u;
    u = min(1.0, max(0.0, u - x / dx));
  }
  return 3 * (1 - u) * u * u + u * u * u;
}

/// How swollen one letter of a held note is, 0 to 1 of the full swell. Strength comes from the note's length ([held]), the letter rises from when the fill reaches it ([sinceLit]) until the note ends ([untilEnd], over at least 0.35 s), then eases back over heldSettleSeconds.
double heldSwell(double sinceLit, double untilEnd, double held, LyricStyle style) {
  if (!(sinceLit >= 0)) return 0;
  final full = style['heldFullSeconds']!;
  final minStrength = style['heldMinStrength']!;
  final reach = full > 1 ? ((held - 1) / (full - 1)).clamp(0.0, 1.0) : 1.0;
  final strength = minStrength + (1 - minStrength) * reach;
  final rise = max(untilEnd, 0.35);
  if (sinceLit < rise) return strength * easeInOut(sinceLit / rise);
  final settleSec = style['heldSettleSeconds']!;
  final settle = settleSec > 0 ? min(1.0, (sinceLit - rise) / settleSec) : 1.0;
  return strength * (1 - easeInOut(settle));
}
