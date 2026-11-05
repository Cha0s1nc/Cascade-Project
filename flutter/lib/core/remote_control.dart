// Making this client a Jellyfin remote-control target ("cast to Cascade"): the
// capabilities it declares, the socket URL, and the dispatch of commands that
// arrive on the socket. Only the protocol lives here; the WebSocket, timers and
// reconnects belong to the app. Ported from desktop/src/core/remote-control.ts
// (its RemoteControl class split into these pure pieces plus RemoteDispatcher).
import 'server_messages.dart';

/// What the host platform must do for a remote to be useful.
class RemoteHandlers {
  /// PlayNow / PlayNext / PlayLast with the item ids the controller picked.
  final void Function(List<String> itemIds, int startIndex, String playCommand) play;
  final void Function() playPause, pause, unpause, stop, nextTrack, previousTrack;

  /// Absolute position in ticks (100 ns units).
  final void Function(num positionTicks) seek;

  /// 0-100, Jellyfin's scale.
  final void Function(double percent) setVolume;
  final void Function() volumeUp, volumeDown, toggleMute;
  final void Function(bool muted) setMute;

  /// A message an admin sent from the dashboard (DisplayMessage). Optional.
  final void Function(ServerMessage message)? showMessage;

  const RemoteHandlers({
    required this.play,
    required this.playPause,
    required this.pause,
    required this.unpause,
    required this.stop,
    required this.nextTrack,
    required this.previousTrack,
    required this.seek,
    required this.setVolume,
    required this.volumeUp,
    required this.volumeDown,
    required this.toggleMute,
    required this.setMute,
    this.showMessage,
  });
}

/// Return false to refuse an incoming command (see ownership.dart).
typedef CommandGate = bool Function();

const keepAliveFallbackMs = 30000;
const reconnectMs = 5000;

/// Commands declared to the server. Must be GeneralCommandType values only: Pause, PlayPause, Stop, NextTrack, PreviousTrack and Seek are playstate commands and make Jellyfin reject the whole registration with a 400. List only what [RemoteDispatcher] handles.
const supportedCommands = [
  'SetVolume', 'ToggleMute', 'Mute', 'Unmute', 'VolumeUp', 'VolumeDown', 'Play', 'PlayState',
  // Messages from the dashboard. Not playback, so not gated.
  'DisplayMessage',
];

/// The JSON body for `POST /Sessions/Capabilities/Full`.
Map<String, Object> remoteCapabilitiesBody() => {
  'PlayableMediaTypes': ['Audio', 'Video'],
  'SupportedCommands': [...supportedCommands],
  'SupportsMediaControl': true,
  'SupportsPersistentIdentifier': true,
  'SupportsContentUploading': false,
  'SupportsSync': false,
};

/// The command socket URL for a server.
String remoteSocketUrl(String url, String token, String? deviceId) =>
    '${url.replaceFirst(RegExp(r'^http'), 'ws')}/socket?ApiKey=${Uri.encodeComponent(token)}&deviceId=${Uri.encodeComponent(deviceId ?? '')}';

/// How often to ping after a ForceKeepAlive whose Data is the server's timeout in seconds: half of it, at least 1 s worth.
int forceKeepAliveIntervalMs(Object? data) {
  final n = _number(data);
  final secs = n.isNaN || n == 0 ? 60.0 : (n < 1 ? 1.0 : n);
  return (secs * 500).round();
}

// JS Number(): numbers as they are, numeric strings parsed, anything else NaN.
double _number(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return v.trim().isEmpty ? 0 : (double.tryParse(v.trim()) ?? double.nan);
  return double.nan;
}

double _orZero(double n) => n.isNaN ? 0 : n;

double _clampPercent(double n) => n.isFinite ? n.clamp(0.0, 100.0) : 0;

/// Turns socket messages into handler calls, honoring the gate. Feed it each decoded message.
class RemoteDispatcher {
  final RemoteHandlers handlers;
  final CommandGate gate;

  const RemoteDispatcher(this.handlers, [this.gate = _open]);

  static bool _open() => true;

  /// Handles one decoded socket message (a Map with MessageType and Data). Unknown messages are ignored.
  void handleMessage(Map<String, dynamic> msg) {
    final data = msg['Data'];
    switch (msg['MessageType']) {
      case 'Play':
        if (!gate()) return;
        final d = data is Map ? data : const {};
        final ids = d['ItemIds'] is List ? (d['ItemIds'] as List).whereType<String>().toList() : <String>[];
        final start = _orZero(_number(d['StartIndex'])).toInt();
        final cmd = d['PlayCommand'];
        handlers.play(ids, start, cmd is String && cmd.isNotEmpty ? cmd : 'PlayNow');
      case 'Playstate' || 'PlayState':
        if (!gate()) return;
        _playState(data);
      case 'GeneralCommand':
        // A message is for the person, not the player: it shows in a Waterfall room or under a cast too.
        if (data is Map && data['Name'] == 'DisplayMessage') {
          final message = parseDisplayMessage(data['Arguments']);
          if (message != null) handlers.showMessage?.call(message);
          return;
        }
        if (!gate()) return;
        _generalCommand(data);
    }
  }

  void _playState(Object? data) {
    if (data is! Map) return;
    switch (data['Command']) {
      case 'PlayPause':
        handlers.playPause();
      case 'Pause':
        handlers.pause();
      case 'Unpause':
        handlers.unpause();
      case 'Stop':
        handlers.stop();
      case 'NextTrack':
        handlers.nextTrack();
      case 'PreviousTrack':
        handlers.previousTrack();
      case 'Seek':
        handlers.seek(_orZero(_number(data['SeekPositionTicks'])));
    }
  }

  void _generalCommand(Object? data) {
    if (data is! Map) return;
    // Arguments arrive as strings even for numbers.
    final args = data['Arguments'] is Map ? data['Arguments'] as Map : const {};
    switch (data['Name']) {
      case 'SetVolume':
        handlers.setVolume(_clampPercent(_number(args['Volume'])));
      case 'VolumeUp':
        handlers.volumeUp();
      case 'VolumeDown':
        handlers.volumeDown();
      case 'ToggleMute':
        handlers.toggleMute();
      case 'Mute':
        handlers.setMute(true);
      case 'Unmute':
        handlers.setMute(false);
    }
  }
}
