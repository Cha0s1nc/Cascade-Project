// Lyric model and parsing: LRC, Enhanced LRC and Kugou KRC, plus which line is
// current. Pure. Ported from desktop/src/core/lyrics.ts. All times are ticks
// (100 ns units, 1 ms = 10,000 ticks), Jellyfin's convention.
import 'dart:math';

/// One timed word. [end] is filled from the next word's start.
class LyricWord {
  int start;
  int? end;
  String text;
  LyricWord(this.start, this.end, this.text);
}

/// One lyric line. [words] is null for plain LRC, set for karaoke formats.
class LyricLine {
  /// Null for untimed (static) lyrics.
  int? start;
  int? end;
  String text;
  List<LyricWord>? words;

  /// Background vocals shown smaller under the line (SpicyLyrics only).
  List<LyricWord>? background;

  /// Sung by the second voice in a duet, drawn on the right (SpicyLyrics only).
  bool opposite;
  LyricLine(this.start, this.end, this.text, this.words, {this.background, this.opposite = false});
}

int? _lastEnd(List<LyricWord>? words) => words != null && words.isNotEmpty ? words.last.end : null;

/// Which line is current, given [baseIdx] (the last line whose start has passed). Once a karaoke line and its background are fully sung, moves to the next.
int currentLyricIndex(List<LyricLine> lines, int baseIdx, int nowTicks) {
  final cur = baseIdx >= 0 && baseIdx < lines.length ? lines[baseIdx] : null;
  if (cur?.words != null && cur!.words!.isNotEmpty && baseIdx + 1 < lines.length) {
    final leadEnd = _lastEnd(cur.words);
    final bgEnd = _lastEnd(cur.background);
    final end = leadEnd == null ? null : max(leadEnd, bgEnd ?? leadEnd);
    if (end != null && nowTicks >= end) return baseIdx + 1;
  }
  return baseIdx;
}

/// How close a line must follow the one before to count as tight (0.5 s).
const tightGapTicks = 5000000;

/// The next line when it is tight and starts within [leadTicks] from now, so the scroll can head there early. Null otherwise.
int? tightScrollTarget(List<LyricLine> lines, int activeIdx, int nowTicks, int leadTicks) {
  if (activeIdx < 0 || activeIdx >= lines.length || activeIdx + 1 >= lines.length || leadTicks <= 0) return null;
  final cur = lines[activeIdx], next = lines[activeIdx + 1];
  final end = lineEndTicks(cur);
  if (end == null) return null;
  if (next.start == null) return null;
  final gap = next.start! - end;
  if (gap < 0 || gap > tightGapTicks) return null;
  return next.start! - nowTicks <= leadTicks ? activeIdx + 1 : null;
}

/// When a line is sung to: the latest of its End, last word and last background word. Null for plain LRC.
int? lineEndTicks(LyricLine line) {
  final ends = [line.end, _lastEnd(line.words), _lastEnd(line.background)].whereType<int>();
  return ends.isEmpty ? null : ends.reduce(max);
}

/// A break with no singing, long enough for the waiting dots: [before] is
/// the line it comes before (0 for an intro), between [start] and [end] in
/// ticks.
typedef Interlude = ({int before, int start, int end});

/// Six seconds: shorter breaks are a breath, not an interlude.
const interludeMinTicks = 60000000;

/// The song's instrumental breaks: a long intro before the first line, and
/// the gaps between a line's known end and the next line's start. A line
/// with no known end (plain LRC without an empty marker line) never counts,
/// since a long held note would look the same.
List<Interlude> interludes(List<LyricLine> lines, {int minTicks = interludeMinTicks}) {
  final out = <Interlude>[];
  final first = lines.firstOrNull?.start;
  if (first != null && first >= minTicks) out.add((before: 0, start: 0, end: first));
  for (var i = 0; i + 1 < lines.length; i++) {
    final end = lineEndTicks(lines[i]), next = lines[i + 1].start;
    if (end != null && next != null && next - end >= minTicks) out.add((before: i + 1, start: end, end: next));
  }
  return out;
}

/// How long an earlier overlapping line stays lit after it is sung (0.7 s).
const layerLingerTicks = 7000000;

/// The lines to show as current, [first, last], around [idx]. Earlier lines that overlap the current one stay lit until [layerLingerTicks] after they end.
(int, int) activeLyricRange(List<LyricLine> lines, int idx, int nowTicks) {
  if (idx < 0 || idx >= lines.length) return (idx, idx);
  final cur = lines[idx];
  var first = idx;
  for (var i = idx - 1; i >= 0; i--) {
    final end = lineEndTicks(lines[i]);
    if (end == null || (cur.start ?? 0) >= end) break;
    if (nowTicks < end + layerLingerTicks) first = i;
  }
  return (first, idx);
}

/// A word held at least this long gets the emphasis glow (1 s).
const emphasisMinTicks = 10000000;

final _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// Whether a karaoke word is a held note: at least a second, and at most 12 letters.
bool isEmphasisWord(LyricWord w) {
  if (w.end == null || w.end! - w.start < emphasisMinTicks) return false;
  final letters = w.text.replaceAll(_notLetterOrDigit, '').runes.length;
  return letters > 0 && letters <= 12;
}

const _ticksPerMs = 10000;
const _lastWordFallbackTicks = 20000000;

int _lrcTimeToTicks(String mm, String ss) => ((int.parse(mm) * 60 + double.parse(ss)) * 10000000).round();

final _lrcLine = RegExp(r'^\[(\d+):(\d+(?:\.\d+)?)\](.*)$');
final _lrcWord = RegExp(r'<(\d+):(\d+(?:\.\d+)?)>([^<\[]*)');
final _hasLetterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

String _trimStart(String s) => s.replaceFirst(RegExp(r'^\s+'), '');
String _trimEnd(String s) => s.replaceFirst(RegExp(r'\s+$'), '');

/// Parses standard LRC (`[mm:ss.xx]text`) or Enhanced LRC (`[..]<mm:ss.xx>word...`) into lines.
List<LyricLine> parseLRC(String text) {
  final lines = <LyricLine>[];
  for (final raw in text.split('\n')) {
    final m = _lrcLine.firstMatch(raw);
    if (m == null) continue;
    final startTicks = _lrcTimeToTicks(m[1]!, m[2]!);
    final content = m[3]!;
    if (content.contains('<')) {
      final words = <LyricWord>[];
      // Per-character sources give every space its own token; keep those as a space.
      var pendingSpace = false;
      for (final wm in _lrcWord.allMatches(content)) {
        final wText = wm[3]!;
        if (wText.isEmpty) continue;
        if (wText.trim().isEmpty) {
          pendingSpace = words.isNotEmpty;
          continue;
        }
        final isSymbol = !_hasLetterOrDigit.hasMatch(wText);
        if (isSymbol && words.isNotEmpty && !pendingSpace) {
          final prev = words.last;
          prev.text = _trimEnd(prev.text) + _trimStart(wText);
        } else {
          if (pendingSpace) words.last.text += ' ';
          words.add(LyricWord(_lrcTimeToTicks(wm[1]!, wm[2]!), null, wText));
        }
        pendingSpace = false;
      }
      for (var i = 0; i < words.length - 1; i++) {
        words[i].end = words[i + 1].start;
      }
      final fullText = words.map((w) => w.text).join().trim();
      if (fullText.isNotEmpty) lines.add(LyricLine(startTicks, null, fullText, words.isNotEmpty ? words : null));
    } else {
      final t = content.trim();
      if (t.isNotEmpty) {
        lines.add(LyricLine(startTicks, null, t, null));
      } else if (lines.isNotEmpty && lines.last.end == null) {
        // An empty timed line marks where the line before stopped: the
        // only end a plain LRC line gets (it shows an instrumental break).
        lines.last.end = startTicks;
      }
    }
  }
  // The last word of each line ends where the next line starts.
  for (var i = 0; i < lines.length; i++) {
    final ws = lines[i].words;
    if (ws == null || ws.isEmpty) continue;
    final last = ws.last;
    last.end ??= i + 1 < lines.length ? lines[i + 1].start : last.start + _lastWordFallbackTicks;
  }
  return lines;
}

final _krcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');
final _krcWord = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');

/// Parses decrypted Kugou KRC: `[start_ms,dur_ms]<off_ms,dur_ms,0>text...`, word offsets relative to the line start.
List<LyricLine> parseKrc(String krcText) {
  final lines = <LyricLine>[];
  for (final rawLine in krcText.split('\n')) {
    final m = _krcLine.firstMatch(rawLine.trim());
    if (m == null) continue;
    final lineStartMs = int.parse(m[1]!);
    final lineEndMs = lineStartMs + int.parse(m[2]!);
    final words = <LyricWord>[];
    var fullText = '';
    for (final wm in _krcWord.allMatches(m[3]!)) {
      final off = int.parse(wm[1]!), dur = int.parse(wm[2]!), wText = wm[3]!;
      if (wText.isEmpty) continue;
      fullText += wText;
      words.add(LyricWord((lineStartMs + off) * _ticksPerMs, (lineStartMs + off + dur) * _ticksPerMs, wText));
    }
    fullText = fullText.trim();
    if (fullText.isEmpty) continue;
    lines.add(LyricLine(lineStartMs * _ticksPerMs, lineEndMs * _ticksPerMs, fullText, words.isNotEmpty ? words : null));
  }
  return lines;
}

final _latinWord = RegExp(r'[a-z]{3,}');

/// Whether two lyric results plausibly are the same song, by word overlap. True when either is missing or has too few Latin words.
bool lyricsTextMatch(List<LyricLine>? a, List<LyricLine>? b) {
  if (a == null || b == null) return true;
  Set<String> words(List<LyricLine> r) => _latinWord.allMatches(r.map((l) => l.text).join(' ').toLowerCase()).map((m) => m[0]!).toSet();
  final aw = words(a), bw = words(b);
  if (aw.length < 5 || bw.length < 5) return true;
  final inter = aw.where(bw.contains).length;
  return inter / min(aw.length, bw.length) >= 0.25;
}

final _instrumentalTag = RegExp(r'\binstrumentals?\b|\boff[\s-]?vocal\b|[(\[]\s*inst\.?\s*[)\]]', caseSensitive: false);

/// Whether a track's own tags (title, album, genres) say it is instrumental.
bool looksInstrumental(Map<String, dynamic>? item) {
  if (item == null) return false;
  final g = item['Genres'];
  return [item['Name'], item['Album'], if (g is List) ...g].any((s) => s is String && s.isNotEmpty && _instrumentalTag.hasMatch(s));
}
