// Discord Rich Presence over Discord's local IPC (what the desktop's
// discord-rpc package does): a named pipe on Windows, a Unix socket on Linux
// (the plain, Flatpak and Snap places). Frames are an op and a length, both
// little-endian 32-bit, then JSON. "Listening to Cascade" with the song,
// artist and album and Discord's own progress bar; pausing clears it.
// ponytail: no cover art (the desktop looks it up on iTunes) and no reading
// of Discord's replies; reconnecting is trying again on the next update.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/engine/player.dart';

const discordClientId = '1512373702522835004'; // the desktop's DEFAULT_DISCORD_CLIENT_ID

/// One Discord frame.
Uint8List discordFrame(int op, Map<String, Object?> body) {
  final json = utf8.encode(jsonEncode(body));
  final b = BytesBuilder()
    ..add(
      (ByteData(8)
            ..setInt32(0, op, Endian.little)
            ..setInt32(4, json.length, Endian.little))
          .buffer
          .asUint8List(),
    )
    ..add(json);
  return b.toBytes();
}

/// The SET_ACTIVITY arguments for [s], started at [startMs].
Map<String, Object?> presenceActivity(Song s, int startMs) => {
  'type': 2, // Listening
  'status_display_type': 1,
  'details': (s.title.isEmpty ? 'Unknown Track' : s.title).substring(0, s.title.length.clamp(0, 128)),
  'state': (s.artist.isEmpty ? 'Unknown Artist' : s.artist).substring(0, s.artist.length.clamp(0, 128)),
  'timestamps': {'start': startMs, if (s.seconds > 0) 'end': startMs + s.seconds * 1000},
  if (s.album.isNotEmpty) 'assets': {'large_text': s.album.substring(0, s.album.length.clamp(0, 128))},
};

class DiscordPresence {
  DiscordPresence(this.player, this.settings) {
    player.addListener(_changed);
    settings.addListener(_changed);
  }
  final Player player;
  final Settings settings;
  void Function(Uint8List)? _write;
  void Function()? _close;
  String? _shown;
  Timer? _wait;
  int _nonce = 0;

  Future<bool> _connect() async {
    if (_write != null) return true;
    for (var i = 0; i < 10; i++) {
      try {
        if (Platform.isWindows) {
          final f = await File('\\\\?\\pipe\\discord-ipc-$i').open(mode: FileMode.append);
          _write = (b) => f.writeFromSync(b);
          _close = f.closeSync;
        } else {
          final base = Platform.environment['XDG_RUNTIME_DIR'] ?? Platform.environment['TMPDIR'] ?? '/tmp';
          Socket? sock;
          for (final dir in [base, '$base/app/com.discordapp.Discord', '$base/snap.discord']) {
            try {
              sock = await Socket.connect(InternetAddress('$dir/discord-ipc-$i', type: InternetAddressType.unix), 0);
              break;
            } catch (_) {}
          }
          if (sock == null) continue;
          sock.listen((_) {}, onError: (_) => _drop(), onDone: _drop);
          _write = sock.add;
          _close = sock.destroy;
        }
        _write!(discordFrame(0, {'v': 1, 'client_id': discordClientId}));
        log('discord: connected on ipc $i');
        return true;
      } catch (_) {}
    }
    return false;
  }

  void _drop() {
    _write = null;
    _close = null;
    _shown = null;
  }

  // Discord rate-limits presence updates, so changes settle for a moment.
  void _changed() {
    _wait?.cancel();
    _wait = Timer(const Duration(seconds: 2), _send);
  }

  Future<void> _send() async {
    final s = player.song;
    final on = settings.discordRpc && s != null && player.playing;
    final key = on ? '${s.id}|${s.title}|${(player.position / 30).floor()}' : null;
    if (key == _shown) return;
    if (!on && _write == null) return;
    if (!await _connect()) return;
    final start = DateTime.now().millisecondsSinceEpoch - (player.position * 1000).round();
    try {
      _write!(
        discordFrame(1, {
          'cmd': 'SET_ACTIVITY',
          'args': {'pid': pid, if (on) 'activity': presenceActivity(s, start)},
          'nonce': '${++_nonce}',
        }),
      );
      _shown = key;
    } catch (e) {
      log('discord: write failed: $e');
      _close?.call();
      _drop();
    }
  }

  void dispose() {
    player.removeListener(_changed);
    settings.removeListener(_changed);
    _wait?.cancel();
    _close?.call();
  }
}
