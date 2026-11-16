// The lyrics renderer: the spring brings the current line to the panel's
// middle, karaoke with held notes and background vocals draws without
// errors, and the wheel browses then springs back.
import 'package:cascade/core/lyrics.dart';
import 'package:cascade/core/lyrics_fetch.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/lyrics_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const s = 10000000; // ticks per second

LyricLine karaoke(double at, List<String> words, {List<String>? bg}) {
  var t = (at * s).round();
  List<LyricWord> timed(List<String> ws) => [for (final w in ws) LyricWord(t, t += w.contains('~') ? 2 * s : s ~/ 3, w.replaceAll('~', ''))];
  final lead = timed(words);
  return LyricLine(lead.first.start, lead.last.end, lead.map((w) => w.text).join(), lead, background: bg == null ? null : timed(bg));
}

Future<void> frames(WidgetTester tester, [int n = 60]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('follows, fills, swells and browses', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false)..playing = false; // the demo player plays; hold the clock still
    final lines = [
      for (var i = 0; i < 12; i++) karaoke(i * 3.0, ['Line ', '$i ', 'goes ', if (i == 4) 'hoooold~ ' else 'by '], bg: i == 4 ? ['(ooh)'] : null),
    ];
    final lyrics = Lyrics(lines, 'SpicyLyrics', credit: (provider: 'SpicyLyrics', uploader: null, maker: null));
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: LyricsView(player: player, lyrics: lyrics),
          ),
        ),
      ),
    );

    // Partway into line 4's held note.
    player.position = 4 * 3.0 + 1.5;
    await frames(tester);
    final panel = tester.getRect(find.byType(LyricsView));
    final block = (tester.getRect(find.text('4').first).top + tester.getRect(find.text('(ooh)')).bottom) / 2;
    expect((block - panel.center.dy).abs(), lessThan(8), reason: 'the current line and its background row sit mid-panel');
    expect(find.text('(ooh)'), findsOneWidget, reason: 'the current line opens its background vocals');
    expect(find.text('h'), findsOneWidget, reason: 'a held note is drawn letter by letter');

    // The held line keeps its exact layout once it is no longer current, so
    // its wrap never changes as it fades.
    // The held word's group on line 4, letter by letter while lit.
    Size wrap4() {
      final word = find.text('h').evaluate().isNotEmpty ? find.text('h') : find.text('hoooold');
      return tester.getSize(find.ancestor(of: word.first, matching: find.byType(Row)).last);
    }

    final lit = wrap4();

    // The wheel moves the sheet; 2.2 s later it springs back.
    final before = tester.getRect(find.text('4').first).top;
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(panel.center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getRect(find.text('4').first).top, closeTo(before - 120, 2));
    await tester.pump(const Duration(milliseconds: 2300));
    await frames(tester, 90);
    expect(tester.getRect(find.text('4').first).top, closeTo(before, 2));

    // A jump ahead (a seek) lands there at once.
    player.position = 6 * 3.0 + 0.2;
    await frames(tester, 3);
    expect(wrap4(), lit, reason: 'line 4, now past, has the same layout as when it was lit');

    player.position = 9 * 3.0 + 0.2;
    await frames(tester, 3);
    expect((tester.getRect(find.text('9').first).center.dy - panel.center.dy).abs(), lessThan(40));

    await tester.pumpWidget(const SizedBox());
    player.dispose();
  });

  testWidgets('a new song rolls in from below, or from above after going back', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final lyrics = Lyrics([for (var i = 0; i < 8; i++) LyricLine(i * 3000, null, 'Line $i', null)], 'LRCLIB');
    final players = <Player>[];
    Future<double> firstFrame(bool back) async {
      final player = Player(audio: false)..playing = false;
      players.add(player);
      player.position = 3 * 3.0 + 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 800,
              height: 600,
              child: LyricsView(key: UniqueKey(), player: player, lyrics: lyrics, rollIn: true, rollBack: back),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      return tester.getRect(find.text('Line 3')).center.dy - tester.getRect(find.byType(LyricsView)).center.dy;
    }

    expect(await firstFrame(false), greaterThan(40), reason: 'forward: it starts below and rises');
    expect(await firstFrame(true), lessThan(-40), reason: 'back: it starts above and drops');
    await tester.pumpWidget(const SizedBox());
    for (final p in players) {
      p.dispose();
    }
  });
}
