import { test } from 'node:test'
import assert from 'node:assert/strict'
import { convertSpicyLyrics, spicyCredit, safeCreditUrl, spicyFitsTrack } from '../src/core/spicy-lyrics.ts'

// Fixtures follow the SpicyLyrics reference schema (times in seconds).
const syllableBody = {
  Type: 'Syllable', id: '1QV6tiMFM6fSOKOGLMHYYg', source: 'spicy_lyrics',
  UploadAttribution: {
    Uploader: { id: '1', username: 'spikerko', url: 'https://spicylyrics.org/uid/1' },
    Maker: { id: '2', username: 'gc', url: 'https://spicylyrics.org/uid/2' },
  },
  Content: [
    {
      Type: 'Vocal',
      Lead: {
        StartTime: 7.357, EndTime: 9.5,
        Syllables: [
          { Text: 'Hel', StartTime: 7.357, EndTime: 7.6, IsPartOfWord: true },
          { Text: 'lo', StartTime: 7.6, EndTime: 7.9 },
          { Text: 'world', StartTime: 8.2, EndTime: 9.5 },
        ],
      },
      Background: [{ Syllables: [{ Text: 'oh', StartTime: 8.5, EndTime: 9.0 }] }],
    },
  ],
}

test('syllable sync: seconds become ticks, IsPartOfWord joins, gaps survive', () => {
  const out = convertSpicyLyrics({ Body: syllableBody, Status: 200, Type: 'object' })
  assert.ok(out)
  const [line] = out.lines
  assert.equal(line.Start, 73_570_000)
  assert.equal(line.End, 95_000_000)
  assert.equal(line.Text, 'Hello world (oh)')
  assert.deepEqual(line.Words!.map(w => w.Text), ['Hel', 'lo ', 'world ', '(oh)'])
  // "lo" ends at 7.9 and "world" starts at 8.2: the pause is kept, not
  // papered over by borrowing the next word's start.
  assert.equal(line.Words![1].End, 79_000_000)
  assert.equal(line.Words![2].Start, 82_000_000)
})

test('also accepts the bare Body', () => {
  assert.equal(convertSpicyLyrics(syllableBody)?.lines.length, 1)
})

test('a syllable with no time borrows the previous end, and a group with no times at all is dropped', () => {
  const out = convertSpicyLyrics({
    Type: 'Syllable', source: 'spicy_lyrics',
    Content: [
      { Lead: { Syllables: [{ Text: 'a', StartTime: 1, EndTime: 2 }, { Text: 'b' }] } },
      { Lead: { Syllables: [{ Text: 'lost' }] } },
    ],
  })
  assert.ok(out)
  assert.equal(out.lines.length, 1)
  assert.equal(out.lines[0].Words![1].Start, 20_000_000)
})

test('line sync keeps timed lines and drops untimed ones', () => {
  const out = convertSpicyLyrics({
    Type: 'Line', source: 'apple_music',
    Content: [{ Type: 'Vocal', Text: 'first (echo)', StartTime: 1.5, EndTime: 3 }, { Text: 'no time' }],
  })
  assert.ok(out)
  assert.deepEqual(out.lines, [{ Start: 15_000_000, End: 30_000_000, Text: 'first (echo)', Words: null }])
})

test('static sync reads Lines, not Content, and has no times', () => {
  const out = convertSpicyLyrics({ Type: 'Static', source: 'spotify', Lines: [{ Text: 'one' }, { Text: '  ' }, { Text: 'two' }] })
  assert.ok(out)
  assert.deepEqual(out.lines.map(l => [l.Start, l.Text]), [[null, 'one'], [null, 'two']])
})

test('nothing usable is null, so the waterfall falls through', () => {
  for (const junk of [null, 'x', {}, { Type: 'Karaoke' }, { Type: 'Syllable', Content: [] }, { Body: { Type: 'Static', Lines: [] } }]) {
    assert.equal(convertSpicyLyrics(junk), null)
  }
})

test('credit: community sync names uploader and maker', () => {
  assert.deepEqual(spicyCredit(syllableBody), {
    provider: 'Spicy Lyrics',
    uploader: { name: 'spikerko', url: 'https://spicylyrics.org/uid/1' },
    maker: { name: 'gc', url: 'https://spicylyrics.org/uid/2' },
  })
})

test('credit: maker absent means no maker, not an empty one', () => {
  const body = { ...syllableBody, UploadAttribution: { Uploader: syllableBody.UploadAttribution.Uploader } }
  assert.equal(spicyCredit(body).maker, null)
})

test('credit: a commercial source shows only the provider, even if attribution is sent', () => {
  const c = spicyCredit({ ...syllableBody, source: 'apple_music' })
  assert.deepEqual(c, { provider: 'Apple Music via Spicy Lyrics', uploader: null, maker: null })
  assert.equal(spicyCredit({ source: 'something-new' }).provider, 'Spicy Lyrics')
})

test('credit links are https only', () => {
  assert.equal(safeCreditUrl('https://spicylyrics.org/uid/1'), 'https://spicylyrics.org/uid/1')
  for (const bad of ['http://x.org', 'javascript:alert(1)', 'file:///etc/passwd', 'not a url', 42, null]) {
    assert.equal(safeCreditUrl(bad), null)
  }
  const c = spicyCredit({ source: 'spicy_lyrics', UploadAttribution: { Uploader: { username: 'x', url: 'javascript:alert(1)' } } })
  assert.deepEqual(c.uploader, { name: 'x', url: null })
})

test('fits track: a sync running past the end of the file is another version', () => {
  // The real case: Apple Music sync to 190.73s, local file 186.6s.
  assert.equal(spicyFitsTrack({ Body: { EndTime: 190.73 } }, 186.6), false)
  assert.equal(spicyFitsTrack({ EndTime: 185 }, 186.6), true)
  assert.equal(spicyFitsTrack({ EndTime: 187.5 }, 186.6), true)   // inside the slack
})

test('fits track: nothing to judge means it passes', () => {
  assert.equal(spicyFitsTrack({ Body: {} }, 186.6), true)
  assert.equal(spicyFitsTrack({ Body: { EndTime: 999 } }, 0), true)
  assert.equal(spicyFitsTrack(null, 186.6), true)
})
