// Ported from the reading-side tests in desktop/test/tuning.test.ts, plus the
// lyric-style tests from desktop/test/lyric-style.test.ts. Reads the same
// shared/tuning-defaults.json the desktop and Apple apps do.
import 'dart:io';

import 'package:cascade/core/lyric_style.dart';
import 'package:cascade/core/tuning.dart';
import 'package:cascade/core/tuning_defaults.dart';
import 'package:flutter_test/flutter_test.dart';

final _text = File('../shared/tuning-defaults.json').readAsStringSync();

void main() {
  final tuning = LyricStyleTuning(TuningDefaults(_text));

  test('a value is shared, or the most specific target a platform reads wins', () {
    expect(resolveEntry(0.3, 'tvos'), 0.3);
    final e = {'all': -0.05, 'ios': -0.35, 'note': 'why'};
    expect(resolveEntry(e, 'ios'), -0.35);
    expect(resolveEntry(e, 'mac'), -0.05);
    expect(resolveEntry(e, 'desktop'), -0.05);
    final apple = {'apple': 30, 'tvos': 44};
    expect(resolveEntry(apple, 'mac'), 30);
    expect(resolveEntry(apple, 'tvos'), 44);
    expect(resolveEntry(apple, 'desktop'), isNull);
    final slots = [
      {'x': 1},
    ];
    expect(identical(resolveEntry(slots, 'ios'), slots), isTrue);
  });

  test('platformsOf and revisionKeys', () {
    expect(platformsOf('apple'), ['mac', 'ios', 'tvos']);
    expect(platformsOf('all'), tuningPlatforms);
    final file = {
      'revisions': {
        '2': {
          'all': ['a'],
        },
        '3': {
          'date': 'd',
          'all': ['b'],
          'apple': ['c'],
        },
      },
    };
    expect(revisionKeys(file, 'desktop', 3), ['b']);
    expect(revisionKeys(file, 'tvos', 3)..sort(), ['b', 'c']);
    expect(revisionKeys(file, 'desktop', 9), isEmpty);
    expect(latestRevision(file), 3);
    expect(latestRevision({}), 1);
  });

  test('every desktop knob has a default in the file, and the revisions name real knobs', () {
    final file = tuning.defaults.file;
    for (final k in tuning.knobs) {
      expect(resolveEntry(file['style'][k.key], 'desktop'), isA<num>(), reason: k.key);
      expect(k.value >= k.min && k.value <= k.max, isTrue, reason: '${k.key} default ${k.value} outside ${k.min}...${k.max}');
    }
    final names = (file['style'] as Map).keys.toSet();
    for (final r in (file['revisions'] as Map).entries) {
      for (final e in (r.value as Map).entries) {
        if (e.value is! List) continue;
        for (final k in e.value as List) {
          expect(names.contains(k), isTrue, reason: 'revision ${r.key} ${e.key}: $k is not a style key');
        }
      }
    }
    // Revision 3 moved only the iPhone, so the desktop has nothing to ask.
    expect(tuning.changed[3], isEmpty);
    expect(tuning.changed[2]?.length, 8);
  });

  test('shippedNumber throws for a key the platform lacks', () {
    expect(() => tuning.defaults.shippedNumber('style', 'lyricSize'), throwsStateError);
    expect(TuningDefaults(_text, platform: 'tvos').shippedNumber('style', 'lyricSize'), 44);
    expect(tuning.defaults.shippedNumber('style', 'currentLinePosition'), 0.5);
  });

  test('every knob has a sane, unique definition', () {
    final keys = <String>{};
    for (final k in tuning.knobs) {
      expect(keys.add(k.key), isTrue, reason: '${k.key} twice');
      expect(k.min < k.max && k.value >= k.min && k.value <= k.max, isTrue, reason: '${k.key} default out of range');
      expect(k.step > 0 && k.step <= k.max - k.min, isTrue, reason: '${k.key} step');
    }
  });

  test('lyricStyleFrom keeps valid stored values, clamps the rest, and ignores junk', () {
    final s = tuning.lyricStyleFrom({'pastBlur': 2, 'pastOpacity': 5, 'next1Blur': 'x', 'bogus': 1, 'lyricsDelay': double.nan});
    expect(s['pastBlur'], 2);
    expect(s['pastOpacity'], 1);
    expect(s['next1Blur'], 2.5);
    expect(s['lyricsDelay'], -0.05);
    expect(s.containsKey('bogus'), isFalse);
    for (final junk in [
      null,
      'str',
      [1, 2],
      42,
    ]) {
      expect(tuning.lyricStyleFrom(junk), tuning.lyricStyleFrom({}));
    }
  });

  test('lyricStyleChanges stores only what differs from the defaults', () {
    expect(tuning.lyricStyleChanges(tuning.lyricStyleFrom({})), isEmpty);
    expect(tuning.lyricStyleChanges(tuning.lyricStyleFrom({'pastBlur': 2, 'wordLift': 0.04})), {'pastBlur': 2});
  });

  test('lyricStyleCss writes units, and leaves JS-only knobs out', () {
    final css = tuning.lyricStyleCss(tuning.lyricStyleFrom({'pastBlur': 2}));
    expect(css['--ly-past-blur'], '2px');
    expect(css['--ly-fade'], '1s');
    expect(css['--word-lift'], '0.04em');
    expect(css['--ly-past-opacity'], '0.3');
    expect(css.values.any((v) => v.contains('NaN')), isFalse);
    expect(css.length, tuning.knobs.where((k) => k.css != null).length);
  });

  test('easeInOut matches cubic-bezier(0.42, 0, 0.58, 1) at its known points', () {
    expect(easeInOut(0), 0);
    expect(easeInOut(1), 1);
    expect((easeInOut(0.5) - 0.5).abs() < 1e-6, isTrue);
    expect(easeInOut(0.25) < 0.25 && easeInOut(0.75) > 0.75, isTrue);
    for (var t = 0.0; t < 1; t += 0.05) {
      expect(easeInOut(t + 0.05) >= easeInOut(t), isTrue, reason: 'monotonic');
    }
  });

  test('heldSwell: longer holds swell more, rise until the note ends, then go back to normal', () {
    final s = tuning.lyricStyleFrom({'heldFullSeconds': 3, 'heldMinStrength': 0.3, 'heldSettleSeconds': 0.6});
    expect(heldSwell(-0.1, 1, 1, s), 0);
    expect((heldSwell(1, 1, 1, s) - 0.3).abs() < 1e-6, isTrue);
    expect((heldSwell(2, 2, 2, s) - 0.65).abs() < 1e-6, isTrue);
    expect((heldSwell(5, 5, 5, s) - 1).abs() < 1e-6, isTrue);
    expect(heldSwell(1, 4, 4, s) < heldSwell(3, 4, 4, s), isTrue);
    expect(heldSwell(4 + 0.3, 4, 4, s) < heldSwell(4, 4, 4, s), isTrue);
    expect(heldSwell(4 + 0.6, 4, 4, s), 0);
    expect(heldSwell(30, 4, 4, s), 0);
    expect(heldSwell(0.1, 0.05, 4, s) < heldSwell(0.34, 0.05, 4, s), isTrue);
  });

  test('lyricKnobsWithNewDefaults: only re-baked knobs this person changed, once', () {
    expect(tuning.lyricKnobsWithNewDefaults({}, null), isEmpty);
    expect(tuning.lyricKnobsWithNewDefaults({'heldScale': 1.12, 'pastBlur': 2}, 1).map((k) => k.key), ['heldScale']);
    expect(tuning.lyricKnobsWithNewDefaults({'heldScale': 1.12}, tuning.revision), isEmpty);
    expect(tuning.lyricKnobsWithNewDefaults({'lyricsDelay': -0.3}, 'x').map((k) => k.key), ['lyricsDelay']);
  });

  test('revisions name real knobs', () {
    final known = tuning.knobs.map((k) => k.key).toSet();
    for (final keys in tuning.changed.values) {
      for (final k in keys) {
        expect(known.contains(k), isTrue, reason: k);
      }
    }
  });
}
