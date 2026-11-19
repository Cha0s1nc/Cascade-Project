// The video player: media_kit's video output with Cascade's own controls.
// Plays the file as it is (mpv decodes nearly everything), resumes where you
// left off, reports to the server like the music does, offers the file's
// audio and subtitle tracks, marks chapters on the seek bar, shows Skip
// Intro and Skip Credits from the server's media segments (or skips them by
// itself with the setting on), and goes on to the next episode.
import 'dart:async';
import 'dart:math';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'package:cascade/ui/pages/browse.dart' show fromStartKey;
import 'package:cascade/ui/pages/common.dart' show narrow;
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/library.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/core/media_segments.dart';
import 'package:cascade/core/playback.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/title_bar.dart';
import 'package:cascade/ui/widgets.dart';

/// True while a video fills the window (not shrunk to its corner window):
/// the phone layout's back shrinks it first (videoBack).
final videoFull = ValueNotifier<bool>(false);
VoidCallback? _shrink;
OverlayEntry? _entry;

/// Back with a video filling the window shrinks it to its corner window.
/// True when it did.
bool videoBack() {
  if (!videoFull.value) return false;
  _shrink?.call();
  return true;
}

/// Open [item] (a movie or an episode) filling the window. It lives in the
/// app's overlay rather than a route, so Back can shrink it to a small window
/// in the corner (picture in picture) while the app goes on underneath; one
/// video at a time.
void openVideoPlayer(BuildContext context, Item item) {
  final lib = LibraryScope.read(context);
  final player = PlayerScope.read(context);
  if (player.playing) player.setPlaying(false);
  _entry
    ?..remove()
    ..dispose();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => VideoScreen(
      item: item,
      library: lib,
      settings: player.settings,
      // Solid while it fills the window, so the app under it is not drawn.
      onSolid: (on) => entry.opaque = on,
      onClose: () {
        if (_entry == entry) _entry = null;
        entry
          ..remove()
          ..dispose();
      },
    ),
  );
  _entry = entry;
  Overlay.of(context, rootOverlay: true).insert(entry);
}

typedef _Chapter = ({String name, double sec});

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.item, required this.library, required this.settings, required this.onClose, required this.onSolid});
  final Item item;
  final Library library;
  final Settings settings;

  /// Stop: take it off the screen (it reports the stop as it goes).
  final VoidCallback onClose;

  /// Whether the app under it can stop being drawn (it fills the window).
  final ValueChanged<bool> onSolid;

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
  Item? _next, _prev;

  /// The volume (0-100) and speed, as mpv last said.
  double _volume = 100, _rate = 1;

  /// Where the pointer is over the seek bar (0-1), for the time above it.
  double? _hoverAt;

  /// The time reads as left rather than gone (click it to switch).
  bool _remaining = false;

  /// Shrunk to the corner window (Back), the app usable around it.
  bool _mini = false;

  /// The pointer is over the corner window (or a touch showed its buttons).
  bool _miniHover = false;
  final _focus = FocusNode(debugLabel: 'video');

  /// What had focus before the video opened, given it back while shrunk.
  FocusNode? _before;
  static const _resize = Duration(milliseconds: 260);

  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
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
      _p.stream.volume.listen((v) => mounted ? setState(() => _volume = v) : null),
      _p.stream.rate.listen((r) => mounted ? setState(() => _rate = r) : null),
      _p.stream.error.listen((e) => log('video error: $e')),
      _p.stream.log.listen((l) => log('video mpv ${l.level} ${l.prefix}: ${l.text.trim()}')),
      _p.stream.buffering.listen((b) => log('video buffering $b')),
    ]);
    widget.settings.addListener(_applyEq);
    _applyEq();
    _start(widget.item);
    _wake();
    _before = FocusManager.instance.primaryFocus;
    videoFull.value = true;
    _shrink = _minimize;
    // Fading in over the app; solid once it has.
    Future.delayed(Motion.base, () => mounted && !_mini ? widget.onSolid(true) : null);
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
      _next = _prev = null;
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
      // The episodes either side of this one, in the series' order.
      _jf.get('/Shows/${full['SeriesId']}/Episodes', {'userId': _jf.userId, 'adjacentTo': id}).then((r) {
        final eps = ((r as Map)['Items'] as List).cast<Item>();
        final at = eps.indexWhere((e) => e['Id'] == id);
        if (!mounted || at < 0) return;
        setState(() {
          _prev = at > 0 ? eps[at - 1] : null;
          _next = at + 1 < eps.length ? eps[at + 1] : null;
        });
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
      _closeAll();
    }
  }

  void _playNext() {
    final n = _next;
    if (n == null) return;
    _report('stop');
    _start(n);
  }

  /// Back: shrink to the corner window and hand the app its focus back.
  Future<void> _minimize() async {
    if (_mini) return;
    if (_full) await _toggleFull();
    if (!mounted) return;
    widget.onSolid(false);
    setState(() {
      _mini = true;
      _miniHover = false;
    });
    videoFull.value = false;
    _focus.unfocus();
    _giveFocusBack();
  }

  void _giveFocusBack() {
    final b = _before;
    if (b != null && (b.context?.mounted ?? false)) b.requestFocus();
  }

  /// From the corner window back to filling the window.
  void _expand() {
    setState(() => _mini = false);
    videoFull.value = true;
    _focus.requestFocus();
    _wake();
    Future.delayed(_resize, () => mounted && !_mini ? widget.onSolid(true) : null);
  }

  /// Stop and take it off the screen.
  Future<void> _closeAll() async {
    if (_full) await _toggleFull();
    widget.onClose();
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
    // Only while still the current video: a new one may have opened already.
    if (_shrink == _minimize) {
      _shrink = null;
      if (!_mini) {
        videoFull.value = false;
        _giveFocusBack();
      }
    }
    _focus.dispose();
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
    const CharacterActivator('>'): () => _stepRate(1),
    const CharacterActivator('<'): () => _stepRate(-1),
    const SingleActivator(LogicalKeyboardKey.keyF): _toggleFull,
    const SingleActivator(LogicalKeyboardKey.keyC): _toggleSubs,
    const SingleActivator(LogicalKeyboardKey.keyS): () => _segment == null ? null : _skip(_segment!),
    const SingleActivator(LogicalKeyboardKey.home): () => _p.seek(Duration.zero),
    const SingleActivator(LogicalKeyboardKey.escape): _minimize,
    const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): () => _chapter(-1),
    const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): () => _chapter(1),
    for (var n = 0; n <= 9; n++)
      SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + n)): () => _p.seek(Duration(milliseconds: (_len * n / 10 * 1000).round())),
  };

  void _stepRate(int dir) {
    final i = _rates.indexWhere((r) => r >= _rate - 0.01);
    _p.setRate(_rates[((i < 0 ? 2 : i) + dir).clamp(0, _rates.length - 1)]);
  }

  /// The chapter playing at [sec], if the file has chapters.
  _Chapter? _chapterAt(double sec) => _chapters.where((c) => c.sec <= sec + 0.5).lastOrNull;

  void _playPrev() {
    final p = _prev;
    if (p == null) return;
    _report('stop');
    _start(p);
  }

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
    final body = CallbackShortcuts(
      bindings: _keys,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            cursor: _mini || _controls ? MouseCursor.defer : SystemMouseCursors.none,
            onHover: (_) => _mini ? null : _wake(),
            onEnter: (_) => _mini ? setState(() => _miniHover = true) : null,
            onExit: (_) => _mini ? setState(() => _miniHover = false) : null,
            child: GestureDetector(
              // In the corner a tap shows its buttons (a touch has no hover).
              onTap: () => _mini
                  ? setState(() => _miniHover = !_miniHover)
                  : _controls
                  ? _p.playOrPause()
                  : _wake(),
              onDoubleTap: _mini ? _expand : _toggleFull,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(
                    controller: _vc,
                    controls: NoVideoControls,
                    // Subtitles move up out of the way while the controls show.
                    subtitleViewConfiguration: SubtitleViewConfiguration(visible: !_mini, padding: EdgeInsets.fromLTRB(24, 0, 24, _controls ? 110 : 36)),
                  ),
                  if (_mini)
                    _miniChrome()
                  else ...[
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // Filling the window, or a 16:9 window in the bottom right corner above
    // the player bar (the phone's mini player and tabs), sliding between.
    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth * 0.28).clamp(220.0, 400.0), h = w * 9 / 16;
        final rect = _mini ? Rect.fromLTWH(c.maxWidth - 16 - w, c.maxHeight - (narrow(context) ? 150 : 96) - h, w, h) : Offset.zero & c.biggest;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Motion.base,
          builder: (_, fade, child) => Opacity(opacity: fade, child: child),
          child: Stack(
            children: [
              AnimatedPositioned.fromRect(
                rect: rect,
                duration: _resize,
                curve: const Cubic(.4, 0, .2, 1),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_mini ? 12 : 0),
                    boxShadow: _mini ? const [BoxShadow(color: Color(0x99000000), blurRadius: 24, offset: Offset(0, 8))] : null,
                  ),
                  child: ClipRRect(borderRadius: BorderRadius.circular(_mini ? 12 : 0), child: body),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The corner window's buttons, shown while the pointer is over it: play
  /// or pause, back to filling the window, stop; and how far along it is.
  Widget _miniChrome() => Stack(
    children: [
      AnimatedOpacity(
        opacity: _miniHover ? 1 : 0,
        duration: Motion.fast,
        child: IgnorePointer(
          ignoring: !_miniHover,
          child: ColoredBox(
            color: const Color(0x73000000),
            child: Stack(
              children: [
                Center(
                  child: IconBtn(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    _playing ? 'Pause' : 'Play',
                    _p.playOrPause,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconBtn(Icons.open_in_full_rounded, 'Back to the full player', _expand, color: Colors.white, size: 18),
                      IconBtn(Icons.close_rounded, 'Stop and close', _closeAll, color: Colors.white, size: 18),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: LinearProgressIndicator(value: _len > 0 ? (_pos / _len).clamp(0.0, 1.0) : 0, minHeight: 2, color: K.accent, backgroundColor: Colors.white24),
      ),
    ],
  );

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
                IconBtn(Icons.arrow_back_rounded, 'Back (keeps playing in a small window)', _minimize, color: Colors.white, size: 22),
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
                clipBehavior: Clip.none,
                children: [
                  MouseRegion(
                    onHover: (e) => setState(() => _hoverAt = ((e.localPosition.dx - 6) / (c.maxWidth - 12)).clamp(0.0, 1.0)),
                    onExit: (_) => setState(() => _hoverAt = null),
                    child: ThinBar(
                      value: _len > 0 ? _pos / _len : 0,
                      onChanged: _len > 0 ? (v) => _p.seek(Duration(milliseconds: (v * _len * 1000).round())) : null,
                    ),
                  ),
                  // The time (and chapter) under the pointer, above the bar.
                  if (_hoverAt != null && _len > 0)
                    Positioned(
                      left: (6 + (c.maxWidth - 12) * _hoverAt! - 60).clamp(0.0, c.maxWidth - 120),
                      bottom: 22,
                      width: 120,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: const Color(0xE6000000), borderRadius: BorderRadius.circular(6)),
                            child: Text(
                              [_chapterAt(_hoverAt! * _len)?.name, fmt(_hoverAt! * _len)].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts(12, c: Colors.white, tab: true),
                            ),
                          ),
                        ),
                      ),
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
            LayoutBuilder(
              builder: (context, box) {
                // Narrow windows keep the essentials; the rest stay on the
                // keyboard (J and L, Ctrl+arrows for chapters, < and > speed).
                final roomy = box.maxWidth >= 720, compact = box.maxWidth < 600;
                return Row(
                  children: [
                    IconBtn(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      _playing ? 'Pause' : 'Play',
                      _p.playOrPause,
                      color: Colors.white,
                      size: 30,
                    ),
                    if (!compact) ...[
                      IconBtn(Icons.replay_10_rounded, 'Back 10 seconds', () => _seekBy(-10), color: Colors.white, size: 22),
                      IconBtn(Icons.forward_10_rounded, 'Forward 10 seconds', () => _seekBy(10), color: Colors.white, size: 22),
                    ],
                    const SizedBox(width: 4),
                    IconBtn(
                      _volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                      _volume == 0 ? 'Unmute' : 'Mute',
                      () => _p.setVolume(_volume > 0 ? 0 : 100),
                      color: Colors.white,
                      size: 22,
                    ),
                    if (roomy) ...[
                      SizedBox(
                        width: 90,
                        child: ThinBar(value: _volume / 100, onChanged: (v) => _p.setVolume(v * 100), color: Colors.white70, label: volumeLabel),
                      ),
                    ],
                    const SizedBox(width: 8),
                    // Click to switch between time gone and time left.
                    Hover(
                      onTap: () => setState(() => _remaining = !_remaining),
                      label: _remaining ? 'Show time played' : 'Show time left',
                      builder: (_, on) => Text(
                        _remaining ? '-${fmt(max(0, _len - _pos))} / ${fmt(_len)}' : '${fmt(_pos)} / ${fmt(_len)}',
                        style: ts(12, c: on ? Colors.white : Colors.white70, tab: true),
                      ),
                    ),
                    const Spacer(),
                    if (_prev != null && !compact) IconBtn(Icons.skip_previous_rounded, 'Previous episode', _playPrev, color: Colors.white, size: 22),
                    if (_next != null) IconBtn(Icons.skip_next_rounded, 'Next episode', _playNext, color: Colors.white, size: 22),
                    if (_chapters.length > 1 && !compact)
                      _trackMenu<_Chapter>(
                        Icons.list_rounded,
                        'Chapters',
                        _chapters,
                        _chapterAt(_pos) ?? _chapters.first,
                        (c) => '${c.name.isEmpty ? 'Chapter' : c.name} · ${fmt(c.sec)}',
                        (c) => _p.seek(Duration(milliseconds: (c.sec * 1000).round())),
                      ),
                    if (!compact)
                      _trackMenu<double>(
                        Icons.speed_rounded,
                        'Speed (< and >)',
                        _rates,
                        _rates.where((r) => (r - _rate).abs() < 0.01).firstOrNull ?? 1.0,
                        (r) => r == 1 ? 'Normal' : '${r}x',
                        _p.setRate,
                      ),
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
                );
              },
            ),
          ],
        ),
      ),
    ),
  );

  Widget _trackMenu<T>(IconData icon, String tip, List<T> tracks, T current, String Function(T) label, Future<void> Function(T) pick) => tracks.isEmpty
      ? const SizedBox.shrink()
      : PopupMenuButton<T>(
          popUpAnimationStyle: Motion.menu,
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
