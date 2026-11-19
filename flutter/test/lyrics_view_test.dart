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
    final block = (tester.getRect(find.text('4').first).top + tester.getRect(find.text('(ooh)').first).bottom) / 2;
    expect((block - panel.center.dy).abs(), lessThan(8), reason: 'the current line and its background row sit mid-panel');
    expect(find.text('(ooh)'), findsWidgets, reason: 'the current line opens its background vocals (drawn in the dim and lit layers)');
    expect(find.text('h'), findsWidgets, reason: 'a held note is drawn letter by letter');

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

  testWidgets('a long break shows the waiting dots mid-panel, then folds them away', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false)..playing = false;
    // Sung 1-3 s, then nothing until 20 s.
    final lyrics = Lyrics([LyricLine(10000000, 30000000, 'Before', null), LyricLine(200000000, 220000000, 'After', null)], 'LRCLIB');
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
    Finder dots() =>
        find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).shape == BoxShape.circle);

    player.position = 2;
    await frames(tester, 30);
    expect(dots(), findsNothing, reason: 'still singing');

    player.position = 10;
    await frames(tester, 90);
    expect(dots(), findsNWidgets(3));
    final panel = tester.getRect(find.byType(LyricsView));
    expect((tester.getCenter(dots().first).dy - panel.center.dy).abs(), lessThan(30), reason: 'the sheet holds the dots mid-panel');

    player.position = 21;
    await frames(tester, 30);
    expect(dots(), findsNothing, reason: 'folded away once the next line comes');
    await tester.pumpWidget(const SizedBox());
    player.dispose();
  });

  for (final scale in [1.0, 1.5]) {
    testWidgets('the current line draws solid text in layers: no see-through letters, masks reaching past the word (text at ${scale}x)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      addTearDown(tester.view.reset);
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      final player = Player(audio: false)..playing = false;
      final lines = [
        for (var i = 0; i < 4; i++) karaoke(i * 3.0, ['What\'s ', 'wrong ', 'with ', 'me?']),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              // The system's text size (Windows' Text size, GNOME's scaling).
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: Center(
                child: SizedBox(
                  width: 800,
                  height: 600,
                  child: LyricsView(player: player, lyrics: Lyrics(lines, 'Kugou')),
                ),
              ),
            ),
          ),
        ),
      );
      player.position = 3.0 + 0.5; // line 1, mid-way through "wrong"
      await frames(tester, 40);
      final current = find.ancestor(of: find.text('wrong').first, matching: find.byType(Stack)).first;
      for (final t in tester.widgetList<Text>(find.descendant(of: current, matching: find.byType(Text)))) {
        expect(t.style?.color?.a ?? 1, 1, reason: '"${t.data}" is solid; its layer makes it dim');
      }
      for (final e in find.descendant(of: current, matching: find.byType(ShaderMask)).evaluate()) {
        final mask = tester.getRect(find.byWidget(e.widget));
        final word = tester.getRect(find.descendant(of: find.byWidget(e.widget), matching: find.byType(Text)));
        expect(mask.left < word.left && mask.right > word.right, isTrue, reason: 'the mask reaches past the word, over ink spilling out of its box');
        expect(
          find.ancestor(of: find.byWidget(e.widget), matching: find.byType(ClipRect)),
          findsNothing,
          reason: 'not clipped: that cut the spill, then let it pop back',
        );
      }
      expect(
        find.descendant(of: current, matching: find.byType(ShaderMask)),
        findsOneWidget,
        reason: 'the word filling now',
      );
      final widths = {for (final e in find.descendant(of: current, matching: find.text('wrong')).evaluate()) tester.getSize(find.byWidget(e.widget)).width};
      expect(widths.length, 1, reason: 'the filling word is as wide in its masked box as in the dim layer: the box is measured at the text size');
      await tester.pumpWidget(const SizedBox());
      player.dispose();
    });
  }

  testWidgets('clicking a word jumps to it, in the current line and any other', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final player = Player(audio: false)..playing = false;
    final lines = [
      for (var i = 0; i < 8; i++) karaoke(i * 3.0, ['Line ', '$i ', 'goes ', 'by ']),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: LyricsView(player: player, lyrics: Lyrics(lines, 'Kugou')),
          ),
        ),
      ),
    );
    player.position = 3.0 + 0.5; // line 1 current
    await frames(tester, 40);
    // Line 2's second word ("2", from 6 1/3 s), not the line's start (6 s);
    // the default lead (-0.05 s) puts it a touch earlier, so it lights as heard.
    await tester.tap(find.text('2').first);
    await frames(tester, 5);
    expect(player.position, closeTo(6 + 1 / 3 - 0.05, 0.01));
    // The current line now (line 2): its "by" (from 7 s).
    await frames(tester, 40);
    final line2 = find.ancestor(of: find.text('2').first, matching: find.byType(Stack)).first;
    await tester.tap(find.descendant(of: line2, matching: find.text('by')).hitTestable().first);
    await frames(tester, 5);
    expect(player.position, closeTo(7 - 0.05, 0.01));
    await tester.pumpWidget(const SizedBox());
    player.dispose();
  });

  test('a held note fills with one edge sliding evenly over its letters, by width', () {
    const widths = [10.0, 30.0, 5.0, 20.0], fs = 40.0;
    double front(double prog) {
      final f = heldFill(widths, prog, fs);
      // The edge in word space is the same from every letter: one edge.
      var x = 0.0;
      final at = <double>[];
      for (var i = 0; i < widths.length; i++) {
        at.add(f[i].edge + x);
        x += widths[i];
      }
      for (final a in at) {
        expect(a, closeTo(at.first, 1e-9));
      }
      return at.first;
    }

    // It moves at an even pace, from before the word to past it.
    final steps = [for (var i = 0; i <= 10; i++) front(i / 10)];
    for (var i = 1; i < steps.length; i++) {
      expect(steps[i] - steps[i - 1], closeTo(steps[1] - steps[0], 1e-9));
    }
    expect(steps.first, lessThan(0));
    expect(steps.last, greaterThan(65));
    // A wide letter is reached later than a narrow one before it by its width, not by its count.
    final lit = heldFill(widths, 0, fs).map((f) => f.litAt).toList();
    expect(lit[2] - lit[1], greaterThan((lit[3] - lit[2]) * 5));
  });
}
