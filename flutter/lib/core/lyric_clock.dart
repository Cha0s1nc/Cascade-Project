// The lyrics' clock: the player's position as mpv reports it, carried on
// smoothly between its updates (a few times a second) so a word's wipe moves
// every frame. Pure, given the reported position and the frame time.
//
// Three things it guards against, each of which made the lyrics feel off:
// - Paused, it keeps its reference time fresh: resuming used to extrapolate
//   the whole pause (up to 1 s) until the next update snapped it back.
// - When updates stall (buffering, a transcode starting), it runs ahead no
//   further than about three of the usual gaps (half a second at least),
//   slowing as it nears that rather than stopping dead.
// - Updates come unevenly (on Linux with PipeWire, late and then in a rush),
//   so it runs at real speed and is steered toward them a little each frame,
//   a touch faster when behind and slower when ahead, never stepping back.
//   Only a seek (half a second or more off) is jumped to. It used to stop at
//   twice the usual gap and snap to any update 0.12 s off, either way: the
//   lyrics froze, then lurched, which a held note's glow showed as a flash.
import 'dart:math';

class LyricClock {
  double _reported = double.nan, _shown = 0;
  Duration? _at, _last;

  /// The usual time between position updates while playing, learned.
  double _gap = 0.1;

  /// Differences this large are a seek, jumped to; smaller ones are steered out.
  static const seekOver = 0.5;

  /// The time to show at frame time [elapsed], from the player's [position]
  /// (seconds) and whether it is [playing].
  double now(double position, bool playing, Duration elapsed) {
    if (position != _reported) {
      final at = _at;
      if (playing && at != null) {
        final seen = (elapsed - at).inMicroseconds / 1e6;
        if (seen > 0 && seen < 2) _gap = _gap * 0.8 + seen * 0.2;
      }
      _reported = position;
      _at = elapsed;
    }
    if (!playing || _at == null) {
      _at = elapsed;
      _last = elapsed;
      return _shown = position;
    }
    final ahead = min((elapsed - _at!).inMicroseconds / 1e6, (3 * _gap).clamp(0.5, 1.0));
    final target = _reported + ahead;
    final last = _last;
    _last = elapsed;
    if (last == null) return _shown = target;
    final carried = _shown + (elapsed - last).inMicroseconds / 1e6;
    final off = target - carried;
    if (off.abs() >= seekOver) return _shown = target;
    // A twentieth of the difference a frame: gentle enough that one late,
    // behind update slows it rather than stopping it. Never back (that would
    // replay a word).
    return _shown = max(_shown, carried + off * 0.05);
  }
}
