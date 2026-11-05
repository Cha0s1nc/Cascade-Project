// Bring settings over from the Cascade desktop app's config.json
// (electron-store, in the Electron app's data folder). The Flutter app
// stores them under the same names, so this is mostly a copy; the work is
// the types, since the desktop kept a few switches as the strings 'true' and
// 'false' and some lists and objects as JSON. The sign-in is not copied:
// the server's tokens belong to the desktop's device.
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

const _bools = ['crossfadeEnabled', 'normalizationEnabled', 'eqEnabled', 'shuffle', 'autoMixEnabled', 'radioEnabled', 'discordRpcEnabled', 'autoSkipSegments'];
const _ints = ['crossfadeSeconds', 'maxStreamingBitrate'];
const _doubles = ['volume'];
const _strings = ['normalizationSource', 'outputDeviceId', 'repeatMode', 'browseMode', 'lyricsForcedSource', 'songsSortField', 'songsSortDir'];
const _lists = ['libraryIds', 'movieLibraryIds', 'showLibraryIds', 'announcementsDismissed', 'announcementsSeen'];

/// Kept as JSON text on both sides.
const _json = ['eqMusic', 'eqVideo', 'lastQueue', 'smartPlaylists', 'albumsPrefs', 'artistsPrefs', 'playlistsPrefs'];

/// The settings in [config] as typed values, under their keys.
Map<String, Object> electronSettings(Map config) {
  final out = <String, Object>{};
  bool? asBool(Object? v) => v is bool ? v : (v == 'true' ? true : (v == 'false' ? false : null));
  for (final k in _bools) {
    final b = asBool(config[k]);
    if (b != null) out[k] = b;
  }
  for (final k in _ints) {
    final v = config[k] is String ? num.tryParse(config[k] as String) : config[k];
    if (v is num && v.isFinite) out[k] = v.round();
  }
  for (final k in _doubles) {
    final v = config[k] is String ? num.tryParse(config[k] as String) : config[k];
    if (v is num && v.isFinite) out[k] = v.toDouble();
  }
  for (final k in _strings) {
    if (config[k] is String && (config[k] as String).isNotEmpty) out[k] = config[k] as String;
  }
  for (final k in _lists) {
    var v = config[k];
    if (v is String) {
      try {
        v = jsonDecode(v);
      } catch (_) {}
    }
    if (v is List) out[k] = v.whereType<String>().toList();
  }
  for (final k in _json) {
    final v = config[k];
    if (v is String && v.isNotEmpty) {
      out[k] = v;
    } else if (v is Map || v is List) {
      out[k] = jsonEncode(v);
    }
  }
  return out;
}

/// Where the desktop app keeps config.json, if it is on this computer.
File? electronConfigFile() {
  final env = Platform.environment;
  final bases = Platform.isWindows
      ? [env['APPDATA']]
      : Platform.isLinux
      ? [env['XDG_CONFIG_HOME'] ?? '${env['HOME']}/.config']
      : const <String?>[];
  for (final base in bases.whereType<String>()) {
    for (final name in ['Cascade', 'cascade']) {
      final f = File('$base${Platform.pathSeparator}$name${Platform.pathSeparator}config.json');
      if (f.existsSync()) return f;
    }
  }
  return null;
}

/// Copy the desktop app's settings in; how many came over.
Future<int> importElectronSettings(File f) async {
  final config = jsonDecode(await f.readAsString());
  if (config is! Map) return 0;
  final p = await SharedPreferences.getInstance();
  final s = electronSettings(config);
  for (final MapEntry(:key, :value) in s.entries) {
    switch (value) {
      case bool b:
        await p.setBool(key, b);
      case int i:
        await p.setInt(key, i);
      case double d:
        await p.setDouble(key, d);
      case List<String> l:
        await p.setStringList(key, l);
      case String t:
        await p.setString(key, t);
    }
  }
  return s.length;
}
