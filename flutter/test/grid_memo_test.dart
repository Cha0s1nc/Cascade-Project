// A library grid sorts once per list and choice: a library change that is not
// the list (here a bare notify) neither re-sorts nor reshuffles Random.
import 'dart:convert';

import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Random keeps its order while the library changes around it', (tester) async {
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'albumsPrefs': jsonEncode({'field': 'random', 'dir': 'asc', 'favorite': false}),
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false, settings: await Settings.load())..playing = false;
    await tester.pumpWidget(CascadeApp(player: player, demo: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();

    List<String> order() => [for (final c in tester.widgetList<MediaCard>(find.byType(MediaCard))) c.title];
    final before = order();
    expect(before.length, greaterThan(2));
    final lib = LibraryScope.read(tester.element(find.byType(MediaCard).first));
    for (var i = 0; i < 5; i++) {
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      lib.notifyListeners();
      await tester.pump();
      expect(order(), before);
    }
  });
}
