// The updater's asset picker, against the asset list a unified release actually
// produces - desktop and mobile binaries side by side on one card.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { pickReleaseAsset } from '../src/core/release-assets.ts'

/** What `v1.3.0` looks like once every platform has uploaded. */
const UNIFIED = [
  { name: 'Cascade-1.3.0.dmg' },
  { name: 'Cascade-1.3.0-arm64.dmg' },
  { name: 'Cascade-Setup-1.3.0.exe' },
  { name: 'Cascade-1.3.0.AppImage' },
  { name: 'cascade_1.3.0_amd64.deb' },
  { name: 'cascade-1.3.0.x86_64.rpm' },
  { name: 'cascade-tv-1.3.0.apk' },
  { name: 'cascade-mobile-1.3.0.apk' },
  { name: 'cascade-mobile-1.3.0.aab' },
  { name: 'Cascade-1.3.0.ipa' },
].map(a => ({ ...a, browser_download_url: `https://example.test/${a.name}` }))

const pick = (t: Parameters<typeof pickReleaseAsset>[1]) => pickReleaseAsset(UNIFIED, t)?.name

test('each desktop platform gets its own installer, never a mobile one', () => {
  assert.equal(pick({ platform: 'win32' }), 'Cascade-Setup-1.3.0.exe')
  assert.equal(pick({ platform: 'darwin', arch: 'arm64' }), 'Cascade-1.3.0-arm64.dmg')
  assert.equal(pick({ platform: 'darwin', arch: 'x64' }), 'Cascade-1.3.0.dmg')
  assert.equal(pick({ platform: 'linux', linuxKind: 'AppImage' }), 'Cascade-1.3.0.AppImage')
  assert.equal(pick({ platform: 'linux', linuxKind: 'deb' }), 'cascade_1.3.0_amd64.deb')
  assert.equal(pick({ platform: 'linux', linuxKind: 'rpm' }), 'cascade-1.3.0.x86_64.rpm')
})

test('no desktop platform can be handed an apk, aab or ipa', () => {
  // The whole point of the unified release: mobile artefacts share the card.
  const mobile = /\.(apk|aab|ipa)$/i
  for (const target of [
    { platform: 'win32' },
    { platform: 'darwin', arch: 'arm64' },
    { platform: 'darwin', arch: 'x64' },
    { platform: 'linux', linuxKind: 'AppImage' as const },
    { platform: 'linux', linuxKind: 'deb' as const },
    { platform: 'linux', linuxKind: 'rpm' as const },
  ]) {
    const got = pick(target)
    assert.ok(got, `expected an asset for ${JSON.stringify(target)}`)
    assert.ok(!mobile.test(got!), `${JSON.stringify(target)} was offered ${got}`)
  }
})

test('an Intel Mac is never handed the arm64 build', () => {
  // Regression: matching on arch alone did exactly this.
  assert.equal(pick({ platform: 'darwin', arch: 'x64' }), 'Cascade-1.3.0.dmg')
  assert.equal(pickReleaseAsset([{ name: 'Cascade-1.3.0-arm64.dmg' }], { platform: 'darwin', arch: 'x64' }), undefined)
})

test('a mobile-only release offers nothing rather than something wrong', () => {
  const mobileOnly = [{ name: 'cascade-mobile-1.3.1.apk' }, { name: 'Cascade-1.3.1.ipa' }]
  for (const target of [
    { platform: 'win32' },
    { platform: 'darwin', arch: 'arm64' },
    { platform: 'linux', linuxKind: 'deb' as const },
  ]) {
    assert.equal(pickReleaseAsset(mobileOnly, target), undefined)
  }
})

test('an unknown linux packaging declines rather than guessing', () => {
  assert.equal(pick({ platform: 'linux', linuxKind: null }), undefined)
})
