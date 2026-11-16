// Ported from desktop/test/lyrics.test.ts.
import 'package:cascade/core/lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

const sec = 10000000;
const ms = 10000;

LyricWord w(String t, num s, num e) => LyricWord((s * sec).round(), (e * sec).round(), t);
LyricLine l(num s, num? e, String t, {List<LyricWord>? words, List<LyricWord>? bg}) =>
    LyricLine((s * sec).round(), e == null ? null : (e * sec).round(), t, words, background: bg);

void main() {
  test('parseLRC: plain lines carry no word timing', () {
    final out = parseLRC('[00:12.50]Hello world');
    expect(out.length, 1);
    expect(out[0].start, (12.5 * sec).round());
    expect(out[0].text, 'Hello world');
    expect(out[0].words, isNull);
  });

  test('parseLRC: whole-second timestamps are valid LRC', () {
    final out = parseLRC('[00:12]hello');
    expect(out.length, 1);
    expect(out[0].start, 12 * sec);
    expect(out[0].text, 'hello');
  });

  test('parseLRC: mixed whole-second and fractional lines all parse', () {
    final out = parseLRC('[00:10]one\n[00:12.50]two\n[00:15]three');
    expect(out.map((x) => x.text), ['one', 'two', 'three']);
    expect(out.map((x) => x.start), [10 * sec, (12.5 * sec).round(), 15 * sec]);
  });

  test('parseLRC: word timestamps also allow whole seconds', () {
    final words = parseLRC('[00:10]<00:10>Hello <00:11.5>world')[0].words!;
    expect(words.length, 2);
    expect(words[0].start, 10 * sec);
    expect(words[1].start, (11.5 * sec).round());
  });

  test('parseLRC: skips metadata tags and blank content', () {
    final out = parseLRC('[ti:Some Title]\n[ar:Artist]\n[00:01.00]\n[00:02.00]real');
    expect(out.length, 1);
    expect(out[0].text, 'real');
  });

  test('parseLRC: enhanced LRC chains word end times to the next word', () {
    final out = parseLRC('[00:10.00]<00:10.00>Hello <00:10.50>world\n[00:12.50]next');
    expect(out.length, 2);
    final words = out[0].words!;
    expect(words.length, 2);
    expect(out[0].text, 'Hello world');
    expect(words[0].start, 10 * sec);
    expect(words[0].end, (10.5 * sec).round());
    expect(words[1].start, (10.5 * sec).round());
    expect(words[1].end, (12.5 * sec).round());
  });

  test('parseLRC: final word falls back to +2s when no line follows', () {
    expect(parseLRC('[00:10.00]<00:10.00>only')[0].words![0].end, 10 * sec + 2 * sec);
  });

  test('parseLRC: bare punctuation attaches to the previous word', () {
    final words = parseLRC('[00:01.00]<00:01.00>hey<00:01.50>!')[0].words!;
    expect(words.length, 1);
    expect(words[0].text, 'hey!');
  });

  test('parseLRC: per-character sources keep their spaces', () {
    expect(parseLRC('[00:01.00]<00:01.00>a<00:01.10> <00:01.20>b')[0].text, 'a b');
  });

  test('parseKrc: word offsets are relative to the line start', () {
    final out = parseKrc('[1000,2000]<0,500,0>Hi<500,500,0> there');
    expect(out.length, 1);
    expect(out[0].start, 1000 * ms);
    expect(out[0].end, 3000 * ms);
    expect(out[0].text, 'Hi there');
    final words = out[0].words!;
    expect(words.length, 2);
    expect(words[0].start, 1000 * ms);
    expect(words[0].end, 1500 * ms);
    expect(words[1].start, 1500 * ms);
    expect(words[1].end, 2000 * ms);
  });

  test('parseKrc: skips tag lines', () {
    final out = parseKrc('[ti:Title]\n[offset:0]\n[100,200]<0,200,0>x');
    expect(out.length, 1);
    expect(out[0].text, 'x');
  });

  test('lyricsTextMatch: rejects clearly different songs, accepts the same, skips few Latin words', () {
    final a = [l(0, null, 'never gonna give you up never gonna let you down')];
    final b = [l(0, null, 'bohemian rhapsody scaramouche fandango galileo figaro')];
    expect(lyricsTextMatch(a, b), isFalse);
    expect(lyricsTextMatch(a, a), isTrue);
    expect(lyricsTextMatch([l(0, null, '君の名は')], [l(0, null, 'completely different english words here')]), isTrue);
    expect(lyricsTextMatch(null, a), isTrue);
  });

  test('isEmphasisWord: held a second or more, and short enough to be a held note', () {
    expect(isEmphasisWord(w('ohhh', 0, 1.2)), isTrue);
    expect(isEmphasisWord(w('ohhh', 0, 0.6)), isFalse);
    expect(isEmphasisWord(w('ohhh ', 0, 1)), isTrue);
    expect(isEmphasisWord(w('extraordinarily', 0, 1.5)), isFalse);
    expect(isEmphasisWord(LyricWord(0, null, 'x')), isFalse);
    expect(isEmphasisWord(w('!', 0, 2)), isFalse);
  });

  test('currentLyricIndex: promotes once the lead is sung, when there is no background', () {
    final lines = parseLRC('[00:10.00]<00:10.00>one <00:11.00>two\n[00:20.00]next');
    lines[0].words![1].end = 12 * sec;
    expect(currentLyricIndex(lines, 0, (11.5 * sec).round()), 0);
    expect(currentLyricIndex(lines, 0, (12.5 * sec).round()), 1);
  });

  test('currentLyricIndex: waits for background vocals before promoting early', () {
    final lines = [
      l(10, 12, 'lead', words: [w('lead', 10, 12)], bg: [w('ooh', 12, 15)]),
      l(20, 22, 'next', words: [w('next', 20, 22)]),
    ];
    expect(currentLyricIndex(lines, 0, 13 * sec), 0);
    expect(currentLyricIndex(lines, 0, (15.5 * sec).round()), 1);
  });

  test('background vocals running into the next line light both as a group', () {
    final lines = [
      l(10, 12, 'lead', words: [w('lead', 10, 12)], bg: [w('ooh', 12, 21)]),
      l(13, 16, 'next', words: [w('next', 13, 16)]),
    ];
    int t(num s) => (s * sec).round();
    expect(currentLyricIndex(lines, 1, t(14)), 1);
    expect(activeLyricRange(lines, 1, t(14)), (0, 1));
    expect(activeLyricRange(lines, 1, t(15.5)), (0, 1));
    expect(activeLyricRange(lines, 1, t(16.5)), (0, 1));
    expect(activeLyricRange(lines, 1, t(21.5)), (0, 1));
    expect(activeLyricRange(lines, 1, t(21.8)), (1, 1));
  });

  test('activeLyricRange: a line starting inside the previous one keeps it lit until 0.7s after it is sung', () {
    int t(num s) => (s * sec).round();
    final lines = [l(0, 5, 'before'), l(10, 14, 'A'), l(12, 16, 'B'), l(20, 22, 'after')];
    expect(layerLingerTicks, (0.7 * sec).round());
    expect(activeLyricRange(lines, 2, t(13)), (1, 2));
    expect(activeLyricRange(lines, 2, t(14.6)), (1, 2));
    expect(activeLyricRange(lines, 2, t(14.7)), (2, 2));
    expect(activeLyricRange(lines, 2, t(16.5)), (2, 2));
    expect(activeLyricRange(lines, 1, t(11)), (1, 1));
  });

  test('activeLyricRange: only lines still sung when the current one began, not a chain', () {
    int t(num s) => (s * sec).round();
    expect(activeLyricRange([l(0, 6, 'x'), l(4, 9, 'x'), l(8, 12, 'x')], 2, t(9.5)), (1, 2));
    expect(activeLyricRange([l(0, 6, 'x'), l(4, 9, 'x'), l(8, 12, 'x')], 2, t(10)), (2, 2));
    expect(activeLyricRange([l(0, 12, 'x'), l(4, 12, 'x'), l(8, 12, 'x')], 2, t(10)), (0, 2));
    expect(activeLyricRange([l(0, null, 'x'), l(1, null, 'x')], 1, t(2)), (1, 1));
  });

  test('activeLyricRange: each earlier line dims on its own end, and the range stays contiguous', () {
    int t(num s) => (s * sec).round();
    final lines = [l(0, 14, 'x'), l(4, 11, 'x'), l(8, 16, 'x')];
    expect(activeLyricRange(lines, 2, t(11.5)), (0, 2));
    expect(activeLyricRange(lines, 2, t(14.5)), (0, 2));
    expect(activeLyricRange(lines, 2, t(14.7)), (2, 2));
  });

  test('tightScrollTarget: a close next line pulls the scroll early, an overlap or a wide gap does not', () {
    int s(num x) => (x * sec).round();
    final lines = [l(0, 2, 'a'), l(2.3, 4, 'b'), l(5, 7, 'c'), l(6.5, 8, 'd')];
    final lead = s(0.4);
    expect(tightScrollTarget(lines, 0, s(1.95), lead), 1);
    expect(tightScrollTarget(lines, 0, s(1.8), lead), isNull);
    expect(tightScrollTarget(lines, 1, s(4.8), lead), isNull);
    expect(tightScrollTarget(lines, 2, s(6.4), lead), isNull);
    expect(tightScrollTarget(lines, 0, s(1.95), 0), isNull);
    expect(tightScrollTarget([l(0, null, 'a'), l(1, null, 'b')], 0, s(0.9), lead), isNull);
  });

  test('looksInstrumental reads the title, album and genres', () {
    expect(looksInstrumental({'Name': 'Blue (Instrumental)'}), isTrue);
    expect(looksInstrumental({'Name': 'Blue - Instrumental Version'}), isTrue);
    expect(looksInstrumental({'Name': 'Blue', 'Album': 'Blue (Instrumentals)'}), isTrue);
    expect(looksInstrumental({'Name': 'Blue (Off Vocal)'}), isTrue);
    expect(looksInstrumental({'Name': 'Blue [Inst.]'}), isTrue);
    expect(
      looksInstrumental({
        'Name': 'Blue',
        'Genres': ['Pop', 'Instrumental'],
      }),
      isTrue,
    );
    expect(
      looksInstrumental({
        'Name': 'Blue',
        'Album': 'Instruments of Love',
        'Genres': ['Pop'],
      }),
      isFalse,
    );
    expect(looksInstrumental({'Name': 'Install Me'}), isFalse);
    expect(looksInstrumental(null), isFalse);
  });

  test('instrumental breaks: a long intro, and gaps after a line with a known end', () {
    LyricLine l(double at, [double? end]) => LyricLine((at * 1e7).round(), end == null ? null : (end * 1e7).round(), 'x', null);
    expect(interludes([l(8, 10), l(11, 13), l(25, 27), l(28)]), [
      (before: 0, start: 0, end: 80000000),
      (before: 2, start: 130000000, end: 250000000),
    ]);
    expect(interludes([l(2), l(20)]), isEmpty, reason: 'no known end: a held note looks the same');
    expect(interludes([l(2, 4), l(9)]), isEmpty, reason: 'five seconds is a breath');
  });

  test('an empty timed LRC line ends the line before it', () {
    final lines = parseLRC('[00:01.00]Hello\n[00:03.00]\n[00:15.00]World');
    expect(lines.map((x) => x.text), ['Hello', 'World']);
    expect(lines.first.end, 30000000);
    expect(interludes(lines).single, (before: 1, start: 30000000, end: 150000000));
  });
}
