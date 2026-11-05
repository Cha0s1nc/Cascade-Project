// Jellyfin Media Segments (10.10+): typed time ranges in a video, such as an
// intro or the end credits, a client can offer to skip. Pure. Ported from
// desktop/src/core/media-segments.ts. A 404 or empty list means nothing to show.

const _ticksPerSec = 10000000;

const _knownTypes = {'Intro', 'Outro', 'Recap', 'Preview', 'Commercial'};

/// A segment as the player uses it, in seconds. [type] is Intro, Outro, Recap, Preview or Commercial.
typedef MediaSegment = ({String type, double startSec, double endSec});

// Recap and commercial have no agreed meaning for "skip", so they are parsed and left alone.
const _skippable = {'Intro', 'Outro'};

/// The segments out of a `/MediaSegments/{id}` response, sorted by start. Unknown types and bad ranges are dropped: the body comes from a server plugin.
List<MediaSegment> parseMediaSegments(Object? raw) {
  final items = raw is Map ? raw['Items'] : null;
  if (items is! List) return [];
  final out = <MediaSegment>[];
  for (final it in items) {
    if (it is! Map) continue;
    final type = it['Type'], start = it['StartTicks'], end = it['EndTicks'];
    if (type is! String || !_knownTypes.contains(type)) continue;
    if (start is! num || end is! num || !start.isFinite || !end.isFinite || start < 0 || end <= start) continue;
    out.add((type: type, startSec: start / _ticksPerSec, endSec: end / _ticksPerSec));
  }
  final pos = {for (var i = 0; i < out.length; i++) i: out[i]};
  final idx = [for (var i = 0; i < out.length; i++) i]..sort((a, b) {
      final x = pos[a]!, y = pos[b]!;
      final c = x.startSec.compareTo(y.startSec);
      if (c != 0) return c;
      final d = x.endSec.compareTo(y.endSec);
      return d != 0 ? d : a.compareTo(b);
    });
  return [for (final i in idx) out[i]];
}

/// The skippable segment playing at [sec], or null. Start is inside, end is not. Where segments overlap the one that ends last wins.
MediaSegment? activeSegment(List<MediaSegment> segments, double sec) {
  if (!sec.isFinite) return null;
  MediaSegment? best;
  for (final s in segments) {
    if (!_skippable.contains(s.type)) continue;
    if (sec >= s.startSec && sec < s.endSec && (best == null || s.endSec > best.endSec)) best = s;
  }
  return best;
}

/// The button's label: "Skip Intro", "Skip Credits".
String skipLabel(MediaSegment segment) => segment.type == 'Outro' ? 'Skip Credits' : 'Skip Intro';

/// What skipping does: kind 'seek' to [sec], or 'next' (sec is null).
typedef SkipAction = ({String kind, double? sec});

/// Within this many seconds of the end counts as "runs to the end".
const segmentEndSlackSec = 1.0;

/// An outro that runs to the end of the item means "go on to what is next"; everything else seeks to the segment's end.
SkipAction skipAction(MediaSegment segment, double durationSec) {
  final toTheEnd = segment.type == 'Outro' && durationSec > 0 && segment.endSec >= durationSec - segmentEndSlackSec;
  return toTheEnd ? (kind: 'next', sec: null) : (kind: 'seek', sec: segment.endSec);
}

/// A stable key for "this segment of this item", so auto-skip fires once.
String segmentKey(String itemId, MediaSegment segment) => '$itemId:${segment.type}:${_js(segment.startSec)}';

/// A double the way JS prints it: no trailing ".0".
String _js(double v) => v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();
