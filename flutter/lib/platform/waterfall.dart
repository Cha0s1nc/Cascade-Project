// Waterfall, listening together on one Jellyfin server (desktop/waterfall.js).
// No audio crosses the wire: everyone streams the same track from the same
// server, and the room carries only "track X, position Y, playing or
// paused" through the relay (signaling/). The host owns playback and the
// queue; guests follow, may add songs, and may drive the transport when the
// host allows it. The wire format and the sync maths are
// core/waterfall_protocol.dart, shared with the desktop and the TV app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/core/waterfall_protocol.dart';
import 'package:cascade/engine/player.dart';

const waterfallDefaultRelay = 'https://cascade-waterfall-signaling.cha0s-netw0rks.workers.dev';

class Waterfall extends ChangeNotifier {
  Waterfall(this.player);
  final Player player;

  Jellyfin? jf;
  WebSocket? _ws;
  bool isHost = false;
  String? code, error, serverId;
  List<Map> roster = const [];

  /// The host's choices, which guests mirror from its queue messages.
  bool guestAddsAllowed = true, guestControlAllowed = false;

  /// A notice for the person (refused additions, missing access).
  void Function(String text)? onNotice;

  Timer? _heartbeat;
  int _rev = 0, _lastRev = -1;
  String _sig = '';
  String? _loadedTrack;
  Map<String, Object?>? _pending;
  final _skew = <num>[];
  bool _applying = false;
  Future<void> _chain = Future.value();

  bool get active => _ws != null;

  Future<String> _relay() async =>
      ((await SharedPreferences.getInstance()).getString('waterfallRelay') ?? '').trim().replaceFirst(RegExp(r'/+$'), '').ifEmpty(waterfallDefaultRelay);

  Future<void> _open(String roomCode, bool host) async {
    final j = jf;
    if (j == null) throw StateError('Sign in first.');
    serverId ??= ((await j.get('/System/Info/Public')) as Map)['Id'] as String?;
    final ws = await WebSocket.connect(roomSocketUrl(await _relay(), roomCode, j.userName ?? 'Listener'));
    final joined = Completer<void>();
    ws.listen(
      (raw) {
        Map msg;
        try {
          msg = jsonDecode(raw as String) as Map;
        } catch (_) {
          return;
        }
        switch (msg['type']) {
          case 'join-denied':
            if (!joined.isCompleted) joined.completeError(msg['reason'] == 'room-full' ? 'That room is full.' : 'No room with that code.');
            ws.close();
          case 'joined':
            _ws = ws;
            isHost = host;
            code = roomCode;
            roster = ((msg['roster'] as List?) ?? const []).cast<Map>();
            if (!joined.isCompleted) joined.complete();
            if (!host) _send({'k': 'hello', 'serverId': serverId});
            notifyListeners();
          case 'roster':
            roster = ((msg['members'] as List?) ?? const []).cast<Map>();
            notifyListeners();
          case 'relay':
            _onRelay(msg['from'] as String?, (msg['payload'] as Map?)?.cast<String, Object?>());
        }
      },
      onDone: () {
        if (!joined.isCompleted) joined.completeError('Could not reach the room server.');
        if (_ws == ws) leave('The room closed.');
      },
      onError: (_) {},
    );
    await joined.future;
  }

  void _send(Map<String, Object?> payload, [String? to]) => _ws?.add(jsonEncode({'type': 'relay', 'to': to, 'payload': payload}));

  /// Start a room and host it; its code.
  Future<String> create() async {
    final res = await http.post(Uri.parse('${await _relay()}/create'));
    if (res.statusCode >= 300) throw StateError('Could not create a room.');
    final c = (jsonDecode(res.body) as Map)['code'] as String;
    await _open(c, true);
    _heartbeat = Timer.periodic(const Duration(milliseconds: wfHeartbeatMs), (_) {
      if (_signature() != _sig) _queueChanged();
      _sendState();
    });
    _queueChanged();
    _sendState();
    return c;
  }

  Future<void> join(String roomCode) async {
    await _open(roomCode.trim().toUpperCase(), false);
    // A guest's transport goes to the host.
    player.remoteDriver = (action, [ms]) {
      if (_applying || !active || isHost) return false;
      if (!guestControlAllowed) {
        onNotice?.call('The host controls playback in this room.');
        return true;
      }
      _send(buildControlMessage(action, ms));
      return true;
    };
  }

  void leave([String? reason]) {
    _heartbeat?.cancel();
    final ws = _ws;
    _ws = null;
    ws?.close();
    if (player.remoteDriver != null) player.remoteDriver = null;
    isHost = false;
    code = null;
    roster = const [];
    _rev = 0;
    _lastRev = -1;
    _sig = '';
    _loadedTrack = null;
    _pending = null;
    _skew.clear();
    guestAddsAllowed = true;
    guestControlAllowed = false;
    if (reason != null) onNotice?.call(reason);
    notifyListeners();
  }

  void setGuestPermissions({bool? adds, bool? control}) {
    guestAddsAllowed = adds ?? guestAddsAllowed;
    guestControlAllowed = control ?? guestControlAllowed;
    if (isHost) _queueChanged();
    notifyListeners();
  }

  /// A guest asks the host to add songs; the host is the authority.
  void requestAdd(List<Song> songs) => _send(buildEnqueueMessage(serverId: serverId, trackIds: [for (final s in songs) s.id]));

  // Host ------------------------------------------------------------------

  String _signature() => player.ordered.map((s) => s.id).join(',');

  void _queueChanged() {
    if (!isHost) return;
    _rev++;
    _sig = _signature();
    _sendQueue();
  }

  void _sendQueue([String? to]) => _send(
    buildQueueMessage(
      serverId: serverId,
      rev: _rev,
      trackIds: [for (final s in player.ordered) s.id],
      index: player.orderIndex,
      guestAddsAllowed: guestAddsAllowed,
      guestControlAllowed: guestControlAllowed,
    ),
    to,
  );

  void _sendState([String? to]) {
    final s = player.song;
    if (!isHost || s == null) return;
    _send(
      buildStateMessage(serverId: serverId, trackId: s.id, positionMs: (player.position * 1000).round(), paused: !player.playing, index: player.orderIndex),
      to,
    );
  }

  Future<void> _hostEnqueue(String? from, Map<String, Object?> p) async {
    if (!guestAddsAllowed) return _send(buildEnqueueRejected('The host is not taking additions right now.'), from);
    final ids = ((p['trackIds'] as List?) ?? const []).whereType<String>().take(50).toList();
    final j = jf;
    if (ids.isEmpty || j == null) return;
    final res = await j.get('/Items', {'userId': j.userId, 'Ids': ids.join(','), 'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData'});
    final songs = [for (final i in ((res as Map)['Items'] as List).cast<Item>()) j.song(i)];
    await player.addToQueue(songs);
    _queueChanged();
  }

  void _hostControl(Map<String, Object?> p) {
    if (!guestControlAllowed || !isControlAction(p['action'])) return;
    switch (p['action']) {
      case 'playpause':
        player.setPlaying(!player.playing);
      case 'next':
        player.next();
      case 'prev':
        player.prev();
      case 'seek':
        final ms = p['positionMs'];
        if (ms is num) player.seekTo(ms / 1000);
    }
  }

  // Everyone ------------------------------------------------------------------

  void _onRelay(String? from, Map<String, Object?>? p) {
    if (p == null) return;
    if (isForeignServer(p['serverId'] as String?, serverId)) {
      if (isHost) {
        _send({'k': 'wrong-server'}, from);
      } else {
        leave('That room is hosted on a different Jellyfin server.');
      }
      return;
    }
    switch (p['k']) {
      case 'hello' when isHost:
        _sendQueue(from);
        _sendState(from);
      case 'wrong-server':
        leave('That room is hosted on a different Jellyfin server.');
      case 'enqueue' when isHost:
        _hostEnqueue(from, p);
      case 'control' when isHost:
        _hostControl(p);
      case 'enqueue-rejected' when !isHost:
        onNotice?.call('${p['reason'] ?? 'The host refused that addition.'}');
      case 'queue' when !isHost:
        _serial(() => _applyQueue(p));
      case 'state' when !isHost:
        final sent = p['sentAt'];
        if (sent is num) {
          _skew.add(DateTime.now().millisecondsSinceEpoch - sent);
          if (_skew.length > wfSkewWindow) _skew.removeAt(0);
        }
        _serial(() => _applyState(p));
    }
  }

  void _serial(Future<void> Function() f) => _chain = _chain.then((_) => f()).catchError((Object e) => log('waterfall: $e'));

  Future<void> _applyQueue(Map<String, Object?> m) async {
    final rev = m['rev'] as int? ?? 0;
    if (isStaleQueue(rev, _lastRev)) return;
    _lastRev = rev;
    guestAddsAllowed = m['guestAddsAllowed'] != false;
    guestControlAllowed = m['guestControlAllowed'] == true;
    final ids = ((m['trackIds'] as List?) ?? const []).whereType<String>().toList();
    final known = {for (final s in player.ordered) s.id: s};
    final missing = missingTrackIds(ids, known.keys);
    final j = jf!;
    for (var i = 0; i < missing.length; i += 150) {
      final res = await j.get('/Items', {'userId': j.userId, 'Ids': missing.skip(i).take(150).join(','), 'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData'});
      for (final it in ((res as Map)['Items'] as List).cast<Item>()) {
        known[it['Id'] as String] = j.song(it);
      }
    }
    // Songs this account cannot see stay as placeholders, so the indexes line
    // up with the host's.
    final songs = [for (final id in ids) known[id] ?? Song('Not available to you', '', '', 0, 0, artFor(id), id: id)];
    player.follow(songs, m['index'] as int? ?? 0);
    notifyListeners();
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      await _applyState(pending);
    }
  }

  Future<void> _applyState(Map<String, Object?> s) async {
    final track = s['trackId'] as String?;
    if (track == null) return;
    final order = player.ordered;
    var index = s['index'] is int && (s['index'] as int) < order.length && order[s['index'] as int].id == track
        ? s['index'] as int
        : order.indexWhere((x) => x.id == track);
    if (index < 0) {
      _pending = s;
      _send({'k': 'hello', 'serverId': serverId});
      return;
    }
    final expected = expectedPositionMs(s, offsetMs: clockOffsetMs(_skew).round());
    final paused = s['paused'] == true;
    _applying = true;
    try {
      if (_loadedTrack != track || player.song?.id != track) {
        await player.playIndex(index, startAt: seekTargetMs(expected, 0, paused) / 1000, paused: paused);
        _loadedTrack = track;
        return;
      }
      if (shouldReseek(player.position * 1000, expected)) await player.seekTo(expected / 1000);
      if (paused == player.playing) await player.setPlaying(!paused);
    } finally {
      _applying = false;
    }
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
