import { test } from 'node:test'
import assert from 'node:assert/strict'
import { playbackOwner, blocksLocalPlayback, acceptsRemoteCommand } from '../src/core/ownership.ts'
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
