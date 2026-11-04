// The OS's own media controls, mirroring the player: Windows' media overlay
// and the keyboard's media keys (SMTC), and Android's notification, lock
// screen and headset buttons (a media session in a foreground service, so
// playback keeps going in the background).
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:smtc_windows/smtc_windows.dart';

import 'log.dart';
import 'player.dart';

Future<void> attachMediaControls(Player p) async {
  try {
    if (Platform.isWindows) await _windows(p);
    if (Platform.isAndroid) {
      await AudioService.init(builder: () => _AndroidHandler(p), config: _androidConfig);
    }
  } catch (e, st) {
    log('media controls unavailable: $e\n$st'); // playback still works without them
  }
}

Future<void> _windows(Player p) async {
  await SMTCWindows.initialize();
  final smtc = SMTCWindows(enabled: false);
  log('SMTC ready');
  // These calls are fire-and-forget; a failure should still show in the log.
  void check(Future<void> call, String what) => call.catchError((Object e) => log('SMTC $what failed: $e'));
  smtc.buttonPressStream.listen((b) {
    log('SMTC button $b');
    switch (b) {
      case PressedButton.play:
        p.setPlaying(true);
      case PressedButton.pause:
        p.setPlaying(false);
      case PressedButton.next:
        p.next();
      case PressedButton.previous:
        p.prev();
      default:
    }
  });
  String? shown;
  bool? wasPlaying;
  var second = -1;
  p.addListener(() {
    final s = p.song;
    if (s == null) {
      if (shown != null) check(smtc.disableSmtc(), 'disable');
      shown = null;
      return;
    }
    if (shown != s.id) {
      if (shown == null) check(smtc.enableSmtc(), 'enable');
      shown = s.id;
      check(smtc.updateMetadata(MusicMetadata(title: s.title, artist: s.artist, album: s.album, albumArtist: s.artist, thumbnail: s.image)), 'metadata');
    }
    if (wasPlaying != p.playing) {
      wasPlaying = p.playing;
      check(smtc.setPlaybackStatus(p.playing ? PlaybackStatus.playing : PlaybackStatus.paused), 'status');
    }
    if (second != p.position.floor()) {
      second = p.position.floor();
      final end = (p.length * 1000).round();
      check(smtc.updateTimeline(PlaybackTimeline(startTimeMs: 0, endTimeMs: end, positionMs: second * 1000, minSeekTimeMs: 0, maxSeekTimeMs: end)), 'timeline');
    }
  });
}

const _androidConfig = AudioServiceConfig(
  androidNotificationChannelId: 'xyz.chaosinc.cascade.playback',
  androidNotificationChannelName: 'Playback',
  androidNotificationOngoing: true,
  androidStopForegroundOnPause: true,
);

class _AndroidHandler extends BaseAudioHandler with SeekHandler {
  _AndroidHandler(this.p) {
    p.addListener(_sync);
  }

  final Player p;
  String? _shown;
  bool? _wasPlaying;
  double _expected = 0;

  @override
  Future<void> play() => p.setPlaying(true);
  @override
  Future<void> pause() => p.setPlaying(false);
  @override
  Future<void> stop() => p.setPlaying(false);
  @override
  Future<void> skipToNext() => p.next();
  @override
  Future<void> skipToPrevious() => p.prev();
  @override
  Future<void> seek(Duration position) => p.seek(position.inMilliseconds / 1000);

  // Android runs the notification's clock itself from the last state, so only
  // send a new state on a change of song, play/pause, or a jump.
  void _sync() {
    final s = p.song;
    if (s == null) return;
    final jumped = (p.position - _expected).abs() > 2;
    _expected = p.position + 1;
    if (_shown != s.id) {
      _shown = s.id;
      mediaItem.add(
        MediaItem(
          id: s.id,
          title: s.title,
          artist: s.artist,
          album: s.album,
          duration: Duration(milliseconds: (p.length * 1000).round()),
          artUri: s.image == null ? null : Uri.parse(s.image!),
          artHeaders: p.jf?.headers,
        ),
      );
    } else if (_wasPlaying == p.playing && !jumped) {
      return;
    }
    _wasPlaying = p.playing;
    playbackState.add(
      PlaybackState(
        controls: [MediaControl.skipToPrevious, p.playing ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: p.playing,
        updatePosition: Duration(milliseconds: (p.position * 1000).round()),
      ),
    );
  }
}
