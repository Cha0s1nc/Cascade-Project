// The player. Signed in, it plays through media_kit (libmpv) on two decks,
// like the desktop: the next track loads paused on the idle deck ahead of
// time, then fades in as the current one fades out, which hides the gap mpv
// leaves between tracks. It negotiates each stream with the server, reports
// what plays (unless told not to), applies normalization and the EQ, and
// keeps the queue for next launch. In the demo and in tests it only
// pretends, keeping time with a 1 s timer.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/core/playback.dart';
import 'package:cascade/core/settings.dart';

/// The desktop's three repeat modes, in the order the button cycles them.
enum Repeat { off, all, one }

const _repeatNames = {Repeat.off: 'none', Repeat.all: 'all', Repeat.one: 'one'};

/// The overlap at a track change with crossfade off: just enough to hide the
/// gap mpv leaves between files. With crossfade on, its own length.
const gapMaskSecs = 1.0;

/// A skip fades the old track out this fast (the desktop's SKIP_FADE_SECS).
const skipFadeSecs = 0.3;

/// How early the next track starts loading on the idle deck.
const _preloadSecs = 20.0;

class _Deck {
  _Deck(this.p);
  final mk.Player p;
  Song? song; // what is loaded on it
  ResolvedStream? stream;
  bool loaded = false, reported = false;
  Future<void>? loading;
  double gain = 1; // the fade envelope
  double norm = 1; // normalization
  double length = 0, pos = 0; // seconds, as the engine found them

  /// Where a converted stream began (see withStartTicks): the engine counts
  /// from 0 there, so positions add this.
  double offset = 0;
}

class Player extends ChangeNotifier {
  /// [audio] false: the pretend player, for the demo and widget tests.
  Player({bool audio = true, Settings? settings}) : settings = settings ?? Settings.memory() {
    volume = this.settings.volume;
    shuffle = this.settings.shuffle;
    repeat = Repeat.values.firstWhere((r) => _repeatNames[r] == this.settings.repeatMode, orElse: () => Repeat.off);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    this.settings.addListener(_settingsChanged);
    ready = audio ? _init() : Future.value();
    if (!audio) {
      queue = const [weirdFishes, reckoner, ...demoRecentlyPlayed];
      _order = List.generate(queue.length, (i) => i);
      song = weirdFishes;
      position = 134;
      playing = true;
    }
  }

  final Settings settings;

  /// Done once both decks exist.
  late final Future<void> ready;
  late final Timer _timer;
  final _decks = <_Deck>[];
  int _cur = 0;
  Timer? _fadeTimer, _sleepTimer;
  bool _fading = false;
  int _ticks = 0;
  final _subs = <StreamSubscription>[];
  final _normCache = <String, double?>{};

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

  /// The output devices mpv sees, 'auto' first.
  List<mk.AudioDevice> devices = const [];

  /// When the sleep timer stops playback, if it is set by time.
  DateTime? sleepAt;
  bool sleepAtTrackEnd = false;

  /// Streaming for real, rather than pretending for the demo.
  bool get _real => _decks.isNotEmpty && jf != null;
  _Deck get _deck => _decks[_cur];
  _Deck get _idle => _decks[1 - _cur];

  bool get isLiked => song != null && liked.contains(song!.id.isEmpty ? song!.title : song!.id);

  /// Seconds: the server's runtime, else what the engine found. Server first:
  /// while a transcode is still being written, the engine only knows the
  /// length converted so far, which made a track look nearly over at once.
  double get length => (song?.seconds ?? 0) > 0 ? song!.seconds.toDouble() : (_real ? _deck.length : 0);

  double get _overlap => settings.crossfadeEnabled ? settings.crossfadeSeconds.toDouble() : gapMaskSecs;

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
      if (native is mk.NativePlayer) {
        // The cache stays in memory (mpv could not create its file cache), and
        // volume may go past 100 for a normalization boost (see _applyVolume).
        await native.setProperty('cache-on-disk', 'no');
        await native.setProperty('volume-max', '200');
      }
      await _applyVolume(d);
      await _applyEq(d);
      _subs.addAll([
        d.p.stream.log.listen((l) => log('mpv[$i] ${l.level} ${l.prefix}: ${l.text.trim()}')),
        d.p.stream.playing.listen((v) {
          if (d != _deck || v == playing) return;
          playing = v;
          _report('progress', d);
          notifyListeners();
        }),
        d.p.stream.position.listen((p) => _onPosition(d, d.offset + p.inMilliseconds / 1000)),
        d.p.stream.duration.listen((x) => d.length = x.inMilliseconds / 1000),
        d.p.stream.completed.listen((done) {
          if (done && d == _deck) _ended();
        }),
        // A stream that will not play: say so once and stop the deck, rather
        // than let mpv retry it many times a second.
        d.p.stream.error.listen((e) {
          log('deck $i error: $e');
          // A refused seek leaves the stream playing; only a stream that will
          // not load is fatal.
          if (d.song == null || e.contains('seek')) return;
          final current = d == _deck;
          _unload(d);
          if (!current) return;
          error = 'Could not play this: $e';
          playing = false;
          notifyListeners();
        }),
        if (i == 0)
          d.p.stream.audioDevices.listen((list) {
            devices = list;
            _applyDevice();
            notifyListeners();
          }),
      ]);
    }
    _applyDevice();
  }

  void _settingsChanged() {
    for (final d in _decks) {
      _applyEq(d);
    }
    _applyDevice();
  }

  // The queue ------------------------------------------------------------------

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
    if (sleepAtTrackEnd) {
      sleepAtTrackEnd = false;
      playing = false;
      _report('progress', _deck);
      notifyListeners();
      return;
    }
    final n = _autoNext;
    if (n != null) {
      _startAt(n);
    } else if (_real && settings.autoMix) {
      _autoMix();
    } else {
      playing = false;
      _report('stop', _deck);
      notifyListeners();
    }
  }

  /// The queue ran out with auto-mix on: similar tracks to the last one.
  Future<void> _autoMix() async {
    final last = song, j = jf;
    if (last == null || j == null) return;
    try {
      final res = await j.get('/Items/${last.id}/InstantMix', {'UserId': j.userId, 'Limit': 25, 'Fields': 'AlbumId,AlbumPrimaryImageTag'});
      final more = [
        for (final i in ((res as Map)['Items'] as List).cast<Item>())
          if (i['Id'] != last.id) j.song(i),
      ];
      if (more.isEmpty) return;
      final start = queue.length;
      queue = [...queue, ...more];
      _order = [..._order, for (var k = start; k < queue.length; k++) k];
      log('auto-mix added ${more.length}');
      await _startAt(_order.length - more.length);
    } catch (e) {
      log('auto-mix failed: $e');
    }
  }

  // The decks ------------------------------------------------------------------

  /// mpv's volume is cubic (gain = (volume/100)^3), so a linear gain, the
  /// desktop's kind, goes in as its cube root.
  Future<void> _applyVolume(_Deck d) => d.p.setVolume(100 * pow(volume * d.gain * d.norm, 1 / 3).toDouble());

  Future<void> _applyEq(_Deck d) async {
    final native = d.p.platform;
    if (native is! mk.NativePlayer) return;
    try {
      await native.setProperty('af', settings.eqEnabled ? eqFilter(settings.eqMusic) : '');
    } catch (e) {
      log('EQ filter refused: $e');
    }
  }

  /// The chosen output, or the system default while it is not connected.
  void _applyDevice() {
    final want = settings.outputDeviceId;
    final device = devices.where((d) => d.name == want).firstOrNull ?? mk.AudioDevice.auto();
    for (final d in _decks) {
      d.p.setAudioDevice(device);
    }
  }

  Future<void> setOutputDevice(mk.AudioDevice device) async => settings.setOutputDevice(device.name);

  Future<double> _normalization(Song s) async {
    final j = jf;
    if (j == null) return 1;
    Future<double?> db(String id) async {
      if (_normCache.containsKey(id)) return _normCache[id];
      try {
        final v = ((await j.get('/Items/$id', {'userId': j.userId})) as Map)['NormalizationGain'];
        return _normCache[id] = v is num ? v.toDouble() : null;
      } catch (_) {
        return null;
      }
    }

    // Album mode falls back to the track's own gain: Jellyfin writes one onto
    // far fewer albums than tracks.
    double? value;
    if (settings.normalizationSource == 'album' && s.albumId != null) value = await db(s.albumId!);
    value ??= await db(s.id);
    return normalizationGainLinear(value);
  }

  Future<void> _load(_Deck d, Song s, {double startAt = 0}) {
    if (d.song == s && d.loading != null) return d.loading!;
    d
      ..song = s
      ..stream = null
      ..loaded = false
      ..reported = false
      ..length = 0
      ..pos = startAt
      ..offset = 0;
    final j = jf!;
    return d.loading = () async {
      final stream = s.live ? await resolveRadioStream(j, s.id, settings.maxStreamingBitrate) : await resolveStream(j, s.id, settings.maxStreamingBitrate);
      final norm = settings.normalizationEnabled ? await _normalization(s) : 1.0;
      if (d.song != s) return;
      d
        ..stream = stream
        ..norm = norm;
      await _applyVolume(d);
      // A direct file seeks itself; a converted one starts converting there.
      final converted = !stream.direct && startAt > 0;
      d.offset = converted ? startAt : 0;
      await d.p.open(
        mk.Media(
          converted ? withStartTicks(stream.url, startAt) : stream.url,
          httpHeaders: j.headers,
          start: !converted && startAt > 0 ? Duration(milliseconds: (startAt * 1000).round()) : null,
        ),
        play: false,
      );
      if (d.song == s) d.loaded = true;
    }();
  }

  void _unload(_Deck d) {
    _report('stop', d);
    if (d.stream?.direct == false && jf != null) stopActiveEncoding(jf!, d.stream!.playSessionId);
    if (jf != null) closeRadioStream(jf!, d.stream?.liveStreamId);
    d
      ..song = null
      ..stream = null
      ..loaded = false
      ..loading = null
      ..gain = 1;
    d.p.stop();
  }

  /// Play the track at [pos] now, on the idle deck (reusing it if that track
  /// is already loaded there). A skip fades the old one out briefly.
  Future<void> _startAt(int pos, {bool fadeOut = false, double startAt = 0, bool paused = false}) async {
    _pos = pos;
    song = _at(pos);
    position = startAt;
    error = null;
    playing = !paused;
    notifyListeners();
    final s = song;
    if (!_real || s == null) return;
    log('start ${s.title}${fadeOut ? ' (skip)' : ''}');
    _fadeTimer?.cancel();
    _fading = false;
    final out = _deck, inc = _idle;
    await _load(inc, s, startAt: startAt);
    if (song != s) return; // another start came in while this one loaded
    inc.gain = 1;
    await _applyVolume(inc);
    _cur = 1 - _cur;
    if (!paused) {
      await inc.p.play();
      _report('start', inc);
    }
    if (fadeOut && out.song != null) {
      _ramp(out, inc, skipFadeSecs, equalPower: false);
    } else if (out.song != null) {
      _unload(out);
    }
    _saveQueue();
  }

  void _onPosition(_Deck d, double s) {
    d.pos = s;
    if (d != _deck) return;
    final changed = s.floor() != position.floor();
    position = s;
    if (changed) notifyListeners();
    final next = _at(_autoNext);
    if (!_real || next == null || !playing || _fading || sleepAtTrackEnd || length <= 0) return;
    final remaining = length - s;
    if (remaining <= max(_preloadSecs, _overlap + 5) && _idle.song != next) _load(_idle, next);
    if (remaining <= _overlap && _idle.song == next && _idle.loaded) _crossfade();
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
    log('crossfade to ${song?.title} over ${_overlap}s');
    _report('start', inc);
    _saveQueue();
    notifyListeners();
    _ramp(out, inc, _overlap, equalPower: true);
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
    if (_real) {
      // Check in every 10 s while playing, and keep the queue for next time.
      if (playing && ++_ticks % progressInterval.inSeconds == 0) {
        _report('progress', _deck);
        _saveQueue();
      }
      return;
    }
    if (!playing || song == null) return;
    if (++position >= song!.seconds) return _ended();
    notifyListeners();
  }

  // Reporting --------------------------------------------------------------------

  /// Tell the server what [d] is doing: 'start', 'progress' or 'stop'. Best
  /// effort, never awaited; nothing at all with reports turned off.
  void _report(String kind, _Deck d) {
    final j = jf, s = d.song, stream = d.stream;
    if (!_real || j == null || s == null || settings.noReports) return;
    if (kind != 'start' && !d.reported) return;
    final Map<String, Object> body = kind == 'stop'
        ? {'ItemId': s.id, 'PositionTicks': ticks(d.pos), 'PlaySessionId': ?stream?.playSessionId, 'MediaSourceId': ?stream?.mediaSourceId}
        : {
            ...playbackReport(
              itemId: s.id,
              positionSec: d.pos,
              paused: !playing,
              volume: volume,
              playSessionId: stream?.playSessionId,
              mediaSourceId: stream?.mediaSourceId,
              playMethod: stream?.direct == false ? 'Transcode' : 'DirectPlay',
            ),
            if (kind == 'progress') 'EventName': playing ? 'TimeUpdate' : 'Pause',
          };
    d.reported = kind != 'stop';
    final path = switch (kind) {
      'start' => '/Sessions/Playing',
      'progress' => '/Sessions/Playing/Progress',
      _ => '/Sessions/Playing/Stopped',
    };
    j.post(path, body).catchError((Object e) => log('report $kind failed: $e'));
  }

  // The saved queue ----------------------------------------------------------------

  void _saveQueue() {
    if (!_real || _order.isEmpty) return;
    settings.saveLastQueue(savedQueueOf([for (final i in _order) queue[i].id], _pos, position, shuffle ? [for (final s in queue) s.id] : const []));
  }

  /// Put back the queue from last time, paused where it was. Once signed in.
  Future<void> restore() async {
    await ready;
    final j = jf, saved = settings.lastQueue;
    final ids = savedQueueIds(saved);
    if (!_real || j == null || ids.isEmpty || song != null || _restoring) return;
    _restoring = true;
    try {
      final byId = <String, Song>{};
      for (var i = 0; i < ids.length; i += 150) {
        final res = await j.get('/Items', {'userId': j.userId, 'Ids': ids.skip(i).take(150).join(','), 'Fields': 'AlbumId,AlbumPrimaryImageTag'});
        for (final it in ((res as Map)['Items'] as List).cast<Item>()) {
          byId[it['Id'] as String] = j.song(it);
        }
      }
      final r = restoreQueue(saved, byId);
      if (r == null || song != null) return;
      if (shuffle && r.unshuffled.isNotEmpty) {
        queue = r.unshuffled;
        _order = [for (final s in r.queue) queue.indexOf(s)]..removeWhere((i) => i < 0);
      } else {
        queue = r.queue;
        _order = List.generate(queue.length, (i) => i);
      }
      log('restored a queue of ${queue.length}');
      await _startAt(min(r.index, _order.length - 1), startAt: r.positionSec, paused: true);
    } catch (e) {
      log('queue restore failed: $e');
    } finally {
      _restoring = false;
    }
  }

  bool _restoring = false;

  // Controls ------------------------------------------------------------------

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
    if (on && !_deck.reported && _deck.song != null) {
      // First play after a restore: this is where the server hears of it.
      await _deck.p.play();
      _report('start', _deck);
      return;
    }
    await (on ? _deck.p.play() : _deck.p.pause());
  }

  Future<void> toggle() => setPlaying(!playing);

  Future<void> seek(double seconds) async {
    position = seconds;
    notifyListeners();
    if (!_real) return;
    final d = _deck, stream = d.stream;
    if (stream != null && !stream.direct && jf != null) {
      // A converted stream cannot seek: open it again from there.
      d.offset = seconds;
      await d.p.open(mk.Media(withStartTicks(stream.url, seconds), httpHeaders: jf!.headers), play: playing);
    } else {
      await d.p.seek(Duration(milliseconds: (seconds * 1000).round()));
    }
    d.pos = seconds;
    _report('progress', d);
  }

  Future<void> setVolume(double v) async {
    volume = v;
    settings.remember(volume: v);
    notifyListeners();
    for (final d in _decks) {
      await _applyVolume(d);
    }
  }

  Future<void> toggleShuffle() async {
    shuffle = !shuffle;
    settings.remember(shuffle: shuffle);
    if (_order.isNotEmpty) {
      final current = _order[_pos];
      _order = shuffle ? _shuffled(current) : List.generate(queue.length, (i) => i);
      _pos = shuffle ? 0 : current;
    }
    notifyListeners();
  }

  void toggleRepeat() {
    repeat = Repeat.values[(repeat.index + 1) % Repeat.values.length];
    settings.remember(repeatMode: _repeatNames[repeat]);
    notifyListeners();
  }

  /// Pause after [after], or at the end of this track, or never (both null/false).
  void setSleepTimer(Duration? after, {bool atTrackEnd = false}) {
    _sleepTimer?.cancel();
    sleepAt = after == null ? null : DateTime.now().add(after);
    sleepAtTrackEnd = atTrackEnd;
    if (after != null) {
      _sleepTimer = Timer(after, () {
        sleepAt = null;
        setPlaying(false);
        notifyListeners();
      });
    }
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
      if (d.song != null) _unload(d);
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
    _sleepTimer?.cancel();
    settings.removeListener(_settingsChanged);
    for (final s in _subs) {
      s.cancel();
    }
    for (final d in _decks) {
      d.p.dispose();
    }
    super.dispose();
  }
}
