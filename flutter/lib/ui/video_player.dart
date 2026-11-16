// The video player: media_kit's video output with Cascade's own controls.
// Plays the file as it is (mpv decodes nearly everything), resumes where you
// left off, reports to the server like the music does, offers the file's
// audio and subtitle tracks, marks chapters on the seek bar, shows Skip
// Intro and Skip Credits from the server's media segments (or skips them by
// itself with the setting on), and goes on to the next episode.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'package:cascade/ui/pages/browse.dart' show fromStartKey;
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/library.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/core/media_segments.dart';
import 'package:cascade/core/playback.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/title_bar.dart';
import 'package:cascade/ui/widgets.dart';

/// Open [item] (a movie or an episode) full screen.
void openVideoPlayer(BuildContext context, Item item) {
  final lib = LibraryScope.read(context);
  final player = PlayerScope.read(context);
  if (player.playing) player.setPlaying(false);
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => VideoScreen(item: item, library: lib, settings: player.settings),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ),
  );
}

typedef _Chapter = ({String name, double sec});

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.item, required this.library, required this.settings});
  final Item item;
  final Library library;
  final Settings settings;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  final _p = mk.Player(
    configuration: mk.PlayerConfiguration(logLevel: Platform.environment['CASCADE_MPV_LOG'] == 'v' ? mk.MPVLogLevel.v : mk.MPVLogLevel.warn),
  );
  // CASCADE_SOFTWARE_VIDEO=1 draws frames on the CPU, for machines (and
  // VMs) whose GPU path shows a black picture.
  late final _vc = VideoController(
    _p,
    configuration: VideoControllerConfiguration(enableHardwareAcceleration: Platform.environment['CASCADE_SOFTWARE_VIDEO'] != '1'),
  );
  final _subs = <StreamSubscription>[];
  Item _item = const {};
  double _pos = 0, _len = 0;
  bool _playing = false, _controls = true, _full = false, _started = false;
  List<MediaSegment> _segments = const [];
  List<_Chapter> _chapters = const [];
  Item? _next;
  final _skipped = <String>{};
  Timer? _hide, _progress;

  Jellyfin get _jf => widget.library.jf!;
  String get _id => _item['Id'] as String? ?? widget.item['Id'] as String;

  @override
  void initState() {
    super.initState();
    _subs.addAll([
      _p.stream.position.listen((d) {
        _pos = d.inMilliseconds / 1000;
        _segmentCheck();
        if (mounted) setState(() {});
      }),
      _p.stream.duration.listen((d) => setState(() => _len = d.inMilliseconds / 1000)),
      _p.stream.playing.listen((v) {
        setState(() => _playing = v);
        _report('progress');
      }),
      _p.stream.completed.listen((done) {
        if (done) _ended();
      }),
      _p.stream.tracks.listen((_) => mounted ? setState(() {}) : null),
      _p.stream.error.listen((e) => log('video error: $e')),
      _p.stream.log.listen((l) => log('video mpv ${l.level} ${l.prefix}: ${l.text.trim()}')),
      _p.stream.buffering.listen((b) => log('video buffering $b')),
    ]);
    widget.settings.addListener(_applyEq);
    _applyEq();
    _start(widget.item);
    _wake();
  }

  /// The Video equalizer, as the music one: an mpv audio filter.
  Future<void> _applyEq() async {
    final native = _p.platform;
    if (native is! mk.NativePlayer) return;
    final s = widget.settings;
    try {
      await native.setProperty('af', s.eqEnabled ? eqFilter(s.eqVideo) : '');
    } catch (e) {
      log('video EQ filter refused: $e');
    }
  }

  Future<void> _start(Item item) async {
    final full = await widget.library.item(item['Id'] as String) ?? item;
    if (!mounted) return;
    final id = full['Id'] as String;
    final resume = item[fromStartKey] == true ? 0 : ((full['UserData'] as Map?)?['PlaybackPositionTicks'] as num? ?? 0) / 1e7;
    setState(() {
      _item = full;
      _chapters = [
        for (final c in (full['Chapters'] as List? ?? const []).cast<Map>())
          (name: c['Name'] as String? ?? '', sec: (c['StartPositionTicks'] as num? ?? 0) / 1e7),
      ];
      _segments = const [];
      _next = null;
      _started = false;
    });
    await _p.open(
      mk.Media(
        '${_jf.server}/Videos/$id/stream?static=true',
        httpHeaders: _jf.headers,
        start: resume > 30 ? Duration(milliseconds: (resume * 1000).round()) : null,
      ),
    );
    _report('start');
    _started = true;
    _progress?.cancel();
    _progress = Timer.periodic(progressInterval, (_) => _report('progress'));
    _jf.get('/MediaSegments/$id').then((r) => mounted ? setState(() => _segments = parseMediaSegments(r)) : null, onError: (_) {});
    if (full['Type'] == 'Episode' && full['SeriesId'] != null) {
      _jf.get('/Shows/${full['SeriesId']}/Episodes', {'userId': _jf.userId, 'startItemId': id, 'limit': 2}).then((r) {
        final eps = ((r as Map)['Items'] as List).cast<Item>();
        if (mounted && eps.length > 1) setState(() => _next = eps[1]);
      }, onError: (_) {});
    }
  }

  void _report(String kind) {
    if (!_started || widget.library.jf == null) return;
    if (widget.settings.noReports) return;
    final body = kind == 'stop'
        ? {'ItemId': _id, 'PositionTicks': ticks(_pos)}
        : {
            ...playbackReport(itemId: _id, positionSec: _pos, paused: !_playing, volume: _p.state.volume / 100, mediaType: 'Video'),
            if (kind == 'progress') 'EventName': _playing ? 'TimeUpdate' : 'Pause',
          };
    final path = switch (kind) {
      'start' => '/Sessions/Playing',
      'progress' => '/Sessions/Playing/Progress',
      _ => '/Sessions/Playing/Stopped',
    };
    _jf.post(path, body).catchError((Object e) => log('video report $kind failed: $e'));
  }

  MediaSegment? get _segment => activeSegment(_segments, _pos);

  void _segmentCheck() {
    final s = _segment;
    if (s == null || !widget.settings.autoSkipSegments) return;
    if (_skipped.add(segmentKey(_id, s))) _skip(s);
  }

  void _skip(MediaSegment s) {
    final a = skipAction(s, _len);
    if (a.kind == 'next' && _next != null) {
      _playNext();
    } else if (a.sec != null) {
      _p.seek(Duration(milliseconds: (a.sec! * 1000).round()));
    }
  }

  void _ended() {
    _report('stop');
    if (_next != null) {
      _playNext();
    } else {
      _close();
    }
  }

  void _playNext() {
    final n = _next;
    if (n == null) return;
    _report('stop');
    _start(n);
  }

  Future<void> _close() async {
    if (_full) await _toggleFull();
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _toggleFull() async {
    _full = !_full;
    if (inlineTitleBar) {
      await windowManager.setFullScreen(_full);
    } else if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(_full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    }
    if (mounted) setState(() {});
  }

  void _wake() {
    if (!_controls) setState(() => _controls = true);
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing) setState(() => _controls = false);
    });
  }

  void _seekBy(double sec) => _p.seek(Duration(milliseconds: ((_pos + sec).clamp(0, _len) * 1000).round()));

  @override
  void dispose() {
    widget.settings.removeListener(_applyEq);
    _report('stop');
    _hide?.cancel();
    _progress?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _p.dispose();
    if (_full && inlineTitleBar) windowManager.setFullScreen(false);
    if (_full && Platform.isAndroid) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // The desktop's video keys (renderer.js): Space or K, J and L, arrows, M,
  // F, C, S, 0 to 9, Home and End, Ctrl+arrows for chapters, Esc.
  Map<ShortcutActivator, VoidCallback> get _keys => {
    const SingleActivator(LogicalKeyboardKey.space): _p.playOrPause,
    const SingleActivator(LogicalKeyboardKey.keyK): _p.playOrPause,
    const SingleActivator(LogicalKeyboardKey.keyJ): () => _seekBy(-10),
    const SingleActivator(LogicalKeyboardKey.keyL): () => _seekBy(10),
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seekBy(-5),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seekBy(5),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _p.setVolume((_p.state.volume + 5).clamp(0, 100)),
    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _p.setVolume((_p.state.volume - 5).clamp(0, 100)),
    const SingleActivator(LogicalKeyboardKey.keyM): () => _p.setVolume(_p.state.volume > 0 ? 0 : 100),
    const SingleActivator(LogicalKeyboardKey.keyF): _toggleFull,
    const SingleActivator(LogicalKeyboardKey.keyC): _toggleSubs,
    const SingleActivator(LogicalKeyboardKey.keyS): () => _segment == null ? null : _skip(_segment!),
    const SingleActivator(LogicalKeyboardKey.home): () => _p.seek(Duration.zero),
    const SingleActivator(LogicalKeyboardKey.escape): _close,
    const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): () => _chapter(-1),
    const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): () => _chapter(1),
    for (var n = 0; n <= 9; n++)
      SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + n)): () => _p.seek(Duration(milliseconds: (_len * n / 10 * 1000).round())),
  };

  void _chapter(int dir) {
    if (_chapters.isEmpty) return;
    final i = _chapters.lastIndexWhere((c) => c.sec <= _pos + 1);
    final to = (i + dir).clamp(0, _chapters.length - 1);
    _p.seek(Duration(milliseconds: (_chapters[to].sec * 1000).round()));
  }

  void _toggleSubs() {
    final t = _p.state.track.subtitle;
    final subs = _p.state.tracks.subtitle.where((s) => s.id != 'no' && s.id != 'auto').toList();
    _p.setSubtitleTrack(t.id == 'no' || subs.isEmpty ? (subs.firstOrNull ?? mk.SubtitleTrack.no()) : mk.SubtitleTrack.no());
  }

  String _trackLabel(String? title, String? language, String id) =>
      [if (title != null && title.isNotEmpty) title, if (language != null && language.isNotEmpty) language].join(' · ').ifEmpty('Track $id');

  @override
  Widget build(BuildContext context) {
    final title = _item['Type'] == 'Episode'
        ? '${_item['SeriesName'] ?? ''} · S${_item['ParentIndexNumber'] ?? '?'} E${_item['IndexNumber'] ?? '?'} · ${_item['Name'] ?? ''}'
        : _item['Name'] as String? ?? widget.item['Name'] as String? ?? '';
    final seg = _segment;
    final nearEnd = _next != null && _len > 0 && _len - _pos < 30;
    return CallbackShortcuts(
      bindings: _keys,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            cursor: _controls ? MouseCursor.defer : SystemMouseCursors.none,
            onHover: (_) => _wake(),
            child: GestureDetector(
              onTap: () => _controls ? _p.playOrPause() : _wake(),
              onDoubleTap: _toggleFull,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(
                    controller: _vc,
                    controls: NoVideoControls,
                    // Subtitles move up out of the way while the controls show.
                    subtitleViewConfiguration: SubtitleViewConfiguration(padding: EdgeInsets.fromLTRB(24, 0, 24, _controls ? 110 : 36)),
                  ),
                  AnimatedOpacity(
                    opacity: _controls ? 1 : 0,
                    duration: Motion.base,
                    child: IgnorePointer(ignoring: !_controls, child: _chrome(title)),
                  ),
                  if (seg != null || nearEnd)
                    Positioned(
                      right: 32,
                      bottom: 120,
                      child: Pill(
                        seg != null ? skipLabel(seg) : 'Next episode',
                        icon: Icons.skip_next_rounded,
                        onTap: () => seg != null ? _skip(seg) : _playNext(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chrome(String title) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xAA000000), Colors.transparent, Colors.transparent, Color(0xCC000000)],
        stops: [0, 0.2, 0.7, 1],
      ),
    ),
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          children: [
            Row(
              children: [
                IconBtn(Icons.arrow_back_rounded, 'Back', _close, color: Colors.white, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: TitleBarDrag(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(15, w: FontWeight.w600, c: Colors.white),
                    ),
                  ),
                ),
                if (!_full) const WindowButtons(),
              ],
            ),
            const Spacer(),
            LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  ThinBar(
                    value: _len > 0 ? _pos / _len : 0,
                    onChanged: _len > 0 ? (v) => _p.seek(Duration(milliseconds: (v * _len * 1000).round())) : null,
                  ),
                  // Chapter marks along the bar.
                  for (final ch in _chapters)
                    if (_len > 0 && ch.sec > 0)
                      Positioned(
                        left: 6 + (c.maxWidth - 12) * (ch.sec / _len),
                        top: 8,
                        child: IgnorePointer(child: Container(width: 2, height: 4, color: Colors.black54)),
                      ),
                ],
              ),
            ),
            Row(
              children: [
                IconBtn(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, _playing ? 'Pause' : 'Play', _p.playOrPause, color: Colors.white, size: 30),
                IconBtn(Icons.replay_10_rounded, 'Back 10 seconds', () => _seekBy(-10), color: Colors.white, size: 22),
                IconBtn(Icons.forward_10_rounded, 'Forward 10 seconds', () => _seekBy(10), color: Colors.white, size: 22),
                const SizedBox(width: 12),
                Text('${fmt(_pos)} / ${fmt(_len)}', style: ts(12, c: Colors.white70)),
                const Spacer(),
                if (_next != null) IconBtn(Icons.skip_next_rounded, 'Next episode', _playNext, color: Colors.white, size: 22),
                _trackMenu<mk.AudioTrack>(
                  Icons.audiotrack_rounded,
                  'Audio',
                  _p.state.tracks.audio.where((t) => t.id != 'no' && t.id != 'auto').toList(),
                  _p.state.track.audio,
                  (t) => _trackLabel(t.title, t.language, t.id),
                  _p.setAudioTrack,
                ),
                _trackMenu<mk.SubtitleTrack>(
                  Icons.subtitles_outlined,
                  'Subtitles',
                  [mk.SubtitleTrack.no(), ..._p.state.tracks.subtitle.where((t) => t.id != 'no' && t.id != 'auto')],
                  _p.state.track.subtitle,
                  (t) => t.id == 'no' ? 'Off' : _trackLabel(t.title, t.language, t.id),
                  _p.setSubtitleTrack,
                ),
                IconBtn(
                  _full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                  _full ? 'Exit full screen' : 'Full screen',
                  _toggleFull,
                  color: Colors.white,
                  size: 24,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _trackMenu<T>(IconData icon, String tip, List<T> tracks, T current, String Function(T) label, Future<void> Function(T) pick) => tracks.isEmpty
      ? const SizedBox.shrink()
      : PopupMenuButton<T>(
          tooltip: tip,
          icon: Icon(icon, color: Colors.white, size: 22),
          onSelected: pick,
          itemBuilder: (_) => [
            for (final t in tracks)
              PopupMenuItem(
                value: t,
                height: 34,
                child: Row(
                  children: [
                    SizedBox(width: 22, child: t == current ? Icon(Icons.check_rounded, size: 16, color: K.accent) : null),
                    Text(label(t), style: ts(13)),
                  ],
                ),
              ),
          ],
        );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
