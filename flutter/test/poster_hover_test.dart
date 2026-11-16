// A poster's hover: the cover dims, Play (or Resume) sits bottom left and
// More bottom right, which opens the same menu as a right click.
import 'package:cascade/ui/pages/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('hovering a poster shows Play and More; More opens its menu', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // Hover highlights count with a mouse, not in a test's touch mode.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
    final played = <String>[];
    Offset? menuAt;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 180,
            child: MediaCard(
              title: 'Dune',
              subtitle: '2024',
              art: const [Colors.black, Colors.grey],
              aspect: 2 / 3,
              onTap: () {},
              hoverPlay: ('Resume', () => played.add('play')),
              onMenu: (at) => menuAt = at,
            ),
          ),
        ),
      ),
    );
    Finder visible(Finder f) => find.ancestor(of: f, matching: find.byWidgetPredicate((w) => w is AnimatedOpacity && w.opacity == 1));
    expect(visible(find.byTooltip('Resume')), findsNothing, reason: 'hidden until hovered');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(MediaCard)));
    await tester.pumpAndSettle();
    expect(visible(find.byTooltip('Resume')), findsOneWidget);

    await tester.tap(find.byTooltip('Resume'));
    expect(played, ['play']);
    await tester.tap(find.byTooltip('More'));
    expect(menuAt, isNotNull);
    await mouse.removePointer();
  });
}
