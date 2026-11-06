// The Settings tabs and the Style menu build without overflow, with and
// without a song playing, at a roomy and a tight desktop size.
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:cascade/ui/style_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Now Playing's lyrics keep a ticker running, so settle by frames.
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  for (final size in const [Size(1440, 900), Size(1000, 700)]) {
    testWidgets('Settings and the Style menu at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final player = Player(audio: false);
      await tester.pumpWidget(CascadeApp(player: player, demo: true));
      await tester.pumpAndSettle();
      player.stop(); // the demo starts with a song loaded
      await tester.pumpAndSettle();

      // Nothing playing: the menu opens on its own with the look controls off.
      await tester.tap(find.byTooltip('Style').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Play something to change how it looks'), findsOneWidget);
      for (final t in ['Now Playing', 'Lyrics', 'Crossfade', 'Presets', 'Appearance']) {
        await tester.tap(find.text(t).last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Close').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      for (final t in ['Playback', 'Lyrics', 'Integrations', 'Account', 'About', 'Library']) {
        await tester.tap(find.text(t).last);
        await tester.pumpAndSettle();
      }

      // Playing: the menu opens inside Now Playing beside the lyrics.
      await tester.tap(find.text('Your Cascade'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nights'));
      await tester.pump();
      await tester.tap(find.byTooltip('Style').first);
      await frames(tester);
      expect(find.textContaining('Play something to change how it looks'), findsNothing);
      for (final t in ['Now Playing', 'Lyrics', 'Crossfade', 'Presets', 'Appearance']) {
        await tester.tap(find.text(t).last);
        await frames(tester);
      }
      await tester.tap(find.byTooltip('Close the Style menu').last); // its own X
      await frames(tester);
      expect(find.byType(StyleMenu), findsNothing);

      // The brush opens it and closes it again.
      await tester.tap(find.byTooltip('Style').first);
      await frames(tester);
      expect(find.byType(StyleMenu), findsOneWidget);
      await tester.tap(find.byTooltip('Close the Style menu').first);
      await frames(tester);
      expect(find.byType(StyleMenu), findsNothing);
      await frames(tester);

      await tester.pumpWidget(const SizedBox());
    });
  }
}
