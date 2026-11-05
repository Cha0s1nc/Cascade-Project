// What the desktop updater takes from a GitHub release: which desktop version
// it holds, and which file installs it on this computer. Pure. Ported from
// desktop/src/core/update-release.ts. A release is a Map as GitHub's API
// returns it (`tag_name`, `assets`); an asset is a Map with a `name`.

import 'dart:convert' show JsonDecoder;

/// A GitHub release's JSON (only `tag_name` and `assets` are read).
typedef ReleaseLike = Map<String, dynamic>;

/// A release asset's JSON (`name`, and usually `browser_download_url`).
typedef ReleaseAsset = Map<String, dynamic>;

/// Which installer this computer can run. [linuxKind] is 'AppImage', 'deb', 'rpm' or null.
typedef InstallTarget = ({String platform, String arch, String? linuxKind});

/// Which Mac app a Mac is on: 'electron' or 'native'. Unset means electron.
bool isMacBuild(Object? v) => v == 'electron' || v == 'native';

const versionsAssetName = 'versions.json';

/// versions.json is far under this; anything near it is not that file.
const versionsMaxBytes = 4096;

final _versionRe = RegExp(r'^(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})(-b[1-9]\d{0,3})?$');

/// Strict x.y.z or x.y.z-bN, so "2.3", "v2.3.1" and "2.3.1 " are all refused.
bool isReleaseVersion(Object? v) => v is String && _versionRe.hasMatch(v);

int _parseIntPrefix(String s) {
  final m = RegExp(r'^\s*[+-]?\d+').firstMatch(s);
  return m == null ? 0 : int.parse(m[0]!.trim().replaceFirst('+', ''));
}

/// [major, minor, patch, beta]. A release sorts above every `-bN` beta (beta is infinity for a release). Any other suffix is stripped.
List<num> parseAppVersion(Object? v) {
  final s = '$v'.replaceFirst(RegExp(r'^v'), '');
  final betaMatch = RegExp(r'-b(\d+)$', caseSensitive: false).firstMatch(s);
  final num beta = betaMatch != null ? int.parse(betaMatch[1]!) : double.infinity;
  final parts = s.replaceFirst(RegExp(r'[-+][a-zA-Z0-9._]*$'), '').split('.').map(_parseIntPrefix).toList();
  return [parts.isNotEmpty ? parts[0] : 0, parts.length > 1 ? parts[1] : 0, parts.length > 2 ? parts[2] : 0, beta];
}

/// Whether [latest] is a newer version than [current], betas below their release.
bool isNewerVersion(Object? latest, Object? current) {
  final l = parseAppVersion(latest), c = parseAppVersion(current);
  for (var i = 0; i < 4; i++) {
    if (l[i] != c[i]) return l[i] > c[i];
  }
  return false;
}

/// The release's assets, keeping only entries shaped like one.
List<ReleaseAsset> releaseAssets(ReleaseLike release) {
  final a = release['assets'];
  return a is List
      ? [
          for (final x in a)
            if (x is Map && x['name'] is String) x.cast<String, dynamic>(),
        ]
      : [];
}

/// The release's versions.json asset, if it has one. The name must match exactly.
ReleaseAsset? findVersionsAsset(ReleaseLike release) {
  for (final a in releaseAssets(release)) {
    if (a['name'] == versionsAssetName) return a;
  }
  return null;
}

/// A parsed versions.json: [desktop] null means a good file with no desktop entry.
typedef VersionsFile = ({bool ok, String? desktop, String? mac});

const _badVersions = (ok: false, desktop: null, mac: null);

/// Reads a versions.json. Untrusted. A bad desktop entry makes the file not ok; a bad mac entry is just no entry.
VersionsFile parseVersionsFile(Object? text) {
  if (text is! String || text.length > versionsMaxBytes) return _badVersions;
  final Object? data;
  try {
    data = _jsonDecode(text);
  } catch (_) {
    return _badVersions;
  }
  if (data is! Map) return _badVersions;
  final mac = isReleaseVersion(data['mac']) ? data['mac'] as String : null;
  if (!data.containsKey('desktop')) return (ok: true, desktop: null, mac: mac);
  final desktop = data['desktop'];
  return isReleaseVersion(desktop) ? (ok: true, desktop: desktop as String, mac: mac) : _badVersions;
}

Object? _jsonDecode(String s) => const JsonDecoder().convert(s);

final _installerRe = RegExp(r'\.(exe|dmg|AppImage|deb|rpm)$', caseSensitive: false);

/// A desktop installer, as opposed to versions.json, an .ipa, an .apk, a blockmap.
bool isDesktopInstaller(String name) => _installerRe.hasMatch(name);

final _nativeMacRe = RegExp(r'^Cascade-Native-.+\.dmg$', caseSensitive: false);

/// The native Mac app's DMG, named without "arm64" so no older updater can pick it.
bool isNativeMacInstaller(String name) => _nativeMacRe.hasMatch(name);

/// Whether a file name carries exactly this version: 2.3.1 is not in 12.3.1, 2.3.10, 1.2.3.1 or 2.3.1-b2.
bool nameCarriesVersion(String name, String version) {
  if (version.isEmpty) return false;
  return RegExp('(?<!\\d)(?<!\\d\\.)${RegExp.escape(version)}(?!\\d|\\.\\d|-b)').hasMatch(name);
}

/// A desktop version and where it came from ('versions.json' or 'tag').
typedef DesktopBuild = ({String version, String source});

/// The desktop version a release holds, or null. Needs a desktop installer carrying that version, so a bad file or a carried-over release never causes an offer on its own. With [macBuild] 'native' the version is the `mac` entry, proved by Cascade-Native-VERSION.dmg, with no tag fallback.
DesktopBuild? desktopBuildOf(ReleaseLike release, String? versionsText, [String? macBuild]) {
  if (macBuild == 'native') {
    final file = versionsText == null ? null : parseVersionsFile(versionsText);
    if (file == null || !file.ok || file.mac == null) return null;
    final mac = file.mac!;
    final built = releaseAssets(release).any((a) => isNativeMacInstaller(a['name']) && nameCarriesVersion(a['name'], mac));
    return built ? (version: mac, source: 'versions.json') : null;
  }
  DesktopBuild? pick;
  final file = versionsText == null ? null : parseVersionsFile(versionsText);
  if (file != null && file.ok) {
    if (file.desktop == null) return null;
    pick = (version: file.desktop!, source: 'versions.json');
  } else if (release['tag_name'] is String) {
    final tag = (release['tag_name'] as String).replaceFirst(RegExp(r'^v'), '');
    if (RegExp(r'^\d+\.\d+\.\d+(-[A-Za-z0-9.]*)?$').hasMatch(tag)) pick = (version: tag, source: 'tag');
  }
  if (pick == null) return null;
  final version = pick.version;
  final built = releaseAssets(release).any((a) => isDesktopInstaller(a['name']) && !isNativeMacInstaller(a['name']) && nameCarriesVersion(a['name'], version));
  return built ? pick : null;
}

/// The installer for this computer carrying [version], or null. No "close enough" fallback. [macBuild] only matters on a Mac.
ReleaseAsset? pickInstaller(ReleaseLike release, String version, InstallTarget target, [String? macBuild]) {
  final assets = releaseAssets(release).where((a) => nameCarriesVersion(a['name'], version)).toList();
  ReleaseAsset? first(bool Function(String) test) {
    for (final a in assets) {
      if (test(a['name'])) return a;
    }
    return null;
  }

  bool ext(String name, String e) => name.toLowerCase().endsWith('.${e.toLowerCase()}');

  if (target.platform == 'win32') return first((n) => ext(n, 'exe'));
  if (target.platform == 'darwin') {
    if (target.arch != 'arm64') return null;
    return macBuild == 'native'
        ? first((n) => ext(n, 'dmg') && isNativeMacInstaller(n))
        : first((n) => ext(n, 'dmg') && RegExp('arm64', caseSensitive: false).hasMatch(n) && !isNativeMacInstaller(n));
  }
  if (target.platform == 'linux') {
    if (target.arch != 'x64') return null;
    switch (target.linuxKind) {
      case 'AppImage':
        return first((n) => ext(n, 'AppImage'));
      case 'deb':
        return first((n) => ext(n, 'deb'));
      case 'rpm':
        return first((n) => ext(n, 'rpm'));
    }
  }
  return null;
}
