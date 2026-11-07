// Mode switches the palette live: everything repaints, and you stay where
// you were.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => K.current = darkPalette);

  for (final size in const [Size(1440, 900), Size(412, 915)]) {
    testWidgets('light mode at ${size.width.toInt()} wide', (tester) async {
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final player = Player(audio: false, settings: await Settings.load())..playing = false;
      await tester.pumpWidget(CascadeApp(player: player, demo: true));
      await tester.pumpAndSettle();
      if (size.width > 900) {
        await tester.tap(find.text('Albums'));
        await tester.pumpAndSettle();
      }
      final before = find.byType(Scaffold).evaluate().length;

      player.settings.setThemeMode('light');
      await tester.pumpAndSettle();
      expect(K.dark, isFalse);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.backgroundColor, anyOf(lightPalette.root, lightPalette.panel, isNull));
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.light);
      if (size.width > 900) expect(find.text('Melodrama'), findsOneWidget, reason: 'still on Albums');
      expect(find.byType(Scaffold).evaluate().length, before);

      player.settings.setThemeMode('dark');
      await tester.pumpAndSettle();
      expect(K.dark, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
