// The player. Signed in, it plays through media_kit (libmpv) on two decks,
// like the desktop: the next track loads paused on the idle deck ahead of
// time, then fades in as the current one fades out, which hides the gap mpv
// leaves between tracks. In the demo and in tests it only pretends, keeping
// time with a 1 s timer, since there is nothing to stream.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'data.dart';
import 'jellyfin.dart';
import 'log.dart';

/// The desktop's three repeat modes, in the order the button cycles them.
enum Repeat { off, all, one }

/// The overlap at a track change. ponytail: fixed for now; the desktop makes
/// it a 1-15 s crossfade setting, and this would read that setting.
const crossfadeSecs = 1.0;

/// A skip fades the old track out this fast (the desktop's SKIP_FADE_SECS).
const skipFadeSecs = 0.3;

/// How early the next track starts loading on the idle deck.
const _preloadSecs = 20.0;

class _Deck {
  _Deck(this.p);
  final mk.Player p;
  String? id; // the song loaded on it
  bool loaded = false;
  Future<void>? loading;
  double gain = 1; // the fade envelope; the deck plays at volume * gain
  double length = 0; // seconds, as the engine found it
}

class Player extends ChangeNotifier {
  /// [audio] false: the pretend player, for the demo and widget tests.
  Player({bool audio = true}) {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    if (audio) {
      _init();
    } else {
      queue = const [weirdFishes, reckoner, ...demoRecentlyPlayed];
      _order = List.generate(queue.length, (i) => i);
      song = weirdFishes;
      position = 134;
      playing = true;
    }
  }

  late final Timer _timer;
  final _decks = <_Deck>[];
  int _cur = 0;
  Timer? _fadeTimer;
  bool _fading = false;
  final _subs = <StreamSubscription>[];

  /// Set once signed in; streams need its auth header.
  Jellyfin? jf;

  Song? song;
  List<Song> queue = const [];
  List<int> _order = const []; // play order, as indexes into queue
  int _pos = 0; // where in _order we are
  double position = 0;
  bool playing = false, shuffle = false;
  Repeat repeat = Repeat.off;
  double volume = 0.7;
  String? error;
  final liked = <String>{};

  /// Streaming for real, rather than pretending for the demo.
  bool get _real => _decks.isNotEmpty && jf != null;
  _Deck get _deck => _decks[_cur];
  _Deck get _idle => _decks[1 - _cur];

  bool get isLiked => song != null && liked.contains(song!.id.isEmpty ? song!.title : song!.id);

  /// Seconds: what the engine found, else the server's runtime.
  double get length => _real && _deck.length > 0 ? _deck.length : (song?.seconds ?? 0).toDouble();

  Future<void> _init() async {
    for (var i = 0; i < 2; i++) {
      final d = _Deck(
        mk.Player(
          configuration: mk.PlayerConfiguration(
            title: 'Cascade',
            logLevel: Platform.environment['CASCADE_MPV_LOG'] == 'v' ? mk.MPVLogLevel.v : mk.MPVLogLevel.warn,
          ),
        ),
      );
      _decks.add(d);
      final native = d.p.platform;
      // mpv could not create its file cache; keep it in memory.
      if (native is mk.NativePlayer) await native.setProperty('cache-on-disk', 'no');
      await _applyVolume(d);
      _subs.addAll([
        d.p.stream.log.listen((l) => log('mpv[$i] ${l.level} ${l.prefix}: ${l.text.trim()}')),
        d.p.stream.playing.listen((v) {
          if (d != _deck) return;
          playing = v;
          notifyListeners();
        }),
        d.p.stream.position.listen((p) => _onPosition(d, p.inMilliseconds / 1000)),
        d.p.stream.duration.listen((x) => d.length = x.inMilliseconds / 1000),
        d.p.stream.completed.listen((done) {
          if (done && d == _deck) _ended();
        }),
        d.p.stream.error.listen((e) {
          log('deck $i error: $e');
          if (d != _deck) return;
          error = e;
          notifyListeners();
        }),
      ]);
    }
  }

  // The queue ----------------------------------------------------------------

  Song? _at(int? pos) => pos == null || _order.isEmpty ? null : queue[_order[pos]];

  /// What plays when this track ends on its own.
  int? get _autoNext {
    if (_order.isEmpty) return null;
    if (repeat == Repeat.one) return _pos;
    if (_pos + 1 < _order.length) return _pos + 1;
    return repeat == Repeat.all ? 0 : null;
  }

  List<int> _shuffled(int first) => [first, ...(List.generate(queue.length, (i) => i)..remove(first))..shuffle()];

  Future<void> play(Song s, [List<Song>? from]) async {
    if (from != null) queue = from;
    final i = max(0, queue.indexOf(s));
    _order = shuffle ? _shuffled(i) : List.generate(queue.length, (k) => k);
    await _startAt(shuffle ? 0 : i);
  }

  Future<void> next() async {
    final n = _pos + 1 < _order.length ? _pos + 1 : (repeat == Repeat.off ? null : 0);
    if (n != null) await _startAt(n, fadeOut: true);
  }

  Future<void> prev() async {
    if (position >= 3 || song == null) return seek(0);
    final n = _pos > 0 ? _pos - 1 : (repeat == Repeat.all ? _order.length - 1 : 0);
    await _startAt(n, fadeOut: true);
  }

  void _ended() {
    final n = _autoNext;
    if (n != null) {
      _startAt(n);
    } else {
      playing = false;
      notifyListeners();
    }
  }

  // The decks ----------------------------------------------------------------

  Future<void> _applyVolume(_Deck d) => d.p.setVolume(volume * d.gain * 100);

  Future<void> _load(_Deck d, Song s) {
    if (d.id == s.id && d.loading != null) return d.loading!;
    final j = jf!;
    d
      ..id = s.id
      ..loaded = false
      ..length = 0;
    return d.loading = d.p.open(mk.Media(j.stream(s.id), httpHeaders: j.headers), play: false).then((_) {
      if (d.id == s.id) d.loaded = true;
    });
  }

  void _unload(_Deck d) {
    d
      ..id = null
      ..loaded = false
      ..loading = null
      ..gain = 1;
    d.p.stop();
  }

  /// Play the track at [pos] now, on the idle deck (reusing it if that track
  /// is already loaded there). A skip fades the old one out briefly.
  Future<void> _startAt(int pos, {bool fadeOut = false}) async {
    _pos = pos;
    song = _at(pos);
    position = 0;
    error = null;
    playing = true;
    notifyListeners();
    final s = song;
    if (!_real || s == null) return;
    log('start ${s.title}${fadeOut ? ' (skip)' : ''}');
    _fadeTimer?.cancel();
    _fading = false;
    final out = _deck, inc = _idle;
    await _load(inc, s);
    if (song != s) return; // another start came in while this one loaded
    inc.gain = 1;
    await _applyVolume(inc);
    _cur = 1 - _cur;
    await inc.p.play();
    if (fadeOut && out.id != null) {
      _ramp(out, inc, skipFadeSecs, equalPower: false);
    } else if (out.id != null) {
      _unload(out);
    }
  }

  void _onPosition(_Deck d, double s) {
    if (d != _deck) return;
    final changed = s.floor() != position.floor();
    position = s;
    if (changed) notifyListeners();
    final next = _at(_autoNext);
    if (!_real || next == null || !playing || _fading || length <= 0) return;
    final remaining = length - s;
    if (remaining <= _preloadSecs && _idle.id != next.id) _load(_idle, next);
    if (remaining <= crossfadeSecs && _idle.id == next.id && _idle.loaded) _crossfade();
  }

  Future<void> _crossfade() async {
    final n = _autoNext;
    if (n == null) return;
    _fading = true;
    final out = _deck, inc = _idle;
    inc.gain = 0;
    await _applyVolume(inc);
    await inc.p.play();
    // Hand over as the fade starts, so the UI follows the incoming track.
    _cur = 1 - _cur;
    _pos = n;
    song = _at(n);
    position = 0;
    log('crossfade to ${song?.title}');
    notifyListeners();
    _ramp(out, inc, crossfadeSecs, equalPower: true);
  }

  /// Fade [out] down and [inc] up over [secs]. Equal power (cos/sin, the
  /// desktop's crossfade.ts curve) keeps the summed loudness level; a skip's
  /// fade-out is a plain line with the new track already at full.
  void _ramp(_Deck out, _Deck inc, double secs, {required bool equalPower}) {
    _fadeTimer?.cancel();
    _fading = true;
    final start = DateTime.now();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 20), (t) {
      final x = min(1.0, DateTime.now().difference(start).inMilliseconds / (secs * 1000));
      out.gain = equalPower ? cos(x * pi / 2) : 1 - x;
      inc.gain = equalPower ? sin(x * pi / 2) : 1;
      _applyVolume(out);
      _applyVolume(inc);
      if (x < 1) return;
      t.cancel();
      _fading = false;
      _unload(out);
    });
  }

  void _tick() {
    if (_real || !playing || song == null) return;
    if (++position >= song!.seconds) return _ended();
    notifyListeners();
  }

  // Controls -----------------------------------------------------------------

  Future<void> setPlaying(bool on) async {
    if (!_real) {
      playing = on;
      notifyListeners();
      return;
    }
    if (!on && _fading) {
      // Pausing mid-fade: drop the outgoing track, keep the incoming at full.
      _fadeTimer?.cancel();
      _fading = false;
      _unload(_idle);
      _deck.gain = 1;
      await _applyVolume(_deck);
    }
    await (on ? _deck.p.play() : _deck.p.pause());
  }

  Future<void> toggle() => setPlaying(!playing);

  Future<void> seek(double seconds) async {
    position = seconds;
    notifyListeners();
    if (_real) await _deck.p.seek(Duration(milliseconds: (seconds * 1000).round()));
  }

  Future<void> setVolume(double v) async {
    volume = v;
    notifyListeners();
    for (final d in _decks) {
      await _applyVolume(d);
    }
  }

  Future<void> toggleShuffle() async {
    shuffle = !shuffle;
    if (_order.isNotEmpty) {
      final current = _order[_pos];
      _order = shuffle ? _shuffled(current) : List.generate(queue.length, (i) => i);
      _pos = shuffle ? 0 : current;
    }
    log('shuffle $shuffle');
    notifyListeners();
  }

  void toggleRepeat() {
    repeat = Repeat.values[(repeat.index + 1) % Repeat.values.length];
    log('repeat $repeat');
    notifyListeners();
  }

  /// Local only for now: favorites are not sent to the server yet.
  void toggleLike() {
    final s = song;
    if (s == null) return;
    final key = s.id.isEmpty ? s.title : s.id;
    if (!liked.remove(key)) liked.add(key);
    notifyListeners();
  }

  Future<void> stop() async {
    _fadeTimer?.cancel();
    _fading = false;
    for (final d in _decks) {
      _unload(d);
    }
    song = null;
    queue = const [];
    _order = const [];
    position = 0;
    playing = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer.cancel();
    _fadeTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    for (final d in _decks) {
      d.p.dispose();
    }
    super.dispose();
  }
}

class PlayerScope extends InheritedNotifier<Player> {
  const PlayerScope({super.key, required Player player, required super.child}) : super(notifier: player);

  /// Rebuilds the caller on every change (once a second while playing).
  static Player of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PlayerScope>()!.notifier!;

  /// For callbacks: no rebuilds.
  static Player read(BuildContext context) => context.getInheritedWidgetOfExactType<PlayerScope>()!.notifier!;
}
