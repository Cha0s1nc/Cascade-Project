// The only automated check on the extracted core. These are pure functions, so
// they need no fixtures or framework - `npm test` runs them via node --test.
//
// Point of this file: catch a bad extraction. If parseLRC/parseKrc drift from
// what renderer.js used to do, these fail.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { parseLRC, parseKrc, lyricsTextMatch, isEmphasisWord, currentLyricIndex, activeLyricRange } from '../src/core/lyrics.ts'

const SEC = 10_000_000   // ticks per second
const MS = 10_000        // ticks per millisecond

test('parseLRC: plain lines carry no word timing', () => {
  const out = parseLRC('[00:12.50]Hello world')
  assert.equal(out.length, 1)
  assert.equal(out[0].Start, 12.5 * SEC)
  assert.equal(out[0].Text, 'Hello world')
  assert.equal(out[0].Words, null)
})

test('parseLRC: whole-second timestamps are valid LRC', () => {
  // Regression: fractional seconds used to be mandatory, so every `[mm:ss]`
  // line was silently dropped and a file written that way lost most of its
  // content with no error.
  const out = parseLRC('[00:12]hello')
  assert.equal(out.length, 1)
  assert.equal(out[0].Start, 12 * SEC)
  assert.equal(out[0].Text, 'hello')
})

test('parseLRC: mixed whole-second and fractional lines all parse', () => {
  const out = parseLRC('[00:10]one\n[00:12.50]two\n[00:15]three')
  assert.deepEqual(out.map(l => l.Text), ['one', 'two', 'three'])
  assert.deepEqual(out.map(l => l.Start), [10 * SEC, 12.5 * SEC, 15 * SEC])
})

test('parseLRC: word timestamps also allow whole seconds', () => {
  const out = parseLRC('[00:10]<00:10>Hello <00:11.5>world')
  const words = out[0].Words
  assert.ok(words)
  assert.equal(words.length, 2)
  assert.equal(words[0].Start, 10 * SEC)
  assert.equal(words[1].Start, 11.5 * SEC)
})

test('parseLRC: skips metadata tags and blank content', () => {
  const out = parseLRC('[ti:Some Title]\n[ar:Artist]\n[00:01.00]\n[00:02.00]real')
  assert.equal(out.length, 1)
  assert.equal(out[0].Text, 'real')
})

test('parseLRC: enhanced LRC chains word end times to the next word', () => {
  const out = parseLRC('[00:10.00]<00:10.00>Hello <00:10.50>world\n[00:12.50]next')
  assert.equal(out.length, 2)

  const words = out[0].Words
  assert.ok(words, 'expected word-level timing')
  assert.equal(words.length, 2)
  assert.equal(out[0].Text, 'Hello world')

  assert.equal(words[0].Start, 10 * SEC)
  assert.equal(words[0].End, 10.5 * SEC, 'word end should be the next word start')
  assert.equal(words[1].Start, 10.5 * SEC)
  // Last word borrows the following line's start.
  assert.equal(words[1].End, 12.5 * SEC)
})

test('parseLRC: final word falls back to +2s when no line follows', () => {
  const out = parseLRC('[00:10.00]<00:10.00>only')
  const words = out[0].Words
  assert.ok(words)
  assert.equal(words[0].End, 10 * SEC + 2 * SEC)
})

test('parseLRC: bare punctuation attaches to the previous word', () => {
  // The tricky branch - a symbol token with no letters/digits must not become
  // its own word, or karaoke highlighting shows a lone "!" as a lyric.
  const out = parseLRC('[00:01.00]<00:01.00>hey<00:01.50>!')
  const words = out[0].Words
  assert.ok(words)
  assert.equal(words.length, 1, 'punctuation should merge, not add a word')
  assert.equal(words[0].Text, 'hey!')
})

test('parseLRC: per-character sources keep their spaces', () => {
  // Per-character formats timestamp each space separately. Those tokens must
  // survive as a space rather than being dropped, or the line runs together.
  const out = parseLRC('[00:01.00]<00:01.00>a<00:01.10> <00:01.20>b')
  assert.equal(out[0].Text, 'a b')
})

test('parseKrc: word offsets are relative to the line start', () => {
  const out = parseKrc('[1000,2000]<0,500,0>Hi<500,500,0> there')
  assert.equal(out.length, 1)

  assert.equal(out[0].Start, 1000 * MS)
  assert.equal(out[0].End, 3000 * MS, 'line end is start + duration')
  assert.equal(out[0].Text, 'Hi there')

  const words = out[0].Words
  assert.ok(words)
  assert.equal(words.length, 2)
  assert.equal(words[0].Start, 1000 * MS)
  assert.equal(words[0].End, 1500 * MS)
  assert.equal(words[1].Start, 1500 * MS)
  assert.equal(words[1].End, 2000 * MS)
})

test('parseKrc: skips tag lines', () => {
  const out = parseKrc('[ti:Title]\n[offset:0]\n[100,200]<0,200,0>x')
  assert.equal(out.length, 1)
  assert.equal(out[0].Text, 'x')
})

test('lyricsTextMatch: rejects clearly different songs', () => {
  const a = { lines: [{ Start: 0, End: null, Words: null, Text: 'never gonna give you up never gonna let you down' }] }
  const b = { lines: [{ Start: 0, End: null, Words: null, Text: 'bohemian rhapsody scaramouche fandango galileo figaro' }] }
  assert.equal(lyricsTextMatch(a, b), false)
})

test('lyricsTextMatch: accepts the same song', () => {
  const a = { lines: [{ Start: 0, End: null, Words: null, Text: 'never gonna give you up never gonna let you down' }] }
  assert.equal(lyricsTextMatch(a, a), true)
})

test('lyricsTextMatch: skips the check when there are too few Latin words', () => {
  // Non-Latin lyrics would otherwise be rejected against everything.
  const a = { lines: [{ Start: 0, End: null, Words: null, Text: '君の名は' }] }
  const b = { lines: [{ Start: 0, End: null, Words: null, Text: 'completely different english words here' }] }
  assert.equal(lyricsTextMatch(a, b), true)
})

test('isEmphasisWord: held a second or more, and short enough to be a held note', () => {
  const w = (text: string, sec: number) => ({ Start: 0, End: sec * SEC, Text: text })
  assert.equal(isEmphasisWord(w('ohhh', 1.2)), true)
  assert.equal(isEmphasisWord(w('ohhh', 0.6)), false)
  assert.equal(isEmphasisWord(w('ohhh ', 1)), true)                 // trailing space is not a letter
  assert.equal(isEmphasisWord(w('extraordinarily', 1.5)), false)     // just a long word
  assert.equal(isEmphasisWord({ Start: 0, End: null, Text: 'x' }), false)
  assert.equal(isEmphasisWord(w('!', 2)), false)
})

test('currentLyricIndex: promotes once the lead is sung, when there is no background', () => {
  const lines = parseLRC('[00:10.00]<00:10.00>one <00:11.00>two\n[00:20.00]next')
  lines[0].Words![1].End = 12 * SEC
  assert.equal(currentLyricIndex(lines, 0, 11.5 * SEC), 0)
  assert.equal(currentLyricIndex(lines, 0, 12.5 * SEC), 1)   // early, before 20s
})

test('currentLyricIndex: waits for background vocals before promoting early', () => {
  const w = (t: string, s: number, e: number) => ({ Start: s * SEC, End: e * SEC, Text: t })
  const lines = [
    { Start: 10 * SEC, End: 12 * SEC, Text: 'lead', Words: [w('lead', 10, 12)], Background: [w('ooh', 12, 15)] },
    { Start: 20 * SEC, End: 22 * SEC, Text: 'next', Words: [w('next', 20, 22)] },
  ]
  assert.equal(currentLyricIndex(lines, 0, 13 * SEC), 0)   // lead done, background still going
  assert.equal(currentLyricIndex(lines, 0, 15.5 * SEC), 1)
})

test('background vocals running into the next line light both as a group', () => {
  const w = (t: string, s: number, e: number) => ({ Start: s * SEC, End: e * SEC, Text: t })
  const lines = [
    { Start: 10 * SEC, End: 12 * SEC, Text: 'lead', Words: [w('lead', 10, 12)], Background: [w('ooh', 12, 21)] },
    { Start: 13 * SEC, End: 16 * SEC, Text: 'next', Words: [w('next', 13, 16)] },
  ]
  // The next line is current as soon as it starts, and the first stays lit
  // with it while its background is sung, and until the next line ends.
  assert.equal(currentLyricIndex(lines, 1, 14 * SEC), 1)
  assert.deepEqual(activeLyricRange(lines, 1, 14 * SEC), [0, 1])
  assert.deepEqual(activeLyricRange(lines, 1, 15.5 * SEC), [0, 1])
  // The next line ended at 16s, but the first one's background runs to 21s.
  assert.deepEqual(activeLyricRange(lines, 1, 16.5 * SEC), [0, 1])
  assert.deepEqual(activeLyricRange(lines, 1, 21.5 * SEC), [1, 1])
})

test('activeLyricRange: a line starting inside the previous one keeps both lit until it ends', () => {
  const l = (s: number, e: number, t: string) => ({ Start: s * SEC, End: e * SEC, Text: t, Words: null })
  const lines = [l(0, 5, 'before'), l(10, 14, 'A'), l(12, 16, 'B'), l(20, 22, 'after')]
  assert.deepEqual(activeLyricRange(lines, 2, 13 * SEC), [1, 2])   // A still going when B began
  assert.deepEqual(activeLyricRange(lines, 2, 15 * SEC), [1, 2])   // A done, B not: both stay lit
  assert.deepEqual(activeLyricRange(lines, 2, 16.5 * SEC), [2, 2]) // B ended
  assert.deepEqual(activeLyricRange(lines, 1, 11 * SEC), [1, 1])   // no overlap into 'before'
})

test('activeLyricRange: only lines still sung when the current one began, not a chain', () => {
  const l = (s: number, e: number | null) => ({ Start: s * SEC, End: e == null ? null : e * SEC, Text: 'x', Words: null })
  // Each line runs into the next (Notion's background vocals). The first ended
  // at 6s, before the third began at 8s: it is not lit with the third.
  assert.deepEqual(activeLyricRange([l(0, 6), l(4, 9), l(8, 12)], 2, 10 * SEC), [1, 2])
  // Two earlier lines both still going when the current one began: both lit.
  assert.deepEqual(activeLyricRange([l(0, 12), l(4, 12), l(8, 12)], 2, 10 * SEC), [0, 2])
  assert.deepEqual(activeLyricRange([l(0, null), l(1, null)], 1, 2 * SEC), [1, 1])
})
