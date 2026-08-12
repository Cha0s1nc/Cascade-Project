import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  playbackOwner, blocksLocalPlayback, acceptsRemoteCommand, queueAdditionMode,
} from '../src/core/ownership.ts'
import type { OwnershipState } from '../src/core/ownership.ts'

const state = (over: Partial<OwnershipState> = {}): OwnershipState => ({
  waterfallActive: false,
  waterfallIsHost: false,
  waterfallApplying: false,
  ...over,
})

test('nobody in a room: the local user owns playback', () => {
  const s = state()
  assert.equal(playbackOwner(s), 'local')
  assert.equal(blocksLocalPlayback(s), false)
  assert.equal(acceptsRemoteCommand(s), true)
})

test('waterfall guest: local controls are inert', () => {
  const s = state({ waterfallActive: true, waterfallIsHost: false })
  assert.equal(playbackOwner(s), 'waterfall')
  assert.equal(blocksLocalPlayback(s), true)
})

test('waterfall host: own controls stay live, they drive the room', () => {
  const s = state({ waterfallActive: true, waterfallIsHost: true })
  assert.equal(blocksLocalPlayback(s), false)
})

test('guest applying host state is not blocked', () => {
  // The escape hatch: this playback IS the host's command, so blocking it would
  // deadlock the guest and it would never follow anything.
  const s = state({ waterfallActive: true, waterfallIsHost: false, waterfallApplying: true })
  assert.equal(blocksLocalPlayback(s), false)
})

test('cast is refused in a waterfall room, host or guest', () => {
  // Refused outright, not queued - a command that silently applies after the
  // room ends is worse than one that visibly does nothing now.
  assert.equal(acceptsRemoteCommand(state({ waterfallActive: true, waterfallIsHost: true })), false)
  assert.equal(acceptsRemoteCommand(state({ waterfallActive: true, waterfallIsHost: false })), false)
})

test('waterfall outranks cast', () => {
  assert.equal(playbackOwner(state({ waterfallActive: true })), 'waterfall')
})

test('queue additions: solo and host mutate directly', () => {
  assert.equal(queueAdditionMode(state()), 'local')
  assert.equal(queueAdditionMode(state({ waterfallActive: true, waterfallIsHost: true })), 'local')
})

test('queue additions: a host is never restricted by its own toggle', () => {
  const s = state({ waterfallActive: true, waterfallIsHost: true, guestAddsAllowed: false })
  assert.equal(queueAdditionMode(s), 'local')
})

test('queue additions: a guest proposes rather than mutating', () => {
  // A guest's local mutation would be wiped by the next host broadcast, which is
  // exactly the bug this replaces.
  const s = state({ waterfallActive: true, waterfallIsHost: false, guestAddsAllowed: true })
  assert.equal(queueAdditionMode(s), 'propose')
})

test('queue additions: guest is blocked when the host turns additions off', () => {
  const s = state({ waterfallActive: true, waterfallIsHost: false, guestAddsAllowed: false })
  assert.equal(queueAdditionMode(s), 'blocked')
})

test('queue additions: unknown toggle state defaults to allowed', () => {
  // Before the first queue broadcast arrives a guest has not heard the setting;
  // failing open matches the default and avoids a dead menu item on join.
  const s = state({ waterfallActive: true, waterfallIsHost: false })
  assert.equal(queueAdditionMode(s), 'propose')
})

test('queue additions stay independent of playback blocking', () => {
  // A guest can propose an addition while still being unable to start playback.
  const s = state({ waterfallActive: true, waterfallIsHost: false, guestAddsAllowed: true })
  assert.equal(blocksLocalPlayback(s), true)
  assert.equal(queueAdditionMode(s), 'propose')
})
