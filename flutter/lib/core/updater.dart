// The Flutter app's own updater, for the Windows installer and the Linux
// tarball. It reads releases the way the desktop app's updater does
// (update_release.dart): versions.json's `flutter` entry plus this computer's
// file in the same release. Off where something else updates the app or
// nothing could be installed: the Flatpak (Flathub's job), Android and macOS,
// a version that is not a release's (a development build), and a Linux folder
// this user cannot replace.
//
// CASCADE_RELEASES_URL, when set, is read instead of GitHub's release list
// (same JSON shape; its files may be on any http server), so the whole path
// can be tried before a release has a Flutter build in it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:cascade/core/jellyfin.dart' show appVersion;
import 'package:cascade/core/log.dart';
import 'package:cascade/core/update_release.dart';

const _repo = 'Cha0s1nc/Cascade-Project';
const _ua = {'User-Agent': 'cascade-updater'};

/// A newer release with this computer's file.
typedef AppUpdate = ({String version, String releaseUrl, String name, String url, int size, String? digest});

enum UpdateKind { installer, tarball }

/// How this copy updates itself, or null when it does not.
UpdateKind? get updateKind {
  if (!isReleaseVersion(appVersion)) return null;
  if (Platform.isWindows) return UpdateKind.installer;
  if (!Platform.isLinux) return null;
  if (Platform.environment['FLATPAK_ID'] != null || File('/.flatpak-info').existsSync()) return null;
  return _canReplace(_installDir) ? UpdateKind.tarball : null;
}

/// The release page to send someone to when this copy cannot update itself.
String get releasesPage => 'https://github.com/$_repo/releases';

/// The newest release newer than this copy, or null. Betas only with [beta].
Future<AppUpdate?> checkForUpdate({required bool beta}) async {
  final kind = updateKind, name = flutterAssetName(Platform.operatingSystem, _arch);
  if (kind == null || name == null) return null;
  // The newest release with a Flutter build, walking past ones made for other platforms.
  for (final r in await fetchReleases(beta: beta)) {
    final build = flutterBuildOf(r, await versionsTextOf(r), Platform.operatingSystem, _arch);
    if (build == null) continue;
    if (!isNewerVersion(build.version, appVersion)) return null;
    final a = build.asset;
    final dl = a['browser_download_url'];
    if (dl is! String) return null;
    return (
      version: build.version,
      releaseUrl: r['html_url'] is String ? r['html_url'] as String : releasesPage,
      name: a['name'] as String,
      url: dl,
      size: a['size'] is int ? a['size'] as int : 0,
      digest: a['digest'] is String ? a['digest'] as String : null,
    );
  }
  return null;
}

/// Recent releases, newest first: stable ones only unless [beta]. Read from
/// CASCADE_RELEASES_URL instead of GitHub when it is set.
Future<List<ReleaseLike>> fetchReleases({required bool beta}) async {
  final override = Platform.environment['CASCADE_RELEASES_URL'];
  final listed = override != null || beta;
  final url = override ?? (beta ? 'https://api.github.com/repos/$_repo/releases?per_page=10' : 'https://api.github.com/repos/$_repo/releases/latest');
  final res = await http.get(Uri.parse(url), headers: _ua).timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) throw HttpException('release list: HTTP ${res.statusCode}');
  final body = jsonDecode(res.body);
  return [
    for (final r in (listed ? (body is List ? body : const []) : [body]))
      if (r is Map<String, dynamic> && r['draft'] != true && (beta || r['prerelease'] != true)) r,
  ];
}

/// A release's versions.json, as text, or null.
Future<String?> versionsTextOf(ReleaseLike r) async {
  final a = findVersionsAsset(r);
  final url = a?['browser_download_url'];
  if (url is! String || (a?['size'] is int && (a!['size'] as int) > versionsMaxBytes)) return null;
  try {
    final res = await http.get(Uri.parse(url), headers: _ua).timeout(const Duration(seconds: 15));
    return res.statusCode == 200 && res.body.length <= versionsMaxBytes ? res.body : null;
  } catch (e) {
    log('updater: versions.json: $e');
    return null;
  }
}

/// Downloads [u] into a temporary folder, checking its sha256 when the
/// release gives one. [progress] gets bytes so far and the total (0 if unknown).
Future<File> downloadUpdate(AppUpdate u, void Function(int got, int total) progress) async {
  final dir = await Directory('${Directory.systemTemp.path}${Platform.pathSeparator}cascade-update').create(recursive: true);
  final file = File('${dir.path}${Platform.pathSeparator}${u.name}');
  final client = http.Client();
  try {
    final res = await client.send(http.Request('GET', Uri.parse(u.url))..headers.addAll(_ua));
    if (res.statusCode != 200) throw HttpException('download: HTTP ${res.statusCode}');
    final total = res.contentLength ?? u.size;
    final sink = file.openWrite();
    final hash = AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(hash);
    var got = 0;
    try {
      await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        hasher.add(chunk);
        progress(got += chunk.length, total);
      }
    } finally {
      await sink.close();
      hasher.close();
    }
    final want = u.digest;
    if (want != null && want.startsWith('sha256:') && want.substring(7).toLowerCase() != hash.events.single.toString()) {
      await file.delete();
      throw const FormatException('The download did not match the release: try again.');
    }
    return file;
  } finally {
    client.close();
  }
}

/// Installs [file] and starts the new version; this copy exits. Windows: the
/// installer runs silently, closes this app if it is still running and starts
/// the new one (/relaunch=1, see packaging/windows/cascade.iss). Linux: the
/// tarball is unpacked beside this folder, the two are swapped and the new one
/// started; the old one goes on the next launch (cleanUpAfterUpdate).
Future<void> installUpdate(File file) async {
  if (Platform.isWindows) {
    await Process.start(file.path, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/relaunch=1'], mode: ProcessStartMode.detached);
    exit(0);
  }
  final app = _installDir, staging = Directory('${app.path}.new');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync();
  final tar = await Process.run('tar', ['-xzf', file.path, '-C', staging.path]);
  final unpacked = Directory('${staging.path}/cascade-flutter');
  if (tar.exitCode != 0 || !File('${unpacked.path}/cascade').existsSync()) {
    staging.deleteSync(recursive: true);
    throw FormatException('Could not unpack the update: ${tar.stderr}'.trim());
  }
  final old = Directory('${app.path}.old');
  if (old.existsSync()) old.deleteSync(recursive: true);
  app.renameSync(old.path);
  unpacked.renameSync(app.path);
  staging.deleteSync(recursive: true);
  await Process.start('${app.path}/cascade', const [], mode: ProcessStartMode.detached);
  exit(0);
}

/// At launch: what an update left behind on Linux.
void cleanUpAfterUpdate() {
  if (!Platform.isLinux || updateKind != UpdateKind.tarball) return;
  for (final d in [Directory('${_installDir.path}.old'), Directory('${_installDir.path}.new')]) {
    try {
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (e) {
      log('updater: could not remove ${d.path}: $e');
    }
  }
}

/// Opens [url] in the browser.
Future<void> openLink(String url) async {
  if (Platform.isWindows) {
    await Process.start('rundll32', ['url.dll,FileProtocolHandler', url], mode: ProcessStartMode.detached);
  } else {
    await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [url], mode: ProcessStartMode.detached);
  }
}

/// The folder this app runs from.
Directory get installDir => File(Platform.resolvedExecutable).parent;
Directory get _installDir => installDir;

// The app folder is swapped as a whole, so its parent must be writable.
bool _canReplace(Directory app) {
  try {
    final probe = Directory('${app.parent.path}/.cascade-write-test-$pid')..createSync();
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

String get _arch => switch (Platform.version) {
  final v when v.contains('arm64') => 'arm64',
  final v when v.contains('x64') => 'x64',
  _ => 'other',
};

/// Collects the one digest a chunked sha256 produces.
class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];
  @override
  void add(T event) => events.add(event);
  @override
  void close() {}
}
