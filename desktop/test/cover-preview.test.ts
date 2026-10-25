import { test } from 'node:test'
import assert from 'node:assert/strict'
import { coverPreviewPlan, PREVIEW_FALLBACK_SECONDS } from '../src/core/cover-preview.ts'

const base = { hasNext: true, nextIsVideo: false, sameCover: false, coverSlice: true, reduceMotion: false, crossfadeOn: true, crossfadeSeconds: 8 }

test('runs for the real crossfade length with nothing to say', () => {
  assert.deepEqual(coverPreviewPlan(base), { run: true, seconds: 8, notes: [] })
})

test('crossfade off previews the fallback length and says so', () => {
  const p = coverPreviewPlan({ ...base, crossfadeOn: false })
  assert.equal(p.run, true)
  assert.equal(p.seconds, PREVIEW_FALLBACK_SECONDS)
  assert.deepEqual(p.notes, ['Previewing a 6s crossfade.'])
  // A junk stored length is treated the same way, never as NaN seconds.
  assert.equal(coverPreviewPlan({ ...base, crossfadeSeconds: NaN }).seconds, PREVIEW_FALLBACK_SECONDS)
})

test('a shared cover still runs, with a note', () => {
  const p = coverPreviewPlan({ ...base, sameCover: true, crossfadeOn: false })
  assert.equal(p.run, true)
  assert.equal(p.notes.length, 2)
  assert.match(p.notes[0], /share a cover/)
})

test('each reason not to run is a plain hint, in priority order', () => {
  assert.deepEqual(coverPreviewPlan({ ...base, reduceMotion: true, coverSlice: false, hasNext: false }).notes, ['Cover transitions are off while Reduce Motion is on.'])
  assert.deepEqual(coverPreviewPlan({ ...base, coverSlice: false, hasNext: false }).notes, ['Cover transitions are off.'])
  assert.deepEqual(coverPreviewPlan({ ...base, hasNext: false }).notes, ['Queue another song to preview the transition.'])
  const video = coverPreviewPlan({ ...base, nextIsVideo: true })
  assert.equal(video.run, false)
  assert.match(video.notes[0], /video/)
})
