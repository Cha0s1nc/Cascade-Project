// Being controlled: the server's command socket (/socket), so the Jellyfin
// dashboard, the Swift apps or another Cascade can play here, pause, skip,
// seek, change the volume and show a message. The rules are
// core/remote_control.dart (the desktop's remote-control.ts); this is the
// socket, the keep-alive, the reconnect and the mapping onto the player.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/core/remote_control.dart';
import 'package:cascade/core/server_messages.dart';
import 'package:cascade/engine/player.dart';

class RemoteSocket {
  RemoteSocket(this.jf, this.player, {this.onMessage});
  final Jellyfin jf;
  final Player player;
  final void Function(ServerMessage message)? onMessage;

  WebSocket? _ws;
  Timer? _keepAlive, _reconnect;
  bool _closed = false;
  double _volumeBeforeMute = 0.7;

  late final _dispatch = RemoteDispatcher(
    RemoteHandlers(
      play: _play,
      playPause: player.toggle,
      pause: () => player.setPlaying(false),
      unpause: () => player.setPlaying(true),
      stop: player.stop,
      nextTrack: player.next,
      previousTrack: player.prev,
      seek: (ticks) => player.seek(ticks / 1e7),
      setVolume: (pct) => player.setVolume(pct / 100),
      volumeUp: () => player.setVolume((player.volume + 0.05).clamp(0, 1)),
      volumeDown: () => player.setVolume((player.volume - 0.05).clamp(0, 1)),
      toggleMute: () => _mute(player.volume > 0),
      setMute: _mute,
      showMessage: onMessage,
    ),
  );

  void _mute(bool on) {
    if (on) {
      if (player.volume > 0) _volumeBeforeMute = player.volume;
      player.setVolume(0);
    } else {
      player.setVolume(player.volume > 0 ? player.volume : _volumeBeforeMute);
    }
  }

  /// PlayNow replaces the queue; PlayNext and PlayLast add to it.
  Future<void> _play(List<String> ids, int start, String command) async {
    if (ids.isEmpty) return;
    final res = await jf.get('/Items', {'userId': jf.userId, 'Ids': ids.join(','), 'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData'});
    final byId = {for (final i in ((res as Map)['Items'] as List).cast<Item>()) i['Id']: jf.song(i)};
    final songs = [for (final id in ids) ?byId[id]];
    if (songs.isEmpty) return;
    switch (command) {
      case 'PlayNext':
        await player.playNext(songs);
      case 'PlayLast':
        await player.addToQueue(songs);
      default:
        await player.play(songs[start.clamp(0, songs.length - 1)], songs, 'Another device');
    }
  }

  Future<void> start() async {
    _closed = false;
    final token = jf.token;
    if (token == null) return;
    try {
      final ws = _ws = await WebSocket.connect(remoteSocketUrl(jf.server, token, jf.deviceId));
      log('remote: socket open');
      jf.post('/Sessions/Capabilities/Full', remoteCapabilitiesBody()).catchError((Object e) => log('remote: capabilities refused: $e'));
      ws.listen(
        (raw) {
          try {
            final msg = jsonDecode(raw as String) as Map<String, dynamic>;
            if (msg['MessageType'] == 'ForceKeepAlive') {
              _keepAlive?.cancel();
              _keepAlive = Timer.periodic(
                Duration(milliseconds: forceKeepAliveIntervalMs(msg['Data'])),
                (_) => _ws?.add(jsonEncode({'MessageType': 'KeepAlive'})),
              );
              return;
            }
            _dispatch.handleMessage(msg);
          } catch (e) {
            log('remote: bad message: $e');
          }
        },
        onDone: _again,
        onError: (_) => _again(),
      );
    } catch (e) {
      log('remote: could not connect: $e');
      _again();
    }
  }

  void _again() {
    _keepAlive?.cancel();
    _ws = null;
    if (_closed) return;
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(milliseconds: reconnectMs), start);
  }

  void close() {
    _closed = true;
    _keepAlive?.cancel();
    _reconnect?.cancel();
    _ws?.close();
    _ws = null;
  }
}
