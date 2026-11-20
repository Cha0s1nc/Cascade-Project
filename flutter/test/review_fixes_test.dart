// From the UI/UX review: cut-off titles can still be read, a cleared or
// trimmed queue can be put back, and a row's menu opens from the keyboard.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a cut-off title shows the whole of it in a tooltip', (tester) async {
    Widget at(double w, String t) => MaterialApp(
      home: Center(
        child: SizedBox(width: w, child: FullText(t)),
      ),
    );
    await tester.pumpWidget(at(80, 'A very long song title that cannot fit'));
    expect(find.byType(Tooltip), findsOneWidget);
    await tester.pumpWidget(at(400, 'Short'));
    expect(find.byType(Tooltip), findsNothing);
  });

  test('Undo puts a cleared queue back, unless playback moved on', () {
    final p = Player(audio: false)..playing = false;
    final before = p.orderSnapshot, next = p.upNext;
    expect(next, isNotEmpty);
    p.clearUpNext();
    expect(p.upNext, isEmpty);
    expect(p.restoreOrder(before), isTrue);
    expect(p.upNext, next);
    p.dispose();
  });

  testWidgets('the Menu key and Shift+F10 open a row menu', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: MenuKeys(
            open: (_) => opened++,
            child: Hover(onTap: () {}, builder: (_, _) => const Text('row')),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(opened, 2);
  });

  testWidgets('? lists the shortcuts, but not while typing in search', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(CascadeApp(player: Player(audio: false)..playing = false, demo: true));
    await tester.pumpAndSettle();

    Future<void> question() async {
      // The character is what counts: Linux sends the key itself as ?.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.slash, character: '?');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await question();
    expect(find.text('Keyboard shortcuts'), findsNothing, reason: 'a ? typed into search stays there');

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await question();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a window narrowed to the phone layout still takes the desktop keys', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(700, 800);
    tester.view.devicePixelRatio = 1;
    // Stored settings: the in-memory kind skips its setters' assignments.
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    player.settings.setNarrowLayout('phone'); // a computer's narrow window is compact unless this is chosen
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget, reason: 'the phone layout');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(player.playing, isTrue, reason: 'Space plays');
    await tester.pumpWidget(const SizedBox());
  });
}
