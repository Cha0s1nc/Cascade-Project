import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  nextOfflineState, isOffline, probeDelayMs, failureKind, blocksServer, checksUpdates, updateCheckDue, type OfflineState,
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
