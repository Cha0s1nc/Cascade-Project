// Skipping flicks the cover away to the right, tilting, and the next one
// steps up; when it is done one cover sits in front, untilted.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final reduce in [false, true]) {
    testWidgets(reduce ? 'with Reduce motion on, the cover only crossfades' : 'the cover swipes away on a skip', (tester) async {
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      final player = Player(audio: false, settings: await Settings.load())..playing = false;
      if (reduce) player.settings.setReduceMotion('on');
      await tester.pumpWidget(CascadeApp(player: player, demo: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lyrics'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final stack = find.byType(ArtStack).last; // Now Playing's, over Home's hero
      double maxTilt() => find
          .descendant(of: stack, matching: find.byType(Transform))
          .evaluate()
          .map((e) => (e.widget as Transform).transform.getRotation().entry(1, 0).abs())
          .fold(0.0, (a, b) => a > b ? a : b);
      expect(maxTilt(), 0);

      await player.next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (reduce) {
        expect(maxTilt(), 0, reason: 'nothing tilts or flies');
      } else {
        expect(maxTilt(), greaterThan(0.05), reason: 'mid-toss the old cover tilts');
      }
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(maxTilt(), 0, reason: 'settled: no tilt');

      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a crossfade holds the toss halfway, both covers showing, then finishes', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lyrics'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final stack = find.byType(ArtStack).last;
    double maxTilt() => find
        .descendant(of: stack, matching: find.byType(Transform))
        .evaluate()
        .map((e) => (e.widget as Transform).transform.getRotation().entry(1, 0).abs())
        .fold(0.0, (a, b) => a > b ? a : b);
    // Opacity of every cover in the stack, front last.
    List<double> shown() => [
      for (final e in find.descendant(of: stack, matching: find.byType(Opacity)).evaluate())
        if ((e.widget as Opacity).opacity > 0.9) (e.widget as Opacity).opacity,
    ];

    // As a crossfade does: the song changes with four seconds of fade left.
    player.crossfadeEnd = DateTime.now().add(const Duration(seconds: 4));
    await player.next();
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(maxTilt(), 0, reason: 'held: the old cover is not tossed yet');
    expect(shown().length, greaterThanOrEqualTo(2), reason: 'both covers in full');

    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(maxTilt(), 0, reason: 'finished as the crossfade ended');
    expect(shown().length, 1, reason: 'one cover in front');
    await tester.pumpWidget(const SizedBox());
  });
}
