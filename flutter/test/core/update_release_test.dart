// Ported from desktop/test/update-release.test.ts.
import 'package:cascade/core/update_release.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> installers(String v) => [
      'Cascade-$v-arm64.dmg', 'Cascade-$v.AppImage', 'cascade-$v.x86_64.rpm', 'Cascade.Setup.$v.exe', 'cascade_${v}_amd64.deb',
    ].map((name) => {'name': name, 'browser_download_url': 'https://example.invalid/$name'}).toList();

List<String> installerNames(String v) => installers(v).map((a) => a['name'] as String).toList();

ReleaseLike release(String tag, List<Object> names) => {
      'tag_name': tag,
      'assets': [for (final n in names) n is String ? {'name': n} : n],
    };

const InstallTarget mac = (platform: 'darwin', arch: 'arm64', linuxKind: null);
const InstallTarget win = (platform: 'win32', arch: 'x64', linuxKind: null);
InstallTarget linux(String kind, [String arch = 'x64']) => (platform: 'linux', arch: arch, linuxKind: kind);

String native(String v) => 'Cascade-Native-$v.dmg';
ReleaseLike both(String v) => release('v$v', [...installerNames(v), native(v), 'versions.json']);

void main() {
  test('isNewerVersion keeps the old ordering, betas below their release', () {
    expect(isNewerVersion('2.3.0', '2.2.0'), isTrue);
    expect(isNewerVersion('2.2.0', '2.2.0'), isFalse);
    expect(isNewerVersion('2.2.0', '2.3.0'), isFalse);
    expect(isNewerVersion('2.3.0-b2', '2.3.0-b1'), isTrue);
    expect(isNewerVersion('2.3.0', '2.3.0-b4'), isTrue);
    expect(isNewerVersion('2.3.0-b4', '2.3.0'), isFalse);
    expect(isNewerVersion('2.3.0-b1', '2.2.9'), isTrue);
    expect(isNewerVersion('v2.10.0', '2.9.0'), isTrue);
    expect(isNewerVersion('2.3.0-rc1', '2.3.0'), isFalse);
  });

  test('isReleaseVersion takes only x.y.z and x.y.z-bN', () {
    for (final ok in ['2.3.1', '0.0.1', '10.20.30', '2.3.1-b1', '2.3.1-b12']) {
      expect(isReleaseVersion(ok), isTrue, reason: ok);
    }
    for (final bad in ['v2.3.1', '2.3', '999', '2.3.1 ', ' 2.3.1', '2.3.1-b', '2.3.1-b0', '2.3.1-rc1', '02.3.1', '2.3.1.4', '99999.0.0', '2.3.1\n', '', 2.3, null, {}, ['2.3.1']]) {
      expect(isReleaseVersion(bad), isFalse, reason: '$bad');
    }
  });

  test('parseVersionsFile reads the desktop entry of a good file', () {
    expect(parseVersionsFile('{ "desktop": "2.3.1", "apple": "2.3.1", "android": "2.3.2" }'), (ok: true, desktop: '2.3.1', mac: null));
    expect(parseVersionsFile('{"desktop":"2.4.0-b3"}'), (ok: true, desktop: '2.4.0-b3', mac: null));
    expect(parseVersionsFile('{"desktop":"2.3.1","android":42}'), (ok: true, desktop: '2.3.1', mac: null));
  });

  test('parseVersionsFile says so when a good file has no desktop build', () {
    expect(parseVersionsFile('{"android":"2.3.2-b1"}'), (ok: true, desktop: null, mac: null));
    expect(parseVersionsFile('{}'), (ok: true, desktop: null, mac: null));
  });

  test('parseVersionsFile refuses anything malformed', () {
    final bad = <Object?>[
      '', 'not json', '{"desktop":"2.3.1"', '[]', '["2.3.1"]', 'null', '"2.3.1"', '231',
      '{"desktop":null}', '{"desktop":231}', '{"desktop":"999"}', '{"desktop":"v2.3.1"}',
      '{"desktop":"2.3"}', '{"desktop":{"version":"2.3.1"}}', '{"desktop":"<script>"}',
      '{"desktop":"2.3.1","pad":"${'x' * versionsMaxBytes}"}',
      null, 42, <String, Object?>{},
    ];
    for (final text in bad) {
      expect(parseVersionsFile(text), (ok: false, desktop: null, mac: null), reason: '$text'.substring(0, '$text'.length.clamp(0, 60)));
    }
  });

  test('parseVersionsFile is not fooled by an inherited desktop key', () {
    expect(parseVersionsFile('{"__proto__":{"desktop":"9.9.9"}}'), (ok: true, desktop: null, mac: null));
  });

  test('findVersionsAsset matches the exact name only', () {
    expect(findVersionsAsset(release('v2.3.2', ['versions.json.bak', 'Versions.json'])), isNull);
    expect(findVersionsAsset(release('v2.3.2', ['a.dmg', 'versions.json']))?['name'], 'versions.json');
    expect(findVersionsAsset({'tag_name': 'v2.3.2', 'assets': 'nope'}), isNull);
    expect(findVersionsAsset({'tag_name': 'v2.3.2', 'assets': [null, 7, {'name': 3}]}), isNull);
  });

  test('nameCarriesVersion matches the whole version in every real naming style', () {
    for (final n in installerNames('2.3.1')) {
      expect(nameCarriesVersion(n, '2.3.1'), isTrue, reason: n);
    }
    for (final n in installerNames('2.3.1-b2')) {
      expect(nameCarriesVersion(n, '2.3.1-b2'), isTrue, reason: n);
    }
    expect(nameCarriesVersion('Cascade-1.1.1-b-arm64.dmg', '1.1.1-b'), isTrue);
  });

  test('nameCarriesVersion refuses a version that is only part of another', () {
    expect(nameCarriesVersion('Cascade-12.3.1-arm64.dmg', '2.3.1'), isFalse);
    expect(nameCarriesVersion('Cascade-2.3.10-arm64.dmg', '2.3.1'), isFalse);
    expect(nameCarriesVersion('Cascade-1.2.3.1.AppImage', '2.3.1'), isFalse);
    expect(nameCarriesVersion('Cascade.Setup.2.3.1-b2.exe', '2.3.1'), isFalse);
    expect(nameCarriesVersion('Cascade-2.3.1-b12.AppImage', '2.3.1-b1'), isFalse);
    expect(nameCarriesVersion('Cascade-2x3x1.AppImage', '2.3.1'), isFalse);
    expect(nameCarriesVersion('Cascade-2.3.1.AppImage', ''), isFalse);
  });

  test('desktopBuildOf falls back to the tag for every release made before versions.json', () {
    expect(desktopBuildOf(release('v2.2.0', installers('2.2.0')), null), (version: '2.2.0', source: 'tag'));
    expect(desktopBuildOf(release('v2.3.0-b1', installers('2.3.0-b1')), null), (version: '2.3.0-b1', source: 'tag'));
  });

  test('desktopBuildOf uses versions.json over the tag when desktop was carried over', () {
    final carried = release('v2.3.2', [...installers('2.3.1'), 'Cascade-2.3.2.apk', 'versions.json']);
    expect(desktopBuildOf(carried, '{"desktop":"2.3.1","apple":"2.3.1","android":"2.3.2"}'), (version: '2.3.1', source: 'versions.json'));
  });

  test('desktopBuildOf offers nothing when a carry-over release has no readable versions.json', () {
    final carried = release('v2.3.2', [...installers('2.3.1'), 'versions.json']);
    for (final text in [null, '', 'garbage', '{"desktop":"2.3"}', '{"desktop":"9.9.9"}']) {
      expect(desktopBuildOf(carried, text), isNull, reason: '$text');
    }
  });

  test('desktopBuildOf offers nothing for a release with no desktop build', () {
    expect(desktopBuildOf(release('v2.3.2-b1', ['Cascade-2.3.2-b1.apk', 'versions.json']), '{"android":"2.3.2-b1"}'), isNull);
    expect(desktopBuildOf(release('v2.3.2', installers('2.3.2')), '{"apple":"2.3.2"}'), isNull);
  });

  test('desktopBuildOf falls back to the tag when a fresh build has a bad versions.json', () {
    expect(desktopBuildOf(release('v2.3.2', [...installers('2.3.2'), 'versions.json']), '{"desktop":'), (version: '2.3.2', source: 'tag'));
  });

  test('desktopBuildOf ignores a tag that is not a version', () {
    expect(desktopBuildOf(release('models-2026', ['Cascade-models-2026.dmg']), null), isNull);
    expect(desktopBuildOf({'assets': installers('2.2.0')}, null), isNull);
    expect(desktopBuildOf({'tag_name': 7, 'assets': installers('2.2.0')}, null), isNull);
    expect(desktopBuildOf(release('v2.2.0/../../x', ['Cascade-2.2.0/../../x.dmg']), null), isNull);
  });

  test('desktopBuildOf still reports an update an Intel Mac has no installer for', () {
    final r = release('v2.3.0', ['Cascade-2.3.0-arm64.dmg']);
    expect(desktopBuildOf(r, null), (version: '2.3.0', source: 'tag'));
    expect(pickInstaller(r, '2.3.0', (platform: 'darwin', arch: 'x64', linuxKind: null)), isNull);
  });

  test('pickInstaller picks the carried-over installer by its own version', () {
    final r = release('v2.3.2', [...installers('2.3.1'), 'Cascade-2.3.2-arm64.dmg.fake', 'versions.json']);
    expect(pickInstaller(r, '2.3.1', mac)?['name'], 'Cascade-2.3.1-arm64.dmg');
    expect(pickInstaller(r, '2.3.1', win)?['name'], 'Cascade.Setup.2.3.1.exe');
    expect(pickInstaller(r, '2.3.1', linux('deb'))?['name'], 'cascade_2.3.1_amd64.deb');
    expect(pickInstaller(r, '2.3.1', linux('rpm'))?['name'], 'cascade-2.3.1.x86_64.rpm');
    expect(pickInstaller(r, '2.3.1', linux('AppImage'))?['name'], 'Cascade-2.3.1.AppImage');
    expect(pickInstaller(r, '2.3.1', linux('deb', 'arm64')), isNull);
  });

  test('pickInstaller never hands over an installer of another version', () {
    final r = release('v2.3.2', ['Cascade-2.3.2-arm64.dmg', 'Cascade.Setup.2.3.2.exe']);
    expect(pickInstaller(r, '2.3.1', mac), isNull);
    expect(pickInstaller(r, '2.3.1', win), isNull);
  });

  test('pickInstaller keeps the old per-platform rules', () {
    final r = release('v2.0.1', [...installers('2.0.1'), 'Cascade-2.0.1.dmg']);
    expect(pickInstaller(r, '2.0.1', mac)?['name'], 'Cascade-2.0.1-arm64.dmg');
    expect(pickInstaller(r, '2.0.1', (platform: 'linux', arch: 'x64', linuxKind: null)), isNull);
    expect(pickInstaller(r, '2.0.1', (platform: 'freebsd', arch: 'x64', linuxKind: null)), isNull);
  });

  test('parseVersionsFile reads the mac entry, and a bad one is no entry rather than a bad file', () {
    expect(parseVersionsFile('{"desktop":"2.4.0","mac":"2.4.1"}'), (ok: true, desktop: '2.4.0', mac: '2.4.1'));
    expect(parseVersionsFile('{"mac":"2.4.1-b2"}'), (ok: true, desktop: null, mac: '2.4.1-b2'));
    expect(parseVersionsFile('{"desktop":"2.4.0","mac":"../x"}'), (ok: true, desktop: '2.4.0', mac: null));
    expect(parseVersionsFile('{"desktop":"2.4.0","mac":7}'), (ok: true, desktop: '2.4.0', mac: null));
    expect(parseVersionsFile('{"__proto__":{"mac":"9.9.9"}}'), (ok: true, desktop: null, mac: null));
  });

  test('isNativeMacInstaller recognizes only the native DMG', () {
    expect(isNativeMacInstaller('Cascade-Native-2.4.0.dmg'), isTrue);
    expect(isNativeMacInstaller('Cascade-Native-2.4.0-b1.dmg'), isTrue);
    expect(isNativeMacInstaller('Cascade-2.4.0-arm64.dmg'), isFalse);
    expect(isNativeMacInstaller('Cascade-Native-2.4.0.dmg.blockmap'), isFalse);
    expect(isNativeMacInstaller('x/Cascade-Native-2.4.0.dmg'), isFalse);
  });

  test('with both DMGs in a release, an unset or electron macBuild gets the Electron one', () {
    final r = both('2.4.0');
    const text = '{"desktop":"2.4.0","mac":"2.4.0"}';
    for (final b in [null, 'electron']) {
      expect(desktopBuildOf(r, text, b), (version: '2.4.0', source: 'versions.json'));
      expect(pickInstaller(r, '2.4.0', mac, b)?['name'], 'Cascade-2.4.0-arm64.dmg');
    }
    expect(pickInstaller(r, '2.4.0', mac)?['name'], 'Cascade-2.4.0-arm64.dmg');
  });

  test('an updater from before the native app can never be handed the native DMG', () {
    Map? old(ReleaseLike rel, String v) {
      for (final a in rel['assets'] as List) {
        final n = a['name'] as String;
        if (RegExp(r'\.dmg$', caseSensitive: false).hasMatch(n) && RegExp('arm64', caseSensitive: false).hasMatch(n) && n.contains(v)) return a as Map;
      }
      return null;
    }

    expect(old(both('2.4.0'), '2.4.0')?['name'], 'Cascade-2.4.0-arm64.dmg');
    final flipped = release('v2.4.0', [native('2.4.0'), 'Cascade-2.4.0-arm64.dmg']);
    expect(old(flipped, '2.4.0')?['name'], 'Cascade-2.4.0-arm64.dmg');
    expect(pickInstaller(flipped, '2.4.0', mac)?['name'], 'Cascade-2.4.0-arm64.dmg');
  });

  test('macBuild native reads the mac entry and the native asset', () {
    final r = both('2.4.0');
    expect(desktopBuildOf(r, '{"desktop":"2.4.0","mac":"2.4.0"}', 'native'), (version: '2.4.0', source: 'versions.json'));
    expect(pickInstaller(r, '2.4.0', mac, 'native')?['name'], 'Cascade-Native-2.4.0.dmg');
    final mixed = release('v2.4.0', [...installerNames('2.3.1'), native('2.4.0'), 'versions.json']);
    const text = '{"desktop":"2.3.1","mac":"2.4.0"}';
    expect(desktopBuildOf(mixed, text, 'native'), (version: '2.4.0', source: 'versions.json'));
    expect(pickInstaller(mixed, '2.4.0', mac, 'native')?['name'], 'Cascade-Native-2.4.0.dmg');
    expect(desktopBuildOf(mixed, text), (version: '2.3.1', source: 'versions.json'));
    expect(pickInstaller(mixed, '2.3.1', mac)?['name'], 'Cascade-2.3.1-arm64.dmg');
    final beta = release('v2.5.0-b1', [native('2.5.0-b1'), 'versions.json']);
    expect(desktopBuildOf(beta, '{"mac":"2.5.0-b1"}', 'native'), (version: '2.5.0-b1', source: 'versions.json'));
    expect(pickInstaller(beta, '2.5.0-b1', mac, 'native')?['name'], 'Cascade-Native-2.5.0-b1.dmg');
    expect(pickInstaller(beta, '2.5.0-b1', (platform: 'darwin', arch: 'x64', linuxKind: null), 'native'), isNull);
  });

  test('macBuild native offers nothing without a mac entry, a native asset, or a readable file', () {
    final r = both('2.4.0');
    expect(desktopBuildOf(r, '{"desktop":"2.4.0"}', 'native'), isNull);
    expect(desktopBuildOf(r, '{"desktop":"2.4.0","mac":"junk"}', 'native'), isNull);
    expect(desktopBuildOf(r, null, 'native'), isNull);
    expect(desktopBuildOf(r, '{"mac":', 'native'), isNull);
    expect(desktopBuildOf(release('v2.4.0', installerNames('2.4.0')), '{"mac":"2.4.0"}', 'native'), isNull);
    expect(desktopBuildOf(release('v2.4.0', [native('2.3.0')]), '{"mac":"2.4.0"}', 'native'), isNull);
    expect(desktopBuildOf(release('v2.4.0', ['Cascade-2.4.0-arm64.dmg']), '{"mac":"2.4.0"}', 'native'), isNull);
    expect(pickInstaller(release('v2.4.0', ['Cascade-2.4.0-arm64.dmg']), '2.4.0', mac, 'native'), isNull);
  });

  test('macBuild never changes what Windows and Linux are handed', () {
    final r = both('2.4.0');
    expect(pickInstaller(r, '2.4.0', win, 'native')?['name'], 'Cascade.Setup.2.4.0.exe');
    expect(pickInstaller(r, '2.4.0', linux('deb'), 'native')?['name'], 'cascade_2.4.0_amd64.deb');
  });

  test('a native DMG alone never proves an Electron build, so a bad versions.json offers nothing', () {
    final r = release('v2.4.1', [native('2.4.1'), 'versions.json']);
    expect(desktopBuildOf(r, null), isNull);
    expect(desktopBuildOf(r, '{"desktop":'), isNull);
    expect(desktopBuildOf(r, '{"desktop":"2.4.1","mac":"2.4.1"}'), isNull);
    expect(desktopBuildOf(r, '{"desktop":"2.4.0","mac":"2.4.1"}'), isNull);
  });
}
