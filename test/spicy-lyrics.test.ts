import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  convertSpicyLyrics, spicyCredit, safeCreditUrl, spicyFitsTrack, parseSpotifyTrackId,
  isSpicyPublicKey, isSpotifyTrackId, spicyCacheFresh, SPICY_CACHE_MS, listenBrainzUrl, spotifyIdsFromListenBrainz, backoffMs, spicyLyricsUrl,
} from '../src/core/spicy-lyrics.ts'
import { SPICY_LYRICS_DAYS } from '../src/core/offline-index.ts'

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
  assert.equal(line.Text, 'Hello world')
  assert.deepEqual(line.Words!.map(w => w.Text), ['Hel', 'lo ', 'world'])
  // Background vocals are their own row, with their own timing.
  assert.deepEqual(line.Background!.map(w => [w.Text, w.Start]), [['oh', 85_000_000]])
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

test('Spotify track ids come out of links, URIs and bare ids, and nothing else does', () => {
  const id = '2VOomzT6VavJOGBeySqaMc'
  for (const ok of [id, ` ${id} `, `spotify:track:${id}`, `https://open.spotify.com/track/${id}`,
    `https://open.spotify.com/track/${id}?si=abc123`, `open.spotify.com/intl-de/track/${id}`,
    `https://open.spotify.com/embed/track/${id}`]) {
    assert.equal(parseSpotifyTrackId(ok), id, ok)
  }
  for (const bad of ['', 'nope', `https://open.spotify.com/album/${id}`, `https://open.spotify.com/playlist/${id}`,
    `https://evil.example/open.spotify.com/track/${id}`, `${id}x`, 'spotify:track:short', null, 42]) {
    assert.equal(parseSpotifyTrackId(bad), null, String(bad))
  }
})

test('a duet keeps which voice sings each line (OppositeAligned)', () => {
  // Shaped like the real "Dracula (JENNIE Remix)" sync: the second voice's
  // lines carry OppositeAligned true, the first voice's false.
  const vocal = (text: string, t: number, opposite: boolean) => ({
    Type: 'Vocal', OppositeAligned: opposite,
    Lead: { StartTime: t, EndTime: t + 1, Syllables: [{ Text: text, StartTime: t, EndTime: t + 1 }] },
  })
  const out = convertSpicyLyrics({ Type: 'Syllable', source: 'spicy_lyrics', Content: [vocal('Tame', 1, false), vocal('Jennie', 3, true)] })
  assert.ok(out)
  assert.equal(out.lines[0].Opposite, undefined, 'the first voice keeps the ordinary line shape')
  assert.equal(out.lines[1].Opposite, true)

  const lineSync = convertSpicyLyrics({
    Type: 'Line', source: 'spicy_lyrics',
    Content: [{ Text: 'first voice', StartTime: 1, EndTime: 2, OppositeAligned: false }, { Text: 'second voice', StartTime: 3, EndTime: 4, OppositeAligned: true }],
  })
  assert.ok(lineSync)
  assert.deepEqual(lineSync.lines.map(l => !!l.Opposite), [false, true])
})

// ── Asking SpicyLyrics from the app ──

test('only a public key is taken: Cascade bundles none and never asks for a secret one', () => {
  assert.equal(isSpicyPublicKey('sl_pk_abcDEF123_-xyz'), true)
  assert.equal(isSpicyPublicKey('  sl_pk_abcDEF123_-xyz  '), true)
  assert.equal(isSpicyPublicKey('sl_sk_abcDEF123456'), false)
  assert.equal(isSpicyPublicKey('sl_pk_short'), false)
  assert.equal(isSpicyPublicKey('sl_pk_has space inside'), false)
  assert.equal(isSpicyPublicKey(undefined), false)
})

test('answers are kept as long as Offline Mode keeps SpicyLyrics, and no longer', () => {
  assert.equal(SPICY_CACHE_MS, SPICY_LYRICS_DAYS * 86_400_000)
  const now = Date.parse('2026-10-19T12:00:00Z')
  assert.equal(spicyCacheFresh(now - 1000, now), true)
  assert.equal(spicyCacheFresh(now - SPICY_CACHE_MS + 1, now), true)
  assert.equal(spicyCacheFresh(now - SPICY_CACHE_MS, now), false, 'day 25 is gone')
  assert.equal(spicyCacheFresh(now + 60_000, now), false, 'a date in the future (clock moved back) is not trusted')
  assert.equal(spicyCacheFresh('x', now), false)
})

test('ListenBrainz is asked as the plugin asks it, and read the same way', () => {
  assert.equal(listenBrainzUrl('A & B', '', 'Song/Two'),
    'https://labs.api.listenbrainz.org/spotify-id-from-metadata/json?artist_name=A+%26+B&release_name=&track_name=Song%2FTwo')
  const a = '4uLU6hMCjMI75M1A2tKUQC', b = '7GhIk7Il098yCjg4BQjzvb'
  assert.deepEqual(spotifyIdsFromListenBrainz([{ spotify_track_ids: [a, 'nope', b, a] }, { spotify_track_ids: ['x'] }]), [a, b])
  assert.deepEqual(spotifyIdsFromListenBrainz([]), [])
  assert.deepEqual(spotifyIdsFromListenBrainz({ error: 'x' }), [])
  assert.equal(isSpotifyTrackId(a), true)
  assert.equal(isSpotifyTrackId('../etc/passwd/aaaaaaaaaa'), false)
  assert.equal(spicyLyricsUrl(a), `https://api.spicylyrics.org/v1/lyrics/${a}`)
})

test('a rate limit is waited out, never for good', () => {
  const now = Date.parse('2026-10-19T12:00:00Z')
  assert.equal(backoffMs(429, { retryAfter: '30' }, now), 30_000)
  assert.equal(backoffMs(429, { retryAfter: 'Mon, 19 Oct 2026 12:02:00 GMT' }, now), 120_000)
  assert.equal(backoffMs(429, { resetIn: '12' }, now), 12_000, "ListenBrainz's own header")
  assert.equal(backoffMs(429, {}, now), 60_000)
  assert.equal(backoffMs(503, { retryAfter: '5' }, now), 5_000)
  assert.equal(backoffMs(404, {}, now), 0)
  assert.equal(backoffMs(429, { retryAfter: '99999999' }, now), 86_400_000, 'capped at a day')
  assert.equal(backoffMs(429, { retryAfter: 'Mon, 19 Oct 2026 11:00:00 GMT' }, now), 0, 'a date already past')
})
