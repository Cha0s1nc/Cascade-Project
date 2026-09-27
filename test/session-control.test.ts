import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  filterControllableSessions, secondsToTicks, clampVolumePercent,
  buildPlayOnDeviceParams, buildSetVolumeCommand, interpolatedPositionTicks,
} from '../src/core/session-control.ts'
import type { RemoteSession } from '../src/core/session-control.ts'

const session = (over: Partial<RemoteSession> = {}): RemoteSession => ({
  Id: 's1', DeviceId: 'other-device', SupportsRemoteControl: true, ...over,
})

test('filterControllableSessions drops our own device', () => {
  const sessions = [session({ Id: 'a', DeviceId: 'me' }), session({ Id: 'b', DeviceId: 'other' })]
  const kept = filterControllableSessions(sessions, 'me')
  assert.deepEqual(kept.map(s => s.Id), ['b'])
})

test('filterControllableSessions drops sessions that cannot be remote controlled', () => {
  const sessions = [session({ Id: 'a', SupportsRemoteControl: false }), session({ Id: 'b' })]
  const kept = filterControllableSessions(sessions, 'me')
  assert.deepEqual(kept.map(s => s.Id), ['b'])
})

test('filterControllableSessions treats a null DeviceId as not-us', () => {
  const sessions = [session({ Id: 'a', DeviceId: null })]
  const kept = filterControllableSessions(sessions, 'me')
  assert.deepEqual(kept.map(s => s.Id), ['a'])
})

test('secondsToTicks converts and floors garbage to zero', () => {
  assert.equal(secondsToTicks(1), 10_000_000)
  assert.equal(secondsToTicks(0.5), 5_000_000)
  assert.equal(secondsToTicks(NaN), 0)
  assert.equal(secondsToTicks(-5), 0)
  assert.equal(secondsToTicks(Infinity), 0)
})

test('clampVolumePercent keeps a corrupted value off the wire as NaN', () => {
  assert.equal(clampVolumePercent(50), 50)
  assert.equal(clampVolumePercent(-10), 0)
  assert.equal(clampVolumePercent(150), 100)
  assert.equal(clampVolumePercent(NaN), 0)
  assert.equal(clampVolumePercent(undefined as unknown as number), 0)
})

test('buildPlayOnDeviceParams refuses an empty item list', () => {
  assert.equal(buildPlayOnDeviceParams([]), null)
  assert.equal(buildPlayOnDeviceParams(['', ''] as string[]), null)
})

test('buildPlayOnDeviceParams builds the play-now default', () => {
  const params = buildPlayOnDeviceParams(['a', 'b'])
  assert.deepEqual(params, { playCommand: 'PlayNow', itemIds: ['a', 'b'], startIndex: 0 })
})

test('buildPlayOnDeviceParams carries a start index and explicit command', () => {
  const params = buildPlayOnDeviceParams(['a', 'b', 'c'], 'PlayNext', 2)
  assert.deepEqual(params, { playCommand: 'PlayNext', itemIds: ['a', 'b', 'c'], startIndex: 2 })
})

test('buildSetVolumeCommand carries the volume as a string, clamped', () => {
  assert.deepEqual(buildSetVolumeCommand(40), { Name: 'SetVolume', Arguments: { Volume: '40' } })
  assert.deepEqual(buildSetVolumeCommand(NaN), { Name: 'SetVolume', Arguments: { Volume: '0' } })
})

test('interpolatedPositionTicks holds still while paused', () => {
  const ticks = interpolatedPositionTicks({ PositionTicks: 1000, IsPaused: true }, 0, 5000)
  assert.equal(ticks, 1000)
})

test('interpolatedPositionTicks projects forward while playing', () => {
  const ticks = interpolatedPositionTicks({ PositionTicks: 0, IsPaused: false }, 0, 2000)
  assert.equal(ticks, 20_000_000) // 2s at 10_000_000 ticks/sec
})

test('interpolatedPositionTicks is 0 for a session with no play state', () => {
  assert.equal(interpolatedPositionTicks(null, 0, 5000), 0)
  assert.equal(interpolatedPositionTicks({}, 0, 5000), 0)
})
