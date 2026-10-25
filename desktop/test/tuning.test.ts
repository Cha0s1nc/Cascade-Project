import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import {
  combineEntry,
  formatTuning,
  latestRevision,
  movedOn,
  recordRevision,
  resolve,
  revisionKeys,
  setEntry,
  simplify,
  swiftCopy,
  tidyRevision,
  type TuningFile,
} from '../src/core/tuning.ts'
import { TUNING_FILE } from '../src/core/tuning-defaults.ts'
import { LYRIC_DEFAULTS_CHANGED, LYRIC_KNOBS } from '../src/core/lyric-style.ts'
import { blobBrightness, blobLook, blobTuning, lookColor, SHIPPED_BLOB_TUNING } from '../src/core/album-colors.ts'

// The repo root: shared/tuning-defaults.json is every app's.
const ROOT = new URL('../../', import.meta.url)
// A checkout of the desktop alone has no apple/ to compare with.
const APPLE = existsSync(new URL('apple', ROOT)) ? false : 'apple/ is not in this checkout'
const text = readFileSync(new URL('shared/tuning-defaults.json', ROOT), 'utf8')

test('a value is shared, or the most specific target a platform reads wins', () => {
  assert.equal(resolve(0.3, 'tvos'), 0.3)
  const e = { all: -0.05, ios: -0.35, note: 'why' }
  assert.equal(resolve(e, 'ios'), -0.35)
  assert.equal(resolve(e, 'mac'), -0.05)
  assert.equal(resolve(e, 'desktop'), -0.05)
  const apple = { apple: 30, tvos: 44 }
  assert.equal(resolve(apple, 'mac'), 30)
  assert.equal(resolve(apple, 'tvos'), 44)
  assert.equal(resolve(apple, 'desktop'), undefined)
  // A list is a value, not a split.
  const slots = [{ x: 1 }]
  assert.equal(resolve(slots, 'ios'), slots)
})

test('setting a target splits a shared value, and folds it back once they agree', () => {
  const split = setEntry(0.3, 'ios', 0.4)
  assert.deepEqual(split.entry, { all: 0.3, ios: 0.4 })
  assert.deepEqual(setEntry(split.entry, 'ios', 0.3).entry, 0.3)
  // A note keeps the object form.
  assert.deepEqual(setEntry({ all: 1, note: 'n' }, 'all', 2).entry, { all: 2, note: 'n' })
})

test('a set without a platform leaves narrower overrides winning and says so', () => {
  const r = setEntry({ all: -0.05, ios: -0.35 }, 'all', -0.1)
  assert.deepEqual(r.entry, { all: -0.1, ios: -0.35 })
  assert.deepEqual(r.shadowedBy, ['ios'])
})

test('a bake from a platform clears the overrides between it and the target, and only those', () => {
  const e = { all: -0.05, apple: -0.1, ios: -0.35, desktop: -0.2 }
  const r = setEntry(e, 'apple', -0.15, 'ios')
  assert.deepEqual(r.entry, { all: -0.05, apple: -0.15, desktop: -0.2 })
  assert.equal(resolve(r.entry, 'ios'), -0.15)
  assert.equal(resolve(r.entry, 'desktop'), -0.2)
  assert.throws(() => setEntry(e, 'desktop', 1, 'ios'), /does not read/)
})

test('simplify drops overrides that repeat what they override', () => {
  assert.deepEqual(simplify({ all: 1, apple: 1, mac: 2 }), { all: 1, mac: 2 })
  assert.deepEqual(simplify({ all: 1, apple: 2, mac: 2 }), { all: 1, apple: 2 })
  assert.equal(simplify({ all: 1, desktop: 1 }), 1)
})

test('combine keeps the one value they share, or the named platform\'s', () => {
  assert.equal(combineEntry({ apple: 4, desktop: 4 }), 4)
  assert.throws(() => combineEntry({ apple: 4, desktop: 3 }), /--from/)
  assert.equal(combineEntry({ apple: 4, desktop: 3 }, 'desktop'), 3)
  assert.deepEqual(combineEntry({ all: 1, ios: 2, note: 'n' }, 'ios'), { all: 2, note: 'n' })
  assert.deepEqual(movedOn({ all: 1, ios: 2 }, 2), ['desktop', 'mac', 'tvos'])
})

function fileWith(revisions: TuningFile['revisions']): TuningFile {
  return { style: {}, albumColors: {}, motion: {}, revisions }
}

test('a moved default joins the open revision, or opens one after a release', () => {
  const shipped = fileWith({ 2: { all: ['a'] } })
  assert.equal(recordRevision(shipped, 'b', ['ios'], 2, '2026-10-23'), 3)
  assert.deepEqual(shipped.revisions['3'], { date: '2026-10-23', ios: ['b'] })
  // Still unreleased: the same revision, tidied under the broadest targets.
  assert.equal(recordRevision(shipped, 'b', ['desktop', 'mac', 'tvos'], 2, '2026-10-24'), 3)
  assert.equal(recordRevision(shipped, 'c', ['mac', 'ios', 'tvos'], 2, '2026-10-24'), 3)
  assert.deepEqual(shipped.revisions['3'], { date: '2026-10-23', all: ['b'], apple: ['c'] })
  assert.deepEqual(revisionKeys(shipped, 'desktop', 3), ['b'])
  assert.deepEqual(revisionKeys(shipped, 'tvos', 3).sort(), ['b', 'c'])
  assert.equal(latestRevision(shipped), 3)
})

test('tidyRevision keeps the date and note', () => {
  assert.deepEqual(tidyRevision({ date: 'd', note: 'n', desktop: ['k'], apple: ['k'] }), { date: 'd', note: 'n', all: ['k'] })
})

test('tuning-defaults.json is written the way npm run tuning writes it', () => {
  assert.equal(formatTuning(JSON.parse(text)), text)
})

test('the Apple apps\' copy is current (npm run tuning -- sync)', { skip: APPLE }, () => {
  const swift = readFileSync(new URL('apple/CascadeKit/Sources/CascadeKit/TuningDefaultsData.swift', ROOT), 'utf8')
  assert.equal(swift, swiftCopy(text))
})

test('every desktop knob has a default in the file, and the revisions name real knobs', () => {
  for (const k of LYRIC_KNOBS) {
    assert.equal(typeof resolve(TUNING_FILE.style[k.key], 'desktop'), 'number', k.key)
    assert.ok(k.value >= k.min && k.value <= k.max, `${k.key} default ${k.value} outside ${k.min}...${k.max}`)
  }
  const names = new Set(Object.keys(TUNING_FILE.style))
  for (const r of Object.keys(TUNING_FILE.revisions)) {
    for (const [t, list] of Object.entries(TUNING_FILE.revisions[r] ?? {})) {
      if (!Array.isArray(list)) continue
      for (const k of list) assert.ok(names.has(k), `revision ${r} ${t}: ${k} is not a style key`)
    }
  }
  // Revision 3 moved only the iPhone, so the desktop has nothing to ask.
  assert.deepEqual(LYRIC_DEFAULTS_CHANGED[3], [])
  assert.equal(LYRIC_DEFAULTS_CHANGED[2]?.length, 8)
})

test('every Apple Style Tuning knob has a default on each Apple platform', { skip: APPLE }, () => {
  // Read from the Swift source: StyleTuning is in the app target, which no
  // test reaches, and a missing default there only shows as an assertion.
  const swift = readFileSync(new URL('apple/App/Sources/StyleTuning.swift', ROOT), 'utf8')
  const table = swift.slice(swift.indexOf('static let knobs: [Knob] = ['), swift.indexOf('    ]', swift.indexOf('static let knobs: [Knob] = [')))
  const keys = [...table.matchAll(/key: "(\w+)"/g)].map(m => m[1] as string)
  assert.ok(keys.length > 30, `found only ${keys.length} knobs; did the table move?`)
  for (const p of ['mac', 'ios', 'tvos'] as const) {
    for (const k of keys) assert.equal(typeof resolve(TUNING_FILE.style[k], p), 'number', `${p} has no ${k}`)
  }
})

test('the album-colors tuning is the file\'s, and the look is a no-op at its defaults', () => {
  assert.deepEqual(blobTuning, SHIPPED_BLOB_TUNING)
  assert.equal(SHIPPED_BLOB_TUNING.slots.length, 3)
  const c = { r: 200, g: 40, b: 90, hue: 0 }
  assert.equal(lookColor(c), c)
  Object.assign(blobLook, { saturation: 0 })
  try {
    const grey = lookColor(c)
    assert.ok(Math.abs(grey.r - grey.g) <= 1 && Math.abs(grey.g - grey.b) <= 1)
  } finally {
    Object.assign(blobLook, { saturation: 1 })
  }
  assert.equal(blobBrightness([]), 0)
  assert.ok(blobBrightness([{ r: 255, g: 255, b: 255, hue: 0 }]) > blobBrightness([{ r: 40, g: 40, b: 40, hue: 0 }]))
})
