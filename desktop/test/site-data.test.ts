import { test } from 'node:test'
import assert from 'node:assert/strict'
import { siteReleases } from '../src/core/site-data.ts'
import type { GhRelease } from '../src/core/site-data.ts'

const rel = (tag: string, names: string[], over: Partial<GhRelease> = {}): GhRelease => ({
  tag_name: tag, html_url: `https://github.com/x/y/releases/tag/${tag}`, published_at: '2026-10-05T12:00:00Z',
  draft: false, prerelease: false,
  assets: names.map(name => ({ name, size: 10, browser_download_url: `https://github.com/dl/${name}` })), ...over,
})

test('siteReleases lists only what each release built, newest first, with mirror links when mirrored', () => {
  const out = siteReleases({
    releases: [
      rel('v2.2.0', ['Cascade-2.2.0-arm64.dmg', 'Cascade-2.2.0.exe', 'latest.yml']),
      // Apple-only release carrying the 2.2.0 desktop files over.
      rel('v2.2.1', ['Cascade-2.2.0-arm64.dmg', 'Cascade-2.2.1-iOS.ipa', 'versions.json']),
      rel('v2.2.2-b1', ['Cascade-2.2.2-b1.dmg'], { prerelease: true }),
      rel('v2.3.0', ['Cascade-2.3.0.dmg'], { draft: true }),
    ],
    versionsByTag: { 'v2.2.1': { desktop: '2.2.0', apple: '2.2.1' } },
    mirrorUrl: 'https://m.example:47443',
    mirrorVersions: { desktop: ['2.2.0'] },
  })
  assert.deepEqual(out.map(r => r.version), ['2.2.2-b1', '2.2.1', '2.2.0'])
  assert.equal(out[0].prerelease, true)
  out.shift()
  assert.deepEqual(Object.keys(out[0].platforms), ['apple'])
  assert.equal(out[0].platforms.apple![0].mirror, null)
  assert.equal(out[0].date, '2026-10-05')
  const desktop = out[1].platforms.desktop!
  assert.deepEqual(desktop.map(f => f.name), ['Cascade-2.2.0-arm64.dmg', 'Cascade-2.2.0.exe'])
  assert.equal(desktop[0].mirror, 'https://m.example:47443/desktop/2.2.0/Cascade-2.2.0-arm64.dmg')
})

test('siteReleases keeps the release notes verbatim and sorts betas below their release', () => {
  const out = siteReleases({
    releases: [
      rel('v1.2.0-b5', [], { prerelease: true, body: 'Alr, later.\n\n**Full Changelog**: x' }),
      rel('v1.1.1-b', [], { prerelease: true }),
      rel('v2.0.0', [], { body: null }),
      rel('v1.1.0', []),
    ],
    versionsByTag: {}, mirrorUrl: 'https://m', mirrorVersions: {},
  })
  assert.deepEqual(out.map(r => r.version), ['2.0.0', '1.2.0-b5', '1.1.1-b', '1.1.0'])
  assert.equal(out[1].notes, 'Alr, later.\n\n**Full Changelog**: x')
  assert.equal(out[0].notes, '')
})

test('siteReleases lists the native Mac DMG under mac and the Electron DMG under desktop, labelled', () => {
  const out = siteReleases({
    releases: [
      rel('v2.4.0', ['Cascade-2.4.0-arm64.dmg', 'Cascade.Setup.2.4.0.exe', 'Cascade-Native-2.4.0.dmg', 'versions.json']),
      // Native only: Electron's files are carried over from v2.4.0.
      rel('v2.4.1', ['Cascade-2.4.0-arm64.dmg', 'Cascade-Native-2.4.1.dmg', 'versions.json']),
    ],
    versionsByTag: { 'v2.4.0': { desktop: '2.4.0', mac: '2.4.0' }, 'v2.4.1': { desktop: '2.4.0', mac: '2.4.1' } },
    mirrorUrl: 'https://m',
    mirrorVersions: { desktop: ['2.4.0'], mac: ['2.4.0', '2.4.1'] },
  })
  const [native, both] = out
  assert.deepEqual(Object.keys(native.platforms), ['mac'])
  assert.deepEqual(native.platforms.mac, [{
    name: 'Cascade-Native-2.4.1.dmg', size: 10, url: 'https://github.com/dl/Cascade-Native-2.4.1.dmg',
    mirror: 'https://m/mac/2.4.1/Cascade-Native-2.4.1.dmg', label: 'Mac (native)',
  }])
  assert.deepEqual(both.platforms.desktop!.map(f => [f.name, f.label]), [['Cascade-2.4.0-arm64.dmg', 'Mac (Electron)'], ['Cascade.Setup.2.4.0.exe', null]])
  assert.deepEqual(both.platforms.mac!.map(f => f.name), ['Cascade-Native-2.4.0.dmg'])
})
