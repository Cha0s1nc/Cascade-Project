// Ported from desktop/test/media-segments.test.ts.
import 'package:cascade/core/media_segments.dart';
import 'package:flutter_test/flutter_test.dart';

const t = 10000000;
MediaSegment seg(String type, double s, double e) => (type: type, startSec: s, endSec: e);

void main() {
  test('parseMediaSegments: reads a response and converts ticks to seconds', () {
    final out = parseMediaSegments({
      'Items': [
        {'Id': 'b', 'ItemId': 'x', 'Type': 'Outro', 'StartTicks': 1200 * t, 'EndTicks': 1300 * t},
        {'Id': 'a', 'ItemId': 'x', 'Type': 'Intro', 'StartTicks': 30 * t, 'EndTicks': 90 * t},
      ],
      'TotalRecordCount': 2,
      'StartIndex': 0,
    });
    expect(out, [seg('Intro', 30, 90), seg('Outro', 1200, 1300)]);
  });

  test('parseMediaSegments: an empty, missing or non-object response is no segments', () {
    for (final raw in [
      {'Items': []},
      <String, Object?>{},
      null,
      'nope',
      {'Items': 'x'},
    ]) {
      expect(parseMediaSegments(raw), isEmpty);
    }
  });

  test('parseMediaSegments: drops unknown types and malformed ranges', () {
    final out = parseMediaSegments({
      'Items': [
        {'Type': 'Unknown', 'StartTicks': 0, 'EndTicks': 5 * t},
        {'Type': 'Bogus', 'StartTicks': 0, 'EndTicks': 5 * t},
        {'Type': 'Intro', 'StartTicks': -1, 'EndTicks': 5 * t},
        {'Type': 'Intro', 'StartTicks': 5 * t, 'EndTicks': 5 * t},
        {'Type': 'Intro', 'StartTicks': 9 * t, 'EndTicks': 5 * t},
        {'Type': 'Intro', 'StartTicks': double.nan, 'EndTicks': 5 * t},
        {'Type': 'Intro', 'StartTicks': '0', 'EndTicks': 5 * t},
        {'Type': 'Intro', 'StartTicks': 0, 'EndTicks': double.infinity},
        null,
        {'Type': 'Recap', 'StartTicks': 0, 'EndTicks': 5 * t},
      ],
    });
    expect(out, [seg('Recap', 0, 5)]);
  });

  test('activeSegment: start is inside, end is outside', () {
    final list = [seg('Intro', 30, 90)];
    expect(activeSegment(list, 29.999), isNull);
    expect(activeSegment(list, 30)?.type, 'Intro');
    expect(activeSegment(list, 89.999)?.type, 'Intro');
    expect(activeSegment(list, 90), isNull);
  });

  test('activeSegment: empty list, junk position', () {
    expect(activeSegment([], 10), isNull);
    expect(activeSegment([seg('Intro', 0, 10)], double.nan), isNull);
    expect(activeSegment([seg('Intro', 0, 10)], double.infinity), isNull);
  });

  test('activeSegment: only intros and outros are offered', () {
    final list = [seg('Recap', 0, 60), seg('Preview', 100, 120), seg('Commercial', 200, 260)];
    for (final s in [10.0, 110.0, 220.0]) {
      expect(activeSegment(list, s), isNull);
    }
  });

  test('activeSegment: overlapping segments, the one that ends last wins', () {
    final list = [seg('Intro', 30, 80), seg('Intro', 40, 100), seg('Recap', 0, 500)];
    expect(activeSegment(list, 50)?.endSec, 100);
    expect(activeSegment(list, 35)?.endSec, 80);
  });

  test('activeSegment: a gap between two segments is null', () {
    final list = [seg('Intro', 0, 10), seg('Outro', 20, 30)];
    expect(activeSegment(list, 15), isNull);
    expect(activeSegment(list, 25)?.type, 'Outro');
  });

  test('skipLabel names the segment', () {
    expect(skipLabel(seg('Intro', 0, 1)), 'Skip Intro');
    expect(skipLabel(seg('Outro', 0, 1)), 'Skip Credits');
  });

  test('skipAction: seeks to the end of an intro', () {
    expect(skipAction(seg('Intro', 30, 90), 2600), (kind: 'seek', sec: 90.0));
  });

  test('skipAction: an outro that ends mid-item seeks, one that runs to the end goes on', () {
    expect(skipAction(seg('Outro', 2400, 2500), 2600), (kind: 'seek', sec: 2500.0));
    expect(skipAction(seg('Outro', 2400, 2600), 2600).kind, 'next');
    expect(skipAction(seg('Outro', 2400, 2599.5), 2600).kind, 'next');
    expect(skipAction(seg('Outro', 2400, 2700), 2600).kind, 'next');
  });

  test('skipAction: an unknown duration never counts as the end', () {
    expect(skipAction(seg('Outro', 2400, 2600), 0), (kind: 'seek', sec: 2600.0));
    expect(skipAction(seg('Intro', 0, 90), 90), (kind: 'seek', sec: 90.0));
  });

  test('segmentKey is stable and distinguishes segments', () {
    expect(segmentKey('x', seg('Intro', 30, 90)), segmentKey('x', seg('Intro', 30, 95)));
    expect(segmentKey('x', seg('Intro', 30, 90)), isNot(segmentKey('y', seg('Intro', 30, 90))));
    expect(segmentKey('x', seg('Intro', 30, 90)), isNot(segmentKey('x', seg('Outro', 30, 90))));
  });
}
