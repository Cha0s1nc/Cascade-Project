import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { ELECTRON_EDITION, desktopDeviceName } from '../src/core/jellyfin.ts'
import { TELEMETRY_URL, TELEMETRY_INTERVAL_MS, TELEMETRY_MAX_SONGS, telemetryAvailable, telemetryDue, telemetryPing } from '../src/core/telemetry.ts'

// The Worker is its own folder at the repo root, absent from a checkout of
// the desktop alone.
const WORKER = new URL('../../telemetry/src/index.js', import.meta.url)
const workerSkip = existsSync(WORKER) ? false : 'telemetry/ is not in this checkout'

test('telemetry ships dormant', () => {
  // Switching it on is a deliberate step with a checklist (src/core/telemetry.ts),
  // not something a stray edit should do.
  assert.equal(TELEMETRY_URL, '')
  assert.equal(telemetryAvailable(), false)
  assert.equal(telemetryAvailable('https://example.workers.dev/ping'), true)
})

test('telemetryDue sends on the first run and then once a day', () => {
  const now = 1_800_000_000_000
  assert.equal(telemetryDue(undefined, now), true)
  assert.equal(telemetryDue('garbage', now), true)
  assert.equal(telemetryDue(0, now), true)
  assert.equal(telemetryDue(now - 1000, now), false)
  assert.equal(telemetryDue(now - TELEMETRY_INTERVAL_MS, now), true)
})

test('telemetryPing clamps an untrusted song count', () => {
  const ping = (songs: unknown) => telemetryPing('id', '2.3.0', 'Cascade Electron', 'Mac', songs).songs
  assert.equal(ping(12), 12)
  assert.equal(ping('7'), 7)
  assert.equal(ping(undefined), 0)
  assert.equal(ping(-3), 0)
  assert.equal(ping(2.9), 2)
  assert.equal(ping(1e9), TELEMETRY_MAX_SONGS)
})

test('the Worker rejects anything but a well-formed ping', { skip: workerSkip }, async () => {
  // @ts-ignore: plain JS Worker source, no types
  const { parsePing } = await import(WORKER.href)
  const good = { installId: '3F2504E0-4F89-41D3-9A0C-0305E82C3301', version: '2.3.0-b2', edition: 'Cascade Electron', device: 'Mac', songs: 4 }
  const ok = parsePing(JSON.stringify(good))
  assert.equal(ok.installId, '3f2504e0-4f89-41d3-9a0c-0305e82c3301')
  const bad = (patch: object) => parsePing(JSON.stringify({ ...good, ...patch }))
  assert.equal(bad({ installId: 'not-a-uuid' }), null)
  assert.equal(bad({ version: '<script>' }), null)
  assert.equal(bad({ edition: 'Someone Else' }), null)
  assert.equal(bad({ device: 'Toaster' }), null)
  assert.equal(bad({ songs: -1 }), null)
  assert.equal(bad({ songs: 1.5 }), null)
  assert.equal(bad({ songs: TELEMETRY_MAX_SONGS + 1 }), null)
  assert.equal(parsePing('{'), null)
  assert.equal(parsePing('x'.repeat(2000)), null)
})

test('the Worker accepts what the desktop app really sends', { skip: workerSkip }, async () => {
  // A ping the Worker refuses never resets the count, so a drifted allowlist
  // would retry on every song start forever.
  // @ts-ignore: plain JS Worker source, no types
  const { parsePing } = await import(WORKER.href)
  for (const platform of ['win32', 'darwin', 'linux', 'freebsd']) {
    for (const version of ['2.3.0', '2.4.0-b2']) {
      const ping = telemetryPing(crypto.randomUUID(), version, ELECTRON_EDITION, desktopDeviceName(platform), 3)
      assert.notEqual(parsePing(JSON.stringify(ping)), null, `${platform} ${version}`)
    }
  }
})
