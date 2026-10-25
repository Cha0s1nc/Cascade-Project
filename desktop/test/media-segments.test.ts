import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  parseMediaSegments, activeSegment, skipLabel, skipAction, segmentKey,
  type MediaSegment,
} from '../src/core/media-segments.ts'

const T = 10_000_000
const seg = (type: MediaSegment['type'], startSec: number, endSec: number): MediaSegment => ({ type, startSec, endSec })

test('parseMediaSegments: reads a response and converts ticks to seconds', () => {
  const out = parseMediaSegments({
    Items: [
      { Id: 'b', ItemId: 'x', Type: 'Outro', StartTicks: 1200 * T, EndTicks: 1300 * T },
      { Id: 'a', ItemId: 'x', Type: 'Intro', StartTicks: 30 * T, EndTicks: 90 * T },
    ],
    TotalRecordCount: 2, StartIndex: 0,
  })
  assert.deepEqual(out, [seg('Intro', 30, 90), seg('Outro', 1200, 1300)], 'sorted by start')
})

test('parseMediaSegments: an empty, missing or non-object response is no segments', () => {
  assert.deepEqual(parseMediaSegments({ Items: [] }), [])
  assert.deepEqual(parseMediaSegments({}), [])
  assert.deepEqual(parseMediaSegments(null), [])
  assert.deepEqual(parseMediaSegments(undefined), [])
  assert.deepEqual(parseMediaSegments('nope'), [])
  assert.deepEqual(parseMediaSegments({ Items: 'x' }), [])
})

test('parseMediaSegments: drops unknown types and malformed ranges', () => {
  const out = parseMediaSegments({ Items: [
    { Type: 'Unknown', StartTicks: 0, EndTicks: 5 * T },
    { Type: 'Bogus', StartTicks: 0, EndTicks: 5 * T },
    { Type: 'Intro', StartTicks: -1, EndTicks: 5 * T },
    { Type: 'Intro', StartTicks: 5 * T, EndTicks: 5 * T },
    { Type: 'Intro', StartTicks: 9 * T, EndTicks: 5 * T },
    { Type: 'Intro', StartTicks: NaN, EndTicks: 5 * T },
    { Type: 'Intro', StartTicks: '0', EndTicks: 5 * T },
    { Type: 'Intro', StartTicks: 0, EndTicks: Infinity },
    null,
    { Type: 'Recap', StartTicks: 0, EndTicks: 5 * T },
  ] })
  assert.deepEqual(out, [seg('Recap', 0, 5)])
})

test('activeSegment: start is inside, end is outside', () => {
  const list = [seg('Intro', 30, 90)]
  assert.equal(activeSegment(list, 29.999), null)
  assert.equal(activeSegment(list, 30)?.type, 'Intro')
  assert.equal(activeSegment(list, 89.999)?.type, 'Intro')
  assert.equal(activeSegment(list, 90), null)
})

test('activeSegment: empty list, junk position', () => {
  assert.equal(activeSegment([], 10), null)
  assert.equal(activeSegment([seg('Intro', 0, 10)], NaN), null)
  assert.equal(activeSegment([seg('Intro', 0, 10)], Infinity), null)
})

test('activeSegment: only intros and outros are offered', () => {
  const list = [seg('Recap', 0, 60), seg('Preview', 100, 120), seg('Commercial', 200, 260)]
  for (const t of [10, 110, 220]) assert.equal(activeSegment(list, t), null)
})

test('activeSegment: overlapping segments, the one that ends last wins', () => {
  const list = [seg('Intro', 30, 80), seg('Intro', 40, 100), seg('Recap', 0, 500)]
  assert.equal(activeSegment(list, 50)?.endSec, 100)
  assert.equal(activeSegment(list, 35)?.endSec, 80, 'only the first has started')
})

test('activeSegment: a gap between two segments is null', () => {
  const list = [seg('Intro', 0, 10), seg('Outro', 20, 30)]
  assert.equal(activeSegment(list, 15), null)
  assert.equal(activeSegment(list, 25)?.type, 'Outro')
})

test('skipLabel names the segment', () => {
  assert.equal(skipLabel(seg('Intro', 0, 1)), 'Skip Intro')
  assert.equal(skipLabel(seg('Outro', 0, 1)), 'Skip Credits')
})

test('skipAction: seeks to the end of an intro', () => {
  assert.deepEqual(skipAction(seg('Intro', 30, 90), 2600), { kind: 'seek', sec: 90 })
})

test('skipAction: an outro that ends mid-item seeks, one that runs to the end goes on', () => {
  assert.deepEqual(skipAction(seg('Outro', 2400, 2500), 2600), { kind: 'seek', sec: 2500 })
  assert.deepEqual(skipAction(seg('Outro', 2400, 2600), 2600), { kind: 'next' })
  assert.deepEqual(skipAction(seg('Outro', 2400, 2599.5), 2600), { kind: 'next' }, 'within a second of the end')
  assert.deepEqual(skipAction(seg('Outro', 2400, 2700), 2600), { kind: 'next' }, 'past the end')
})

test('skipAction: an unknown duration never counts as the end', () => {
  assert.deepEqual(skipAction(seg('Outro', 2400, 2600), 0), { kind: 'seek', sec: 2600 })
  assert.deepEqual(skipAction(seg('Intro', 0, 90), 90), { kind: 'seek', sec: 90 }, 'an intro never means next')
})

test('segmentKey is stable and distinguishes segments', () => {
  assert.equal(segmentKey('x', seg('Intro', 30, 90)), segmentKey('x', seg('Intro', 30, 95)))
  assert.notEqual(segmentKey('x', seg('Intro', 30, 90)), segmentKey('y', seg('Intro', 30, 90)))
  assert.notEqual(segmentKey('x', seg('Intro', 30, 90)), segmentKey('x', seg('Outro', 30, 90)))
})
