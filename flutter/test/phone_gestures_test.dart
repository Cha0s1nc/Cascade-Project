// The phone layout's gestures: swipe the mini player or Now Playing's art to
// skip, drag Now Playing down to close it, swipe between Settings' tabs.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('swipes skip, a drag down closes, Settings swipes', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(412, 880);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    player.settings.setNarrowLayout('phone');
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();
    Future<void> frames() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    final first = player.song!.title;
    final mini = tester.getCenter(find.text(first).last);
    await tester.dragFrom(mini, const Offset(-160, 0));
    await frames();
    final second = player.song!.title;
    expect(second, isNot(first), reason: 'swiping the mini player left skips');

    await tester.tapAt(mini);
    await frames();
    expect(find.byTooltip('Queue'), findsOneWidget, reason: 'Now Playing open');
    await tester.dragFrom(const Offset(206, 300), const Offset(160, 0)); // the art, to the right
    await frames();
    expect(player.song!.title, isNot(second), reason: 'swiping the art right goes back');

    await tester.dragFrom(const Offset(206, 300), const Offset(0, 500)); // the art, down
    await frames();
    expect(find.byTooltip('Queue'), findsNothing, reason: 'dragged down, it closed');

    await tester.tap(find.text('Settings').last);
    await frames();
    await tester.flingFrom(const Offset(300, 500), const Offset(-250, 0), 1200);
    await frames();
    expect(find.text('Crossfade'), findsWidgets, reason: 'swiped on to Playback');
    await tester.pumpWidget(const SizedBox());
  });
}
