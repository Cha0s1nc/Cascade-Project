import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  VERSIONS_MAX_BYTES, desktopBuildOf, findVersionsAsset, isNewerVersion,
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
  assert.deepEqual(parseVersionsFile('{ "desktop": "2.3.1", "apple": "2.3.1", "android": "2.3.2" }'), { ok: true, desktop: '2.3.1' })
  assert.deepEqual(parseVersionsFile('{"desktop":"2.4.0-b3"}'), { ok: true, desktop: '2.4.0-b3' })
  // Other platforms are not checked: a bad android entry is not desktop's problem.
  assert.deepEqual(parseVersionsFile('{"desktop":"2.3.1","android":42}'), { ok: true, desktop: '2.3.1' })
})

test('parseVersionsFile says so when a good file has no desktop build', () => {
  assert.deepEqual(parseVersionsFile('{"android":"2.3.2-b1"}'), { ok: true, desktop: null })
  assert.deepEqual(parseVersionsFile('{}'), { ok: true, desktop: null })
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
  assert.deepEqual(parseVersionsFile('{"__proto__":{"desktop":"9.9.9"}}'), { ok: true, desktop: null })
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
