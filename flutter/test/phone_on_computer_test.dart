// The phone layout on a computer (a narrow window, chosen in the Style menu):
// a back button where Android would use its own, and Movies and TV only in a
// wider window.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a back button away from Home, and a hint instead of Movies and TV', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(420, 860);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    player.settings.setNarrowLayout('phone');
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing, reason: 'nowhere to go back to on Home');

    await tester.tap(find.text('Library').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsNothing, reason: 'back on Home');

    await tester.tap(find.byTooltip('Movies and TV'));
    await tester.pump();
    expect(find.text('Widen the window for Movies and TV'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Search songs, albums, artists'), findsOneWidget, reason: 'still music');
    await tester.pumpWidget(const SizedBox());
  });
}
