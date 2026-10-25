import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  nextOfflineState, isOffline, probeDelayMs, failureKind, blocksServer, blocksWeb, checksUpdates, updateCheckDue, isOfflineState,
  type OfflineState,
} from '../src/core/offline-mode.ts'

test('the manual switch outranks what the network says', () => {
  let s: OfflineState = 'online'
  s = nextOfflineState(s, { type: 'switch', on: true })
  assert.equal(s, 'manual')
  assert.equal(nextOfflineState(s, { type: 'reachable' }), 'manual')
  assert.equal(nextOfflineState(s, { type: 'unreachable' }), 'manual')
  assert.equal(nextOfflineState(s, { type: 'switch', on: false }), 'online')
})

test('a drop turns it on by itself and an answer turns it off', () => {
  let s: OfflineState = 'online'
  s = nextOfflineState(s, { type: 'unreachable' })
  assert.equal(s, 'unreachable')
  assert.equal(nextOfflineState(s, { type: 'unreachable' }), 'unreachable')
  assert.equal(nextOfflineState(s, { type: 'reachable' }), 'online')
  assert.equal(nextOfflineState(s, { type: 'switch', on: true }), 'manual', 'the switch can be turned on while unreachable')
  assert.equal(nextOfflineState(s, { type: 'switch', on: false }), 'unreachable', 'turning off a switch that was not on changes nothing')
})

test('only online is online', () => {
  assert.equal(isOffline('online'), false)
  assert.equal(isOffline('manual'), true)
  assert.equal(isOffline('unreachable'), true)
})

test('probes back off from 30 s to five minutes', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 50].map(probeDelayMs), [30_000, 60_000, 120_000, 240_000, 300_000, 300_000, 300_000])
  assert.equal(probeDelayMs(-1), 30_000)
  assert.equal(probeDelayMs(NaN), 30_000)
})

test('an expired session is never Offline Mode', () => {
  assert.equal(failureKind(undefined), 'unreachable')
  assert.equal(failureKind(0), 'unreachable')
  for (const s of [502, 503, 504]) assert.equal(failureKind(s), 'unreachable', String(s))
  assert.equal(failureKind(401), 'auth')
  assert.equal(failureKind(403), 'auth')
  for (const s of [400, 404, 500]) assert.equal(failureKind(s), 'error', String(s))
})

test('main blocks the server only for the switch; updates wait until online', () => {
  assert.equal(blocksServer('manual'), true)
  assert.equal(blocksServer('unreachable'), false, 'the probe must get through')
  assert.equal(blocksServer('online'), false)
  assert.equal(checksUpdates('online'), true)
  assert.equal(checksUpdates('manual'), false)
  assert.equal(updateCheckDue('unreachable', 'online'), true)
  assert.equal(updateCheckDue('manual', 'online'), true)
  assert.equal(updateCheckDue('online', 'online'), false)
  assert.equal(updateCheckDue('online', 'manual'), false)
})

test('Local mode has no server to lose, but the web is there', () => {
  for (const event of [{ type: 'switch', on: true }, { type: 'switch', on: false }, { type: 'unreachable' }, { type: 'reachable' }] as const) {
    assert.equal(nextOfflineState('local', event), 'local', event.type)
  }
  assert.equal(isOffline('local'), true, 'the reads answer from the catalog and server features hide')
  assert.equal(blocksServer('local'), false, 'there is no server origin to block')
  assert.equal(blocksWeb('local'), false, 'LRCLIB, artwork and translation models still go out')
  assert.equal(blocksWeb('manual'), true)
  assert.equal(blocksWeb('unreachable'), true)
  assert.equal(blocksWeb('online'), false)
  assert.equal(checksUpdates('local'), true)
  assert.equal(updateCheckDue('online', 'local'), false, 'already checking')
  assert.equal(updateCheckDue('manual', 'local'), true)
  assert.equal(updateCheckDue('local', 'online'), false)
})

test('only the four states cross IPC', () => {
  for (const s of ['online', 'manual', 'unreachable', 'local']) assert.equal(isOfflineState(s), true, s)
  for (const s of ['Local', '', null, undefined, 1, {}]) assert.equal(isOfflineState(s), false, String(s))
})
