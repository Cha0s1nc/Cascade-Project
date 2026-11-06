// The desktop shell: search sits centered on Home and tucks beside the
// right-hand buttons elsewhere, widening while in use; the sidebar button
// cycles expanded, a rail that slides out under the mouse, and a plain rail.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('search slides, the sidebar cycles', (tester) async {
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

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(search().width, 86, reason: 'tucked elsewhere');
    expect(search().right, greaterThan(1200));

    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(search().width, 300, reason: 'wide while in use');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

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

    await tester.pumpWidget(const SizedBox());
  });
}
