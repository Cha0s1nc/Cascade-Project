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
  assert.deepEqual(out.map(r => r.version), ['2.2.1', '2.2.0'])
  assert.deepEqual(Object.keys(out[0].platforms), ['apple'])
  assert.equal(out[0].platforms.apple![0].mirror, null)
  assert.equal(out[0].date, '2026-10-05')
  const desktop = out[1].platforms.desktop!
  assert.deepEqual(desktop.map(f => f.name), ['Cascade-2.2.0-arm64.dmg', 'Cascade-2.2.0.exe'])
  assert.equal(desktop[0].mirror, 'https://m.example:47443/desktop/2.2.0/Cascade-2.2.0-arm64.dmg')
})
