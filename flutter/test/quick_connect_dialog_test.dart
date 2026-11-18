// The title bar's Quick Connect dialog is small: words, the field, Done.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:cascade/ui/settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the Quick Connect dialog is a small popup', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();
    showQuickConnectApprove(tester.element(find.text('Your Cascade').first));
    await tester.pumpAndSettle();
    final box = tester.getRect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first);
    expect(box.height, lessThan(300), reason: 'it used to stretch to most of the window');
    expect(box.width, lessThan(450));
    expect(find.text('Approve'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });
}
