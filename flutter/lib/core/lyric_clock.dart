// The lyrics' clock: the player's position as mpv reports it, carried on
// smoothly between its updates (a few times a second) so a word's wipe moves
// every frame. Pure, given the reported position and the frame time.
//
// Three things it guards against, each of which made the lyrics feel off:
// - Paused, it keeps its reference time fresh: resuming used to extrapolate
//   the whole pause (up to 1 s) until the next update snapped it back.
// - When updates stall (buffering, a transcode starting), it runs ahead no
//   further than twice the usual gap between updates, instead of a second.
// - A new update a little off the running clock is eased in over a few
//   frames rather than jumped to, so the wipe does not twitch on each one.
import 'dart:math';

class LyricClock {
  double _reported = double.nan, _shown = 0;
  Duration? _at, _last;

  /// The usual time between position updates while playing, learned.
  double _gap = 0.1;

  /// Differences under this are eased in; larger ones (a seek) jump.
  static const easeUnder = 0.12;

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
    final ahead = min((elapsed - _at!).inMicroseconds / 1e6, (2 * _gap).clamp(0.15, 1.0));
    final target = _reported + ahead;
    final last = _last;
    _last = elapsed;
    if (last == null) return _shown = target;
    final carried = _shown + (elapsed - last).inMicroseconds / 1e6;
    final off = target - carried;
    if (off.abs() >= easeUnder) return _shown = target;
    // Behind: catch up over a few frames. Ahead: hold until the player
    // catches up, never stepping back (that would replay a word).
    return _shown = off >= 0 ? carried + off * 0.2 : max(_shown, target);
  }
}
