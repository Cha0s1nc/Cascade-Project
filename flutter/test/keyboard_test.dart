// The app's own controls work from the keyboard: Tab reaches them, Enter
// and Space press them, and a screen reader hears a button or a switch.
import 'package:cascade/ui/controls.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Tab, Enter and Space', (tester) async {
    var pressed = 0;
    var on = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: StatefulBuilder(
            builder: (context, set) => Column(
              children: [
                Hover(onTap: () => pressed++, label: 'Press me', builder: (_, hot) => Text(hot ? 'lit' : 'unlit')),
                Toggle(value: on, onChanged: (v) => set(() => on = v)),
              ],
            ),
          ),
        ),
      ),
    );
    final handle = tester.ensureSemantics();
    expect(tester.getSemantics(find.byType(Hover)), isSemantics(isButton: true, isEnabled: true, isFocusable: true, hasTapAction: true));
    expect(tester.getSemantics(find.byType(Hover)).label, contains('Press me'));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.text('lit'), findsOneWidget, reason: 'focus lights it as hover does');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(pressed, 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(on, isTrue, reason: 'the toggle flips from the keyboard');
    handle.dispose();
  });
}
