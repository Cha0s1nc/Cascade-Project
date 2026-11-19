// The desktop shell: search sits centered on Home and tucks beside the
// right-hand buttons elsewhere (the glass and the shortcut), widening to fill
// the bar while in use; the sidebar button
// cycles expanded, a rail that slides out under the mouse, and a plain rail.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:cascade/ui/pages/library.dart' show GridPage;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('search slides, the sidebar cycles, the interface scales', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    // Saved settings: the in-memory kind keeps no changes.
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();

    Rect search() => tester.getRect(find.byType(TextField).first);
    expect(search().center.dx, closeTo(720, 1), reason: 'centered on Home');
    expect(search().width, lessThanOrEqualTo(340));

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(search().width, lessThan(90), reason: 'elsewhere, idle, a small pill');
    expect(search().right, greaterThan(1440 - 260), reason: 'beside the right-hand buttons');
    expect(find.text('Ctrl K'), findsOneWidget, reason: 'with the shortcut showing');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(search().width, 720, reason: 'in use it fills the free middle of the bar, up to 720');
    expect(search().left, greaterThan(100), reason: 'clear of the left buttons');
    expect(search().right, lessThan(1440 - 60), reason: 'clear of the right buttons');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(search().width, lessThan(90), reason: 'tucked again when let go');

    double sidebar() => tester.getRect(find.text('Your Cascade').first).left;
    final logo = find.image(const AssetImage('assets/icon.png'));
    double width() => tester.getRect(find.ancestor(of: logo, matching: find.byType(AnimatedContainer)).last).width;
    expect(width(), 232);
    await tester.tap(find.byTooltip('Sidebar: slide out on hover'));
    await tester.pumpAndSettle();
    expect(width(), 60);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(logo));
    await mouse.moveTo(tester.getCenter(logo));
    await tester.pumpAndSettle();
    expect(width(), 232, reason: 'slid out under the mouse');
    await mouse.moveTo(const Offset(900, 500));
    await tester.pumpAndSettle();
    expect(width(), 60);
    await tester.tap(find.byTooltip('Sidebar: icons only'));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(logo));
    await tester.pumpAndSettle();
    expect(width(), 60, reason: 'a plain rail stays shut');
    await mouse.removePointer();
    await tester.tap(find.byTooltip('Sidebar: expanded'));
    await tester.pumpAndSettle();
    expect(width(), 232);
    expect(sidebar(), isNonZero);

    // Ctrl + makes everything bigger together; Ctrl 0 puts it back.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(player.settings.uiScale, closeTo(1.1, 1e-9));
    expect(width(), closeTo(232 * 1.1, 0.5));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(width(), 232);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opening and closing the sidebar moves no row, frame by frame', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sidebarMode': 'hover'});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();

    final logo = find.image(const AssetImage('assets/icon.png'));
    // Every row's height on the page, top to bottom.
    List<double> rows() => [
      for (final e in find.byType(Icon).evaluate())
        if (tester.getTopLeft(find.byWidget(e.widget)).dx < 80) tester.getTopLeft(find.byWidget(e.widget)).dy,
    ];
    final before = rows();
    expect(before, isNotEmpty);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(logo));
    // In, out and back in quickly, as a mouse brushing past does.
    for (final to in [tester.getCenter(logo), const Offset(900, 500), tester.getCenter(logo), const Offset(900, 500)]) {
      await mouse.moveTo(to);
      for (var f = 0; f < 6; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull);
        expect(rows(), before, reason: 'rows stay put while the sidebar moves');
      }
    }
    await tester.pumpAndSettle();
    await mouse.removePointer();
  });

  testWidgets('switching sections keeps the old page alive while it fades: no blank frame', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    final albums = tester.state(find.byType(GridPage));

    await tester.tap(find.text('Artists'));
    for (var f = 0; f < 6; f++) {
      await tester.pump(const Duration(milliseconds: 16));
      // It used to be rebuilt from scratch as it left, and drew nothing.
      expect(tester.stateList(find.byType(GridPage)), contains(same(albums)), reason: 'frame $f: the leaving page is the same page');
    }
    await tester.pumpAndSettle();
  });

  testWidgets('the open sidebar fits every label, Rediscover\'s New included', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();
    final logo = find.image(const AssetImage('assets/icon.png'));
    final side = tester.getRect(find.ancestor(of: logo, matching: find.byType(AnimatedContainer)).last);
    final badge = tester.getRect(find.text('New'));
    expect(badge.right, lessThanOrEqualTo(side.right - 10), reason: 'the badge ends inside the row, not cut at the edge');
  });
}
