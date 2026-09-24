import { test } from 'node:test'
import assert from 'node:assert/strict'
import { liveTranslationEntries, translationExpired, TRANSLATION_CACHE_TTL_MS } from '../src/core/translation-cache.ts'

const now = 1_800_000_000_000
const day = 24 * 60 * 60 * 1000

test('an entry lasts 25 days from when it was translated', () => {
  assert.equal(translationExpired(now - 24 * day, now), false)
  assert.equal(translationExpired(now - TRANSLATION_CACHE_TTL_MS, now), true)
  assert.equal(translationExpired(now + day, now), true)   // from the future: clock was wrong, do not trust it
})

test('loaded entries: malformed and expired ones dropped, order kept', () => {
  const raw = [
    ['apple|ja|a', 'A', now - 30 * day],     // expired
    ['apple|ja|b', 'B', now - day],
    'junk', ['x'], ['', 'empty key', now], ['k', 5, now], ['k', 'nan', NaN],
    ['mozilla|ko|c', 'C', now],
  ]
  assert.deepEqual(liveTranslationEntries(raw, now), [['apple|ja|b', 'B', now - day], ['mozilla|ko|c', 'C', now]])
})

test('loaded entries: capped to the newest, and anything not an array is empty', () => {
  const raw = [1, 2, 3].map(i => [`k${i}`, `t${i}`, now])
  assert.deepEqual(liveTranslationEntries(raw, now, 2).map(e => e[0]), ['k2', 'k3'])
  for (const junk of [null, {}, 'x', 42]) assert.deepEqual(liveTranslationEntries(junk, now), [])
})
