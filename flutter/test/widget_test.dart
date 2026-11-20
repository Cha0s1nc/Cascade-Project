import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> at(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle();
  }

  testWidgets('desktop and phone layouts build without overflow and play a tapped song', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await at(tester, const Size(1440, 900));
    // The phone layout below 900 px, as on Android (a computer is compact unless it is chosen).
    final settings = await Settings.load()
      ..setNarrowLayout('phone');
    await tester.pumpWidget(CascadeApp(player: Player(audio: false, settings: settings), demo: true));
    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('TV Shows'), findsOneWidget);

    await tester.tap(find.text('Nights'));
    await tester.pump();
    expect(find.text('Nights'), findsNWidgets(3)); // the tile, the Home card (now playing) and the player bar

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(find.text('Melodrama'), findsOneWidget); // the demo's albums, in the grid

    await tester.tap(find.text('Your Cascade')); // the logo row is the Home button
    await tester.pumpAndSettle();
    expect(find.text('Recently played'), findsOneWidget);

    await at(tester, const Size(1000, 700)); // narrow desktop: hero stacks over the tiles
    await at(tester, const Size(412, 915));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Nights'), findsWidgets);

    await tester.pumpWidget(const SizedBox()); // disposes the player's timer
  });
}
