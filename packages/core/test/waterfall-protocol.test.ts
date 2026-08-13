import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  buildStateMessage, expectedPositionMs, shouldReseek, isForeignServer, roomSocketUrl,
  buildQueueMessage, buildEnqueueMessage, buildEnqueueRejected,
  buildControlMessage, isControlAction,
  isStaleQueue, missingTrackIds,
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

test('buildQueueMessage pads attribution to match the track list', () => {
  // A misaligned parallel array would attach names to the wrong rows.
  const msg = buildQueueMessage({
    serverId: 'S1', rev: 3, trackIds: ['a', 'b', 'c'],
    addedBy: ['Jon'], index: 0, guestAddsAllowed: true, guestControlAllowed: false,
  })
  assert.deepEqual(msg.addedBy, ['Jon', null, null])
})

test('buildQueueMessage trims over-long attribution', () => {
  const msg = buildQueueMessage({
    serverId: 'S1', rev: 1, trackIds: ['a'],
    addedBy: ['Jon', 'Sam', 'Alex'], index: 0, guestAddsAllowed: true, guestControlAllowed: false,
  })
  assert.deepEqual(msg.addedBy, ['Jon'])
})

test('buildQueueMessage copies its inputs', () => {
  // The host keeps mutating its live queue; the message must not alias it.
  const ids = ['a', 'b']
  const msg = buildQueueMessage({
    serverId: null, rev: 1, trackIds: ids, index: 0, guestAddsAllowed: false, guestControlAllowed: true,
  })
  ids.push('c')
  assert.deepEqual(msg.trackIds, ['a', 'b'])
  assert.equal(msg.guestAddsAllowed, false)
})

test('isStaleQueue drops older and duplicate revisions', () => {
  assert.equal(isStaleQueue(5, 4), false, 'newer applies')
  assert.equal(isStaleQueue(4, 4), true, 'same revision is a duplicate')
  assert.equal(isStaleQueue(3, 4), true, 'older must not clobber newer')
})

test('missingTrackIds returns only unknown ids, once each', () => {
  const missing = missingTrackIds(['a', 'b', 'c', 'b', 'd'], ['a', 'c'])
  assert.deepEqual(missing, ['b', 'd'], 'deduped, order preserved')
})

test('missingTrackIds with nothing known asks for everything', () => {
  assert.deepEqual(missingTrackIds(['a', 'b'], []), ['a', 'b'])
})

test('buildEnqueueMessage is append-only and copies its ids', () => {
  const ids = ['x']
  const msg = buildEnqueueMessage({ serverId: 'S1', trackIds: ids })
  ids.push('y')
  assert.deepEqual(msg, { k: 'enqueue', serverId: 'S1', trackIds: ['x'] })
})

test('buildEnqueueRejected carries a reason rather than dropping silently', () => {
  assert.deepEqual(buildEnqueueRejected('Host cannot access that track'),
    { k: 'enqueue-rejected', reason: 'Host cannot access that track' })
})

test('buildQueueMessage carries both guest permissions independently', () => {
  const msg = buildQueueMessage({
    serverId: 'S1', rev: 1, trackIds: ['a'], index: 0,
    guestAddsAllowed: true, guestControlAllowed: false,
  })
  assert.equal(msg.guestAddsAllowed, true)
  assert.equal(msg.guestControlAllowed, false, 'adding and controlling are separate rights')
})

test('buildControlMessage only carries a position for seek', () => {
  assert.deepEqual(buildControlMessage('playpause'), { k: 'control', action: 'playpause' })
  assert.deepEqual(buildControlMessage('next'), { k: 'control', action: 'next' })
  // A stray positionMs on a non-seek action would be meaningless.
  assert.deepEqual(buildControlMessage('prev', 5000), { k: 'control', action: 'prev' })
  assert.deepEqual(buildControlMessage('seek', 5000), { k: 'control', action: 'seek', positionMs: 5000 })
})

test('buildControlMessage normalises the seek position', () => {
  assert.equal(buildControlMessage('seek', -50).positionMs, 0, 'never negative')
  assert.equal(buildControlMessage('seek', 1234.7).positionMs, 1235, 'rounded')
  // Without a usable number the field is omitted rather than sent as NaN.
  assert.equal('positionMs' in buildControlMessage('seek', NaN), false)
  assert.equal('positionMs' in buildControlMessage('seek'), false)
})

test('isControlAction rejects anything unrecognised', () => {
  // Control messages arrive from another client, so this is a trust boundary.
  for (const ok of ['playpause', 'next', 'prev', 'seek']) assert.equal(isControlAction(ok), true)
  for (const bad of ['stop', 'eval', '', 'PLAYPAUSE', null, undefined, 7, {}, ['next']]) {
    assert.equal(isControlAction(bad), false, `${String(bad)} must be refused`)
  }
})

test('roomSocketUrl tolerates a trailing slash on the relay base', () => {
  assert.equal(
    roomSocketUrl('https://relay.test/', 'ABC123', 'Jon'),
    'wss://relay.test/room/ABC123?name=Jon',
  )
})
