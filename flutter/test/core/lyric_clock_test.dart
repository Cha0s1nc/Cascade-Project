import 'package:cascade/core/lyric_clock.dart';
import 'package:flutter_test/flutter_test.dart';

Duration ms(num v) => Duration(microseconds: (v * 1000).round());

void main() {
  test('moves every frame between updates and follows them', () {
    final c = LyricClock();
    var pos = 10.0, shown = <double>[];
    for (var f = 0; f <= 120; f++) {
      final t = f * 16.0;
      if (f % 6 == 0) pos = 10 + t / 1000; // an update every ~0.1 s
      shown.add(c.now(pos, true, ms(t)));
    }
    for (var i = 1; i < shown.length; i++) {
      expect(shown[i], greaterThan(shown[i - 1]), reason: 'frame $i moves forward');
    }
    expect(shown.last, closeTo(10 + 120 * 16 / 1000, 0.03));
  });

  test('resuming after a pause starts from the paused position, no leap', () {
    final c = LyricClock();
    c.now(5, true, ms(0));
    c.now(5, false, ms(100));
    c.now(5, false, ms(10000)); // ten seconds paused
    final resumed = c.now(5, true, ms(10016));
    expect(resumed, closeTo(5, 0.05), reason: 'it used to jump a full second ahead');
  });

  test('a stall runs ahead only about half a second', () {
    final c = LyricClock();
    var t = 0.0;
    for (var i = 0; i < 20; i++, t += 100) {
      c.now(1 + t / 1000, true, ms(t));
    }
    final at = 1 + (t - 100) / 1000;
    double shown = 0;
    for (var f = 0; f < 120; f++) {
      shown = c.now(at, true, ms(t + f * 16)); // no updates for ~2 s
    }
    expect(shown - at, lessThan(0.85), reason: 'the half-second cap, and a little creep past it as it is steered');
  });

  test('uneven updates neither freeze it nor make it lurch or step back', () {
    // As mpv on PipeWire reported: mostly every 0.1 s, but now and then
    // 0.25 s late and 0.15 s behind, then caught up all at once.
    final c = LyricClock();
    var pos = 10.0;
    final shown = <double>[];
    for (var f = 0; f <= 600; f++) {
      final t = f * 16.0;
      if (f % 6 == 0 && f % 60 != 6 && f % 60 != 12) pos = 10 + t / 1000 - (f % 60 == 18 ? 0.15 : 0);
      shown.add(c.now(pos, true, ms(t)));
    }
    for (var i = 30; i < shown.length; i++) {
      final step = shown[i] - shown[i - 1];
      expect(step, greaterThan(0.004), reason: 'frame $i moves (no freeze)');
      expect(step, lessThan(0.04), reason: 'frame $i does not lurch');
    }
    expect(shown.last, closeTo(10 + 600 * 16 / 1000, 0.08));
  });

  test('a seek jumps straight there', () {
    final c = LyricClock();
    c.now(10, true, ms(0));
    c.now(10.1, true, ms(100));
    expect(c.now(60, true, ms(116)), closeTo(60, 0.02));
  });
}
