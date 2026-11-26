// Settings > About > Switch back to the classic app, until 3.0: the reverse of
// Electron's "Try the new Cascade" (core/electron_handover.dart). This app's
// settings and sign-in go back into the desktop app's config.json, the newest
// desktop release for this computer is installed and started, and this app is
// removed once it has quit. Only where this app manages its own install (the
// Windows installer or the Linux tarball, see updater.dart): a Flatpak cannot
// remove itself from inside its sandbox.
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/electron_import.dart';
import 'package:cascade/core/update_release.dart';
import 'package:cascade/core/updater.dart';

/// Whether this copy can switch back.
bool get canSwitchBack => updateKind != null;

/// The desktop app's newest stable release for this computer, as a download.
Future<AppUpdate?> findClassicApp() async {
  for (final r in await fetchReleases(beta: false)) {
    final build = desktopBuildOf(r, await versionsTextOf(r));
    if (build == null) continue;
    // Linux takes the AppImage: it needs no root, unlike a .deb or .rpm.
    final a = pickInstaller(r, build.version, (platform: Platform.isWindows ? 'win32' : 'linux', arch: 'x64', linuxKind: 'AppImage'));
    final url = a?['browser_download_url'];
    if (a == null || url is! String) return null;
    return (
      version: build.version,
      releaseUrl: r['html_url'] is String ? r['html_url'] as String : releasesPage,
      name: a['name'] as String,
      url: url,
      size: a['size'] is int ? a['size'] as int : 0,
      digest: a['digest'] is String ? a['digest'] as String : null,
    );
  }
  return null;
}

/// Writes the settings back, installs [download] (the desktop app), starts it
/// and quits, leaving this app to be removed once it has.
Future<void> switchBack(File download) async {
  // An AppImage needs FUSE 2, which Ubuntu 24.04 and its kind leave out: check
  // before anything changes, or this app would go and the classic one not start.
  if (Platform.isLinux && !await _hasFuse2()) {
    throw StateError('The classic app needs FUSE 2 to run. Install it first (on Debian or Ubuntu: sudo apt install libfuse2t64; on Fedora: sudo dnf install fuse-libs), then try again.');
  }
  final p = await SharedPreferences.getInstance();
  final target = electronConfigTarget();
  final existing = target.existsSync() ? jsonDecode(target.readAsStringSync()) : const {};
  await target.parent.create(recursive: true);
  await target.writeAsString(jsonEncode(electronExport(p, existing is Map ? existing : const {})));

  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME']!;
  if (Platform.isWindows) {
    // The desktop app's installer is per user; /S installs it without a wizard.
    final r = await Process.run(download.path, ['/S', '/currentuser']);
    if (r.exitCode != 0) throw ProcessException(download.path, ['/S', '/currentuser'], 'the installer said ${r.exitCode}', r.exitCode);
    await Process.start('${Platform.environment['LOCALAPPDATA']}\\Programs\\Cascade\\Cascade.exe', const [], mode: ProcessStartMode.detached);
    // This app's uninstaller, once this process is gone.
    final script = File('${Directory.systemTemp.path}\\cascade-remove-new-app.cmd');
    await script.writeAsString('@echo off\r\ntimeout /t 3 /nobreak >nul\r\n"${installDir.path}\\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES\r\n');
    await Process.start('cmd', ['/c', script.path], mode: ProcessStartMode.detached);
    exit(0);
  }
  // Linux: the AppImage into ~/Applications with a menu entry of its own (the
  // desktop app's id is cascade, so it never collides with this one's).
  final apps = Directory('$home/Applications')..createSync(recursive: true);
  final image = '${apps.path}/Cascade.AppImage';
  await download.copy(image);
  await Process.run('chmod', ['755', image]);
  final menu = Directory('$home/.local/share/applications')..createSync(recursive: true);
  await File('${menu.path}/cascade.desktop').writeAsString(
    '[Desktop Entry]\nType=Application\nName=Cascade\nComment=Jellyfin music and video client\nExec="$image" %U\nIcon=xyz.chaosinc.cascade\nTerminal=false\nCategories=AudioVideo;Audio;Player;\nStartupWMClass=Cascade\n',
  );
  // Only a folder that is this app's own bundle is removed, never anything else.
  final ours = File('${installDir.path}/cascade').existsSync() && File('${installDir.path}/lib/libapp.so').existsSync();
  await Process.start(
    '/bin/bash',
    ['-c', 'while kill -0 "\$1" 2>/dev/null; do sleep 0.2; done; [ "\$5" = yes ] && rm -rf "\$2" "\$3"; exec "\$4"', 'switch', '$pid', installDir.path, '${menu.path}/xyz.chaosinc.cascade.desktop', image, ours ? 'yes' : 'no'],
    mode: ProcessStartMode.detached,
  );
  exit(0);
}

Future<bool> _hasFuse2() async {
  for (final ldconfig in ['ldconfig', '/sbin/ldconfig', '/usr/sbin/ldconfig']) {
    try {
      final r = await Process.run(ldconfig, ['-p']);
      if (r.exitCode == 0) return '${r.stdout}'.contains('libfuse.so.2');
    } catch (_) {}
  }
  return false;
}
