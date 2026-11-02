import 'package:cascade/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> at(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle();
  }

  testWidgets('desktop and phone layouts build without overflow and play a tapped song', (tester) async {
    addTearDown(tester.view.reset);
    await at(tester, const Size(1440, 900));
    await tester.pumpWidget(const CascadeApp());
    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('TV Shows'), findsOneWidget);

    await tester.tap(find.text('Nights'));
    await tester.pump();
    expect(find.text('Nights'), findsNWidgets(2)); // the tile and the player bar

    await tester.tap(find.text('Albums'));
    await tester.pump();
    expect(find.text('Not in the prototype yet. Home is.'), findsOneWidget);

    await at(tester, const Size(1000, 700)); // narrow desktop: hero stacks over the tiles
    await at(tester, const Size(412, 915));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Nights'), findsWidgets);

    await tester.pumpWidget(const SizedBox()); // disposes the player's timer
  });
}
