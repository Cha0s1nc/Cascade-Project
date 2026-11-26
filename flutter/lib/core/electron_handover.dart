// The new app's half of Electron's "Try the new Cascade" (desktop/main.js
// 'try-flutter'). Electron wrote flutter-handover.json beside its config.json,
// installed this app and quit. At launch, before the saved sign-in is
// restored: bring every setting and the sign-in over (the token with the
// device id it belongs to), check the sign-in against the server, and only
// then remove the Electron app. A failure anywhere leaves the Electron app
// installed and working, and every step is safe to run again: the marker is
// only deleted once there is nothing left to do.
//
// Only the marker starts this. A config.json on its own is someone running
// both apps side by side, which is allowed.
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/electron_import.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/log.dart';

/// What the handover did, for a toast once the app is up; null when there was none.
String? handoverResult;

Future<void> runElectronHandover() async {
  final config = electronConfigFile();
  if (config == null) return;
  final markerFile = File('${config.parent.path}${Platform.pathSeparator}flutter-handover.json');
  if (!markerFile.existsSync()) return;
  try {
    final marker = jsonDecode(await markerFile.readAsString()) as Map;
    final c = jsonDecode(await config.readAsString()) as Map;
    final p = await SharedPreferences.getInstance();
    final hadSignIn = p.getString('token') != null;
    if (!hadSignIn) {
      await importElectronSettings(config);
      final server = c['serverUrl'], token = c['token'], userId = c['userId'], user = c['username'], device = c['deviceId'];
      if ([server, token, userId, device].every((v) => v is String && v.isNotEmpty)) {
        await p.setString('server', Jellyfin.normalize(server as String));
        await p.setString('token', token as String);
        await p.setString('userId', userId as String);
        await p.setString('userName', user is String ? user : '');
        await p.setString('deviceId', device as String);
      }
    }
    // The sign-in must work before the old app goes.
    final server = p.getString('server'), token = p.getString('token');
    if (server == null || token == null) {
      await markerFile.delete();
      handoverResult = 'Brought over your settings. Sign in to finish; the classic app is still installed.';
      return;
    }
    try {
      await Jellyfin(server, p.getString('deviceId') ?? '', token: token, userId: p.getString('userId')).get('/Users/Me');
    } catch (e) {
      log('handover: the sign-in did not work: $e');
      if (!hadSignIn) await p.remove('token');
      await markerFile.delete();
      handoverResult = 'Brought over your settings, but the sign-in did not work here: sign in again. The classic app is still installed.';
      return;
    }
    final removed = marker['packaged'] == false ? 'left alone (a development run)' : await _removeElectron(marker);
    await markerFile.delete();
    handoverResult = 'Welcome to the new Cascade: your settings and sign-in came with you. The classic app was $removed.';
    log('handover: done, classic app $removed');
  } catch (e) {
    log('handover failed: $e');
    handoverResult = 'Could not finish moving over from the classic app: $e';
  }
}

/// Removes the Electron app as the marker says it is installed; says how it went.
Future<String> _removeElectron(Map marker) async {
  switch (marker['kind']) {
    case 'nsis':
      final u = marker['uninstaller'];
      if (u is! String || !File(u).existsSync()) return 'already gone';
      final r = await Process.run(u, ['/S', '/currentuser']);
      return r.exitCode == 0 ? 'removed' : 'not removed (its uninstaller said ${r.exitCode}); remove it in Settings, Apps';
    case 'AppImage':
      final f = marker['appImage'];
      if (f is! String || !File(f).existsSync()) return 'already gone';
      await File(f).delete();
      return 'removed';
    case 'deb' || 'rpm':
      // Needs root: the desktop's own password prompt. Declined or missing, it stays.
      final args = marker['kind'] == 'deb' ? ['apt-get', 'remove', '-y', 'cascade'] : ['dnf', 'remove', '-y', 'cascade'];
      try {
        final r = await Process.run('pkexec', args);
        return r.exitCode == 0 ? 'removed' : 'not removed; remove the cascade package yourself';
      } catch (_) {
        return 'not removed; remove the cascade package yourself';
      }
  }
  return 'left alone (it was installed in a way this app does not know)';
}
