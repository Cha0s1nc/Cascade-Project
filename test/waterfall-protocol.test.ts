import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  buildStateMessage, expectedPositionMs, shouldReseek, isForeignServer, roomSocketUrl,
  WF_DRIFT_MS,
} from '../src/core/waterfall-protocol.ts'

test('buildStateMessage stamps the send time', () => {
  const msg = buildStateMessage({
    serverId: 'S1', trackId: 'T1', positionMs: 5000, paused: false, now: 1_000_000,
  })
  assert.deepEqual(msg, {
    k: 'state', serverId: 'S1', trackId: 'T1', positionMs: 5000, paused: false, sentAt: 1_000_000,
  })
})

test('expectedPositionMs ages a playing position by time in transit', () => {
  const msg = buildStateMessage({
    serverId: 'S1', trackId: 'T1', positionMs: 10_000, paused: false, now: 1_000_000,
  })
  // 300ms later the host has moved on by 300ms.
  assert.equal(expectedPositionMs(msg, 1_000_300), 10_300)
})

test('expectedPositionMs does not age a paused position', () => {
  const msg = buildStateMessage({
    serverId: 'S1', trackId: 'T1', positionMs: 10_000, paused: true, now: 1_000_000,
  })
  assert.equal(expectedPositionMs(msg, 1_005_000), 10_000, 'paused means frozen')
})

test('expectedPositionMs ignores a clock running backwards', () => {
  const msg = buildStateMessage({
    serverId: 'S1', trackId: 'T1', positionMs: 10_000, paused: false, now: 1_000_000,
  })
  // Negative latency would rewind the guest; clamped to zero instead.
  assert.equal(expectedPositionMs(msg, 999_000), 10_000)
})

test('shouldReseek only fires past the drift threshold', () => {
  assert.equal(shouldReseek(10_000, 10_000 + WF_DRIFT_MS - 1), false)
  assert.equal(shouldReseek(10_000, 10_000 + WF_DRIFT_MS + 1), true)
  // Symmetric: being ahead counts too.
  assert.equal(shouldReseek(10_000, 10_000 - WF_DRIFT_MS - 1), true)
})

test('isForeignServer refuses a different server but tolerates unknowns', () => {
  assert.equal(isForeignServer('A', 'B'), true)
  assert.equal(isForeignServer('A', 'A'), false)
  // An older client that sends no id must not be locked out.
  assert.equal(isForeignServer(null, 'A'), false)
  assert.equal(isForeignServer('A', null), false)
  assert.equal(isForeignServer(undefined, undefined), false)
})

test('roomSocketUrl upgrades the scheme and encodes the name', () => {
  assert.equal(
    roomSocketUrl('https://relay.test', 'ABC123', 'Jon'),
    'wss://relay.test/room/ABC123?name=Jon',
  )
  assert.equal(
    roomSocketUrl('http://relay.test', 'ABC123', 'a b&c'),
    'ws://relay.test/room/ABC123?name=a%20b%26c',
  )
})

test('roomSocketUrl tolerates a trailing slash on the relay base', () => {
  assert.equal(
    roomSocketUrl('https://relay.test/', 'ABC123', 'Jon'),
    'wss://relay.test/room/ABC123?name=Jon',
  )
})
