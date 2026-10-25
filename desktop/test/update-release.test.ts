import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  VERSIONS_MAX_BYTES, desktopBuildOf, findVersionsAsset, isNativeMacInstaller, isNewerVersion,
  isReleaseVersion, nameCarriesVersion, parseVersionsFile, pickInstaller,
  type InstallTarget, type ReleaseLike,
} from '../src/core/update-release.ts'

// The asset names electron-builder and GitHub actually produced for v2.2.0.
const installers = (v: string) => [
  `Cascade-${v}-arm64.dmg`, `Cascade-${v}.AppImage`, `cascade-${v}.x86_64.rpm`,
  `Cascade.Setup.${v}.exe`, `cascade_${v}_amd64.deb`,
].map(name => ({ name, browser_download_url: `https://example.invalid/${name}` }))

const release = (tag: string, ...names: (string | { name: string })[]): ReleaseLike => ({
  tag_name: tag,
  assets: names.map(n => typeof n === 'string' ? { name: n } : n),
})

const MAC: InstallTarget = { platform: 'darwin', arch: 'arm64', linuxKind: null }
const WIN: InstallTarget = { platform: 'win32', arch: 'x64', linuxKind: null }

test('isNewerVersion keeps the old ordering, betas below their release', () => {
  assert.equal(isNewerVersion('2.3.0', '2.2.0'), true)
  assert.equal(isNewerVersion('2.2.0', '2.2.0'), false)
  assert.equal(isNewerVersion('2.2.0', '2.3.0'), false)
  assert.equal(isNewerVersion('2.3.0-b2', '2.3.0-b1'), true)
  assert.equal(isNewerVersion('2.3.0', '2.3.0-b4'), true)
  assert.equal(isNewerVersion('2.3.0-b4', '2.3.0'), false)
  assert.equal(isNewerVersion('2.3.0-b1', '2.2.9'), true)
  assert.equal(isNewerVersion('v2.10.0', '2.9.0'), true)
  // Any other suffix is stripped, so it compares equal to the release.
  assert.equal(isNewerVersion('2.3.0-rc1', '2.3.0'), false)
})

test('isReleaseVersion takes only x.y.z and x.y.z-bN', () => {
  for (const ok of ['2.3.1', '0.0.1', '10.20.30', '2.3.1-b1', '2.3.1-b12']) assert.equal(isReleaseVersion(ok), true, ok)
  for (const bad of ['v2.3.1', '2.3', '999', '2.3.1 ', ' 2.3.1', '2.3.1-b', '2.3.1-b0', '2.3.1-rc1',
    '02.3.1', '2.3.1.4', '99999.0.0', '2.3.1\n', '', 2.3, null, undefined, {}, ['2.3.1']]) {
    assert.equal(isReleaseVersion(bad), false, JSON.stringify(bad))
  }
})

test('parseVersionsFile reads the desktop entry of a good file', () => {
  assert.deepEqual(parseVersionsFile('{ "desktop": "2.3.1", "apple": "2.3.1", "android": "2.3.2" }'), { ok: true, desktop: '2.3.1', mac: null })
  assert.deepEqual(parseVersionsFile('{"desktop":"2.4.0-b3"}'), { ok: true, desktop: '2.4.0-b3', mac: null })
  // Other platforms are not checked: a bad android entry is not desktop's problem.
  assert.deepEqual(parseVersionsFile('{"desktop":"2.3.1","android":42}'), { ok: true, desktop: '2.3.1', mac: null })
})

test('parseVersionsFile says so when a good file has no desktop build', () => {
  assert.deepEqual(parseVersionsFile('{"android":"2.3.2-b1"}'), { ok: true, desktop: null, mac: null })
  assert.deepEqual(parseVersionsFile('{}'), { ok: true, desktop: null, mac: null })
})

test('parseVersionsFile refuses anything malformed', () => {
  const bad = [
    '', 'not json', '{"desktop":"2.3.1"', '[]', '["2.3.1"]', 'null', '"2.3.1"', '231',
    '{"desktop":null}', '{"desktop":231}', '{"desktop":"999"}', '{"desktop":"v2.3.1"}',
    '{"desktop":"2.3"}', '{"desktop":{"version":"2.3.1"}}', '{"desktop":"<script>"}',
    `{"desktop":"2.3.1","pad":"${'x'.repeat(VERSIONS_MAX_BYTES)}"}`,
    null, undefined, 42, {},
  ]
  for (const text of bad) assert.deepEqual(parseVersionsFile(text), { ok: false }, JSON.stringify(text)?.slice(0, 60))
})

test('parseVersionsFile is not fooled by an inherited desktop key', () => {
  assert.deepEqual(parseVersionsFile('{"__proto__":{"desktop":"9.9.9"}}'), { ok: true, desktop: null, mac: null })
})

test('findVersionsAsset matches the exact name only', () => {
  assert.equal(findVersionsAsset(release('v2.3.2', 'versions.json.bak', 'Versions.json'))?.name, undefined)
  assert.equal(findVersionsAsset(release('v2.3.2', 'a.dmg', 'versions.json'))?.name, 'versions.json')
  assert.equal(findVersionsAsset({ tag_name: 'v2.3.2', assets: 'nope' }), undefined)
  assert.equal(findVersionsAsset({ tag_name: 'v2.3.2', assets: [null, 7, { name: 3 }] }), undefined)
})

test('nameCarriesVersion matches the whole version in every real naming style', () => {
  for (const { name } of installers('2.3.1')) assert.equal(nameCarriesVersion(name, '2.3.1'), true, name)
  for (const { name } of installers('2.3.1-b2')) assert.equal(nameCarriesVersion(name, '2.3.1-b2'), true, name)
  assert.equal(nameCarriesVersion('Cascade-1.1.1-b-arm64.dmg', '1.1.1-b'), true)
})

test('nameCarriesVersion refuses a version that is only part of another', () => {
  assert.equal(nameCarriesVersion('Cascade-12.3.1-arm64.dmg', '2.3.1'), false)
  assert.equal(nameCarriesVersion('Cascade-2.3.10-arm64.dmg', '2.3.1'), false)
  assert.equal(nameCarriesVersion('Cascade-1.2.3.1.AppImage', '2.3.1'), false)
  assert.equal(nameCarriesVersion('Cascade.Setup.2.3.1-b2.exe', '2.3.1'), false)
  assert.equal(nameCarriesVersion('Cascade-2.3.1-b12.AppImage', '2.3.1-b1'), false)
  assert.equal(nameCarriesVersion('Cascade-2x3x1.AppImage', '2.3.1'), false)
  assert.equal(nameCarriesVersion('Cascade-2.3.1.AppImage', ''), false)
})

test('desktopBuildOf falls back to the tag for every release made before versions.json', () => {
  assert.deepEqual(desktopBuildOf(release('v2.2.0', ...installers('2.2.0')), null), { version: '2.2.0', source: 'tag' })
  assert.deepEqual(desktopBuildOf(release('v2.3.0-b1', ...installers('2.3.0-b1')), null), { version: '2.3.0-b1', source: 'tag' })
})

test('desktopBuildOf uses versions.json over the tag when desktop was carried over', () => {
  const carried = release('v2.3.2', ...installers('2.3.1'), 'Cascade-2.3.2.apk', 'versions.json')
  assert.deepEqual(desktopBuildOf(carried, '{"desktop":"2.3.1","apple":"2.3.1","android":"2.3.2"}'),
    { version: '2.3.1', source: 'versions.json' })
})

test('desktopBuildOf offers nothing when a carry-over release has no readable versions.json', () => {
  // The loop the plan warns about: v2.3.2 holding desktop 2.3.1 must never
  // read as desktop 2.3.2, whatever happened to the file.
  const carried = release('v2.3.2', ...installers('2.3.1'), 'versions.json')
  for (const text of [null, '', 'garbage', '{"desktop":"2.3"}', '{"desktop":"9.9.9"}']) {
    assert.equal(desktopBuildOf(carried, text), null, String(text))
  }
})

test('desktopBuildOf offers nothing for a release with no desktop build', () => {
  // A beta built only for Android.
  assert.equal(desktopBuildOf(release('v2.3.2-b1', 'Cascade-2.3.2-b1.apk', 'versions.json'), '{"android":"2.3.2-b1"}'), null)
  // A well-formed file saying "no desktop" is believed even if the tag matches installers.
  assert.equal(desktopBuildOf(release('v2.3.2', ...installers('2.3.2')), '{"apple":"2.3.2"}'), null)
})

test('desktopBuildOf falls back to the tag when a fresh build has a bad versions.json', () => {
  assert.deepEqual(desktopBuildOf(release('v2.3.2', ...installers('2.3.2'), 'versions.json'), '{"desktop":'),
    { version: '2.3.2', source: 'tag' })
})

test('desktopBuildOf ignores a tag that is not a version', () => {
  assert.equal(desktopBuildOf(release('models-2026', 'Cascade-models-2026.dmg'), null), null)
  assert.equal(desktopBuildOf({ assets: installers('2.2.0') }, null), null)
  assert.equal(desktopBuildOf({ tag_name: 7, assets: installers('2.2.0') }, null), null)
  assert.equal(desktopBuildOf(release('v2.2.0/../../x', 'Cascade-2.2.0/../../x.dmg'), null), null)
})

test('desktopBuildOf still reports an update an Intel Mac has no installer for', () => {
  // Only the arm64 dmg exists; the Intel Mac is sent to the release page.
  const r = release('v2.3.0', 'Cascade-2.3.0-arm64.dmg')
  assert.deepEqual(desktopBuildOf(r, null), { version: '2.3.0', source: 'tag' })
  assert.equal(pickInstaller(r, '2.3.0', { platform: 'darwin', arch: 'x64', linuxKind: null }), undefined)
})

test('pickInstaller picks the carried-over installer by its own version', () => {
  const r = release('v2.3.2', ...installers('2.3.1'), 'Cascade-2.3.2-arm64.dmg.fake', 'versions.json')
  assert.equal(pickInstaller(r, '2.3.1', MAC)?.name, 'Cascade-2.3.1-arm64.dmg')
  assert.equal(pickInstaller(r, '2.3.1', WIN)?.name, 'Cascade.Setup.2.3.1.exe')
  assert.equal(pickInstaller(r, '2.3.1', { platform: 'linux', arch: 'x64', linuxKind: 'deb' })?.name, 'cascade_2.3.1_amd64.deb')
  assert.equal(pickInstaller(r, '2.3.1', { platform: 'linux', arch: 'x64', linuxKind: 'rpm' })?.name, 'cascade-2.3.1.x86_64.rpm')
  assert.equal(pickInstaller(r, '2.3.1', { platform: 'linux', arch: 'x64', linuxKind: 'AppImage' })?.name, 'Cascade-2.3.1.AppImage')
  // No arm64 Linux build exists, so an arm64 machine gets nothing, not the amd64 package.
  assert.equal(pickInstaller(r, '2.3.1', { platform: 'linux', arch: 'arm64', linuxKind: 'deb' }), undefined)
})

test('pickInstaller never hands over an installer of another version', () => {
  const r = release('v2.3.2', 'Cascade-2.3.2-arm64.dmg', 'Cascade.Setup.2.3.2.exe')
  assert.equal(pickInstaller(r, '2.3.1', MAC), undefined)
  assert.equal(pickInstaller(r, '2.3.1', WIN), undefined)
})

test('pickInstaller keeps the old per-platform rules', () => {
  // 2.0.x shipped an unsuffixed x64 dmg too; Apple Silicon must get arm64.
  const r = release('v2.0.1', ...installers('2.0.1'), 'Cascade-2.0.1.dmg')
  assert.equal(pickInstaller(r, '2.0.1', MAC)?.name, 'Cascade-2.0.1-arm64.dmg')
  assert.equal(pickInstaller(r, '2.0.1', { platform: 'linux', arch: 'x64', linuxKind: null }), undefined)
  assert.equal(pickInstaller(r, '2.0.1', { platform: 'freebsd', arch: 'x64', linuxKind: null }), undefined)
})

// ── The native Mac app's DMG beside the Electron one ─────────────────────────

const NATIVE = (v: string) => `Cascade-Native-${v}.dmg`
const BOTH = (v: string) => release(`v${v}`, ...installers(v).map(a => a.name), NATIVE(v), 'versions.json')

test('parseVersionsFile reads the mac entry, and a bad one is no entry rather than a bad file', () => {
  assert.deepEqual(parseVersionsFile('{"desktop":"2.4.0","mac":"2.4.1"}'), { ok: true, desktop: '2.4.0', mac: '2.4.1' })
  assert.deepEqual(parseVersionsFile('{"mac":"2.4.1-b2"}'), { ok: true, desktop: null, mac: '2.4.1-b2' })
  assert.deepEqual(parseVersionsFile('{"desktop":"2.4.0","mac":"../x"}'), { ok: true, desktop: '2.4.0', mac: null })
  assert.deepEqual(parseVersionsFile('{"desktop":"2.4.0","mac":7}'), { ok: true, desktop: '2.4.0', mac: null })
  assert.deepEqual(parseVersionsFile('{"__proto__":{"mac":"9.9.9"}}'), { ok: true, desktop: null, mac: null })
})

test('isNativeMacInstaller recognizes only the native DMG', () => {
  assert.equal(isNativeMacInstaller('Cascade-Native-2.4.0.dmg'), true)
  assert.equal(isNativeMacInstaller('Cascade-Native-2.4.0-b1.dmg'), true)
  assert.equal(isNativeMacInstaller('Cascade-2.4.0-arm64.dmg'), false)
  assert.equal(isNativeMacInstaller('Cascade-Native-2.4.0.dmg.blockmap'), false)
  assert.equal(isNativeMacInstaller('x/Cascade-Native-2.4.0.dmg'), false)
})

test('with both DMGs in a release, an unset or electron macBuild gets the Electron one', () => {
  const r = BOTH('2.4.0')
  const text = '{"desktop":"2.4.0","mac":"2.4.0"}'
  for (const macBuild of [undefined, null, 'electron'] as const) {
    assert.deepEqual(desktopBuildOf(r, text, macBuild), { version: '2.4.0', source: 'versions.json' })
    assert.equal(pickInstaller(r, '2.4.0', MAC, macBuild)?.name, 'Cascade-2.4.0-arm64.dmg')
  }
  // Without the argument at all, exactly as before the native app existed.
  assert.equal(pickInstaller(r, '2.4.0', MAC)?.name, 'Cascade-2.4.0-arm64.dmg')
})

test('an updater from before the native app can never be handed the native DMG', () => {
  // The old rule, verbatim: the first .dmg that contains arm64 and the desktop version.
  const old = (rel: ReleaseLike, v: string) => (rel.assets as { name: string }[]).find(a => /\.dmg$/i.test(a.name) && /arm64/i.test(a.name) && a.name.includes(v))
  const r = BOTH('2.4.0')
  assert.equal(old(r, '2.4.0')?.name, 'Cascade-2.4.0-arm64.dmg')
  // Even with the native DMG listed first.
  const flipped = release('v2.4.0', NATIVE('2.4.0'), 'Cascade-2.4.0-arm64.dmg')
  assert.equal(old(flipped, '2.4.0')?.name, 'Cascade-2.4.0-arm64.dmg')
  assert.equal(pickInstaller(flipped, '2.4.0', MAC)?.name, 'Cascade-2.4.0-arm64.dmg')
})

test('macBuild native reads the mac entry and the native asset', () => {
  const r = BOTH('2.4.0')
  assert.deepEqual(desktopBuildOf(r, '{"desktop":"2.4.0","mac":"2.4.0"}', 'native'), { version: '2.4.0', source: 'versions.json' })
  assert.equal(pickInstaller(r, '2.4.0', MAC, 'native')?.name, 'Cascade-Native-2.4.0.dmg')
  // The two versions can differ: Electron carried over at 2.3.1, native new.
  const mixed = release('v2.4.0', ...installers('2.3.1').map(a => a.name), NATIVE('2.4.0'), 'versions.json')
  const text = '{"desktop":"2.3.1","mac":"2.4.0"}'
  assert.deepEqual(desktopBuildOf(mixed, text, 'native'), { version: '2.4.0', source: 'versions.json' })
  assert.equal(pickInstaller(mixed, '2.4.0', MAC, 'native')?.name, 'Cascade-Native-2.4.0.dmg')
  assert.deepEqual(desktopBuildOf(mixed, text), { version: '2.3.1', source: 'versions.json' })
  assert.equal(pickInstaller(mixed, '2.3.1', MAC)?.name, 'Cascade-2.3.1-arm64.dmg')
  // A native beta, and an Intel Mac, which the native app does not support.
  const beta = release('v2.5.0-b1', NATIVE('2.5.0-b1'), 'versions.json')
  assert.deepEqual(desktopBuildOf(beta, '{"mac":"2.5.0-b1"}', 'native'), { version: '2.5.0-b1', source: 'versions.json' })
  assert.equal(pickInstaller(beta, '2.5.0-b1', MAC, 'native')?.name, 'Cascade-Native-2.5.0-b1.dmg')
  assert.equal(pickInstaller(beta, '2.5.0-b1', { platform: 'darwin', arch: 'x64', linuxKind: null }, 'native'), undefined)
})

test('macBuild native offers nothing without a mac entry, a native asset, or a readable file', () => {
  const r = BOTH('2.4.0')
  assert.equal(desktopBuildOf(r, '{"desktop":"2.4.0"}', 'native'), null)
  assert.equal(desktopBuildOf(r, '{"desktop":"2.4.0","mac":"junk"}', 'native'), null)
  // No tag fallback: the tag names no native version.
  assert.equal(desktopBuildOf(r, null, 'native'), null)
  assert.equal(desktopBuildOf(r, '{"mac":', 'native'), null)
  // An entry with no DMG behind it, or a DMG of another version.
  assert.equal(desktopBuildOf(release('v2.4.0', ...installers('2.4.0').map(a => a.name)), '{"mac":"2.4.0"}', 'native'), null)
  assert.equal(desktopBuildOf(release('v2.4.0', NATIVE('2.3.0')), '{"mac":"2.4.0"}', 'native'), null)
  assert.equal(desktopBuildOf(release('v2.4.0', 'Cascade-2.4.0-arm64.dmg'), '{"mac":"2.4.0"}', 'native'), null)
  // And the Electron DMG is never the native pick.
  assert.equal(pickInstaller(release('v2.4.0', 'Cascade-2.4.0-arm64.dmg'), '2.4.0', MAC, 'native'), undefined)
})

test('macBuild never changes what Windows and Linux are handed', () => {
  const r = BOTH('2.4.0')
  assert.equal(pickInstaller(r, '2.4.0', WIN, 'native')?.name, 'Cascade.Setup.2.4.0.exe')
  assert.equal(pickInstaller(r, '2.4.0', { platform: 'linux', arch: 'x64', linuxKind: 'deb' }, 'native')?.name, 'cascade_2.4.0_amd64.deb')
})

test('a native DMG alone never proves an Electron build, so a bad versions.json offers nothing', () => {
  // v2.4.1 holds only the native DMG; Electron is carried at 2.4.0. If
  // versions.json cannot be read the tag is used, and the native file must
  // not make that look like a desktop 2.4.1.
  const r = release('v2.4.1', NATIVE('2.4.1'), 'versions.json')
  assert.equal(desktopBuildOf(r, null), null)
  assert.equal(desktopBuildOf(r, '{"desktop":'), null)
  assert.equal(desktopBuildOf(r, '{"desktop":"2.4.1","mac":"2.4.1"}'), null)
  // A versions.json that says desktop 2.4.0 with only 2.4.1 files offers nothing either.
  assert.equal(desktopBuildOf(r, '{"desktop":"2.4.0","mac":"2.4.1"}'), null)
})
