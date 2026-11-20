// Every main screen at window sizes from the 420x520 minimum to 2560 wide, and
// at 150% interface size, collecting every layout error rather than stopping at
// the first. Below 900 px both narrow layouts: the phone layout (Android's, and
// a computer's when chosen) at every size, and the compact desktop layout (a
// computer's default) from 640 px, the narrowest its window goes.
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sizes = [
  Size(420, 520),
  Size(420, 900),
  Size(600, 800),
  Size(760, 600),
  Size(899, 900),
  Size(900, 600),
  Size(1000, 700),
  Size(1100, 620),
  Size(1280, 720),
  Size(1440, 900),
  Size(1920, 1080),
  Size(2560, 1440),
];

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final cases = [
    for (final s in sizes) (s, 1.0, 'phone'),
    for (final s in const [Size(640, 600), Size(760, 600), Size(899, 900)]) (s, 1.0, 'compact'),
    (const Size(1280, 720), 1.5, 'phone'),
    (const Size(1280, 720), 1.5, 'compact'),
  ];
  for (final (size, scale, narrow) in cases) {
    final wide = size.width / scale >= 900;
    if (wide && narrow == 'compact' && scale == 1) continue;
    testWidgets('every screen at ${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : ' at ${(scale * 100).round()}%'}${wide ? '' : ', $narrow'}', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final player = Player(audio: false, settings: await Settings.load())..playing = false;
      if (scale != 1) player.settings.setUiScale(scale);
      player.settings.setNarrowLayout(narrow);
      final found = <String>[];
      final old = FlutterError.onError;
      var where = 'Home';
      FlutterError.onError = (d) {
        found.add('$where: ${d.exceptionAsString().split('\n').first}');
        if (const bool.fromEnvironment('SWEEP_DEBUG')) {
          debugPrint(
            'STACK $where ${d.exceptionAsString()}\n${d.stack.toString().split('\n').where((l) => l.contains('package:cascade')).take(6).join('\n')}\n${d.informationCollector?.call().take(8).join('\n')}',
          );
        }
      };
      try {
        await tester.pumpWidget(CascadeApp(player: player, demo: true));
        await settle(tester);
        Future<void> go(String label, {bool last = false}) async {
          final f = find.text(label);
          if (f.evaluate().isEmpty) return;
          where = label;
          await tester.tap(last ? f.last : f.first, warnIfMissed: false);
          await settle(tester);
        }

        final desktop = wide || narrow == 'compact';
        if (desktop) {
          for (final page in ['Albums', 'Artists', 'Songs', 'Playlists', 'Genres', 'History', 'Rediscover', 'Movies', 'TV Shows', 'Downloads']) {
            await go(page);
          }
          await go('Albums');
          await go('Melodrama'); // an album page
          await go('Settings');
          for (final tab in ['Playback', 'Lyrics', 'Integrations', 'Account', 'About', 'Library']) {
            await go(tab, last: true);
          }
          await go('Your Cascade');
          where = 'Now Playing';
          await tester.tap(find.byTooltip('Lyrics').first, warnIfMissed: false);
          await settle(tester);
          await tester.tap(find.byTooltip('Queue').first, warnIfMissed: false);
          await settle(tester);
          where = 'Style menu';
          await tester.tap(find.byTooltip('Style').first, warnIfMissed: false);
          await settle(tester);
          for (final tab in ['Now Playing', 'Lyrics', 'Crossfade', 'Presets']) {
            await go(tab, last: true);
          }
        } else {
          for (final tab in ['Search', 'Library', 'Settings', 'Home']) {
            await go(tab, last: true);
          }
        }
      } finally {
        FlutterError.onError = old;
      }
      await tester.pumpWidget(const SizedBox());
      expect(found.toSet().toList(), isEmpty);
    });
  }
}
