import { test, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { JellyfinClient } from '../src/core/jellyfin.ts'
import {
  buildPlaybackReport, reportStart, reportProgress, reportStopped, PROGRESS_INTERVAL_MS,
} from '../src/core/playback-reporting.ts'
import type { PlaybackState } from '../src/core/playback-reporting.ts'
import type { ServerConfig } from '../src/core/types.ts'

const realFetch = globalThis.fetch
let calls: { url: string, body: any }[] = []

function stubFetch(ok = true) {
  globalThis.fetch = (async (input: any, init?: RequestInit) => {
    calls.push({ url: String(input), body: init?.body ? JSON.parse(String(init.body)) : undefined })
    return ok
      ? { ok: true, status: 204, statusText: 'No Content', json: async () => ({}), text: async () => '' }
      : { ok: false, status: 500, statusText: 'Server Error', json: async () => ({}), text: async () => '' }
  }) as typeof fetch
}

beforeEach(() => { calls = [] })
afterEach(() => { globalThis.fetch = realFetch })

const config: ServerConfig = { url: 'https://jf.test', token: 'TOK', userId: 'U1' }
const client = new JellyfinClient(() => config)

const state = (over: Partial<PlaybackState> = {}): PlaybackState => ({
  itemId: 'ITEM1',
  positionTicks: 50_000_000,
  isPaused: false,
  isMuted: false,
  volumeLevel: 80,
  playSessionId: 'PS1',
  mediaSourceId: 'MS1',
  playMethod: 'DirectPlay',
  ...over,
})

test('report carries the fields a controller binds its transport to', () => {
  // VolumeLevel and IsMuted were absent before, which is why remote volume
  // appeared to do nothing - the controller had no state to render.
  const r = buildPlaybackReport(state())
  assert.equal(r.ItemId, 'ITEM1')
  assert.equal(r.PositionTicks, 50_000_000)
  assert.equal(r.IsPaused, false)
  assert.equal(r.IsMuted, false)
  assert.equal(r.VolumeLevel, 80)
  assert.equal(r.CanSeek, true)
  assert.equal(r.PlayMethod, 'DirectPlay')
  assert.equal(r.PlaySessionId, 'PS1')
  assert.equal(r.MediaSourceId, 'MS1')
})

test('pause state is reported, not assumed', () => {
  assert.equal(buildPlaybackReport(state({ isPaused: true })).IsPaused, true)
  assert.equal(buildPlaybackReport(state({ isMuted: true })).IsMuted, true)
})

test('volume is clamped to Jellyfin 0-100 and rounded', () => {
  assert.equal(buildPlaybackReport(state({ volumeLevel: 33.4 })).VolumeLevel, 33)
  assert.equal(buildPlaybackReport(state({ volumeLevel: 250 })).VolumeLevel, 100)
  assert.equal(buildPlaybackReport(state({ volumeLevel: -10 })).VolumeLevel, 0)
  assert.equal(buildPlaybackReport(state({ volumeLevel: NaN })).VolumeLevel, 100)
})

test('negative or fractional positions are normalised', () => {
  assert.equal(buildPlaybackReport(state({ positionTicks: -5 })).PositionTicks, 0)
  assert.equal(buildPlaybackReport(state({ positionTicks: 1.6 })).PositionTicks, 2)
})

test('optional ids are omitted rather than sent as null', () => {
  const r = buildPlaybackReport(state({ playSessionId: null, mediaSourceId: null }))
  assert.equal('PlaySessionId' in r, false)
  assert.equal('MediaSourceId' in r, false)
})

test('each report hits its own endpoint', async () => {
  stubFetch()
  await reportStart(client, state())
  await reportProgress(client, state())
  await reportStopped(client, state())

  assert.deepEqual(calls.map(c => new URL(c.url).pathname), [
    '/Sessions/Playing',
    '/Sessions/Playing/Progress',
    '/Sessions/Playing/Stopped',
  ])
})

test('progress tags the event so pause is distinguishable', async () => {
  stubFetch()
  await reportProgress(client, state({ isPaused: true }))
  assert.equal(calls[0].body.EventName, 'Pause')
  calls = []
  await reportProgress(client, state({ isPaused: false }))
  assert.equal(calls[0].body.EventName, 'TimeUpdate')
})

test('stopped carries the final position for watch history', async () => {
  stubFetch()
  await reportStopped(client, state({ positionTicks: 123_456_789 }))
  assert.equal(calls[0].body.PositionTicks, 123_456_789)
  assert.equal(calls[0].body.PlaySessionId, 'PS1')
})

test('a failed report never throws', async () => {
  // These fire on a timer; a rejection would be unhandled noise, and a dropped
  // check-in must not interrupt playback.
  stubFetch(false)
  await assert.doesNotReject(() => reportStart(client, state()))
  await assert.doesNotReject(() => reportProgress(client, state()))
  await assert.doesNotReject(() => reportStopped(client, state()))

  globalThis.fetch = (() => Promise.reject(new Error('offline'))) as unknown as typeof fetch
  await assert.doesNotReject(() => reportProgress(client, state()))
})

test('progress interval is frequent enough to look live', () => {
  assert.ok(PROGRESS_INTERVAL_MS <= 10_000)
})
