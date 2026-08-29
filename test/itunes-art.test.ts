import { test } from 'node:test'
import assert from 'node:assert/strict'
import { pickItunesArt, itunesArtistMatches } from '../src/core/itunes-art.ts'

const art = (n: string) =>
  `https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/${n}/100x100bb.jpg`

const r = (collectionName: string, artistName: string) =>
  ({ collectionName, artistName, artworkUrl100: art(collectionName) })

test('an exact album match beats the more relevant-looking first hit', () => {
  const results = [
    r('Hip Hop Takes On - Demon Days: The Tribute', 'Various Artists'),
    r('Demon Days', 'Gorillaz'),
  ]
  assert.equal(pickItunesArt(results, 'Gorillaz', 'Demon Days'), art('Demon Days').replace('100x100bb', '600x600bb'))
})

test('punctuation and accents do not block an exact match', () => {
  assert.match(pickItunesArt([r('DAMN.', 'Kendrick Lamar')], 'Kendrick Lamar', 'Damn')!, /DAMN/)
  assert.ok(pickItunesArt([r('Café Bleu', 'The Style Council')], 'The Style Council', 'Cafe Bleu'))
  // Ligatures do not decompose, so both sides have to spell it the same way -
  // which they do, since both tag sets come from the same metadata upstreams.
  assert.ok(pickItunesArt([r('Ágætis byrjun', 'Sigur Rós')], 'Sigur Rós', 'Ágætis byrjun'))
})

test('an edition suffix still matches, but loses to the plain album', () => {
  const results = [r('Kid A (Deluxe Edition)', 'Radiohead'), r('Kid A', 'Radiohead')]
  assert.equal(pickItunesArt(results, 'Radiohead', 'Kid A'), art('Kid A').replace('100x100bb', '600x600bb'))
  // On its own, the deluxe edition is still the right record.
  assert.ok(pickItunesArt([results[0]], 'Radiohead', 'Kid A'))
})

test('the artist only breaks ties between albums of the same name', () => {
  const results = [r('Home', 'Some Other Band'), r('Home', 'The Wanted')]
  assert.equal(pickItunesArt(results, 'The Wanted', 'Home'), art('Home').replace('100x100bb', '600x600bb'))
  // A disagreeing AlbumArtist must not throw away the only real match.
  assert.ok(pickItunesArt([r('Home', 'The Wanted')], 'Various Artists', 'Home'))
})

test('nothing matching means no art, not the wrong art', () => {
  assert.equal(pickItunesArt([r('Greatest Hits', 'Queen')], 'Boards of Canada', 'Geogaddi'), null)
  assert.equal(pickItunesArt([], 'Anyone', 'Anything'), null)
  assert.equal(pickItunesArt(null, 'Anyone', 'Anything'), null)
})

test('with no album name the artist has to carry it alone', () => {
  assert.ok(pickItunesArt([r('Whatever', 'Aphex Twin')], 'Aphex Twin', ''))
  assert.equal(pickItunesArt([r('Whatever', 'Aphex Twin')], 'Autechre', ''), null)
})

test('a result with no artwork is skipped rather than returned as a match', () => {
  const results = [{ collectionName: 'Kid A', artistName: 'Radiohead' }, r('Kid A', 'Radiohead')]
  assert.ok(pickItunesArt(results, 'Radiohead', 'Kid A'))
})

test('collectionArtistName wins over artistName when both are present', () => {
  const results = [{ collectionName: 'Watch the Throne', collectionArtistName: 'JAY-Z & Kanye West', artistName: 'Nobody', artworkUrl100: art('wtt') }]
  assert.ok(pickItunesArt(results, 'JAY-Z & Kanye West', 'Watch the Throne'))
})

test('itunesArtistMatches tolerates spelling drift but not a different act', () => {
  assert.ok(itunesArtistMatches('Panic! At the Disco', 'Panic! At The Disco'))
  assert.ok(itunesArtistMatches('JAY-Z & Kanye West', 'JAY Z & Kanye West'))
  assert.ok(itunesArtistMatches('Gorillaz', 'Gorillaz'))
  assert.ok(!itunesArtistMatches('géraud', 'Panic! At The Disco'))
  assert.ok(!itunesArtistMatches('R. Kelly', 'Panic! At The Disco'))
  assert.ok(itunesArtistMatches('anything', ''))  // nothing asked for, nothing to reject
})

// The real search response for "Panic! At The Disco A Fever You Can't Sweat
// Out", which is why the discography fallback exists: three records, none of
// them the album, and results[0] is a lofi covers record whose title contains
// the whole album name.
test('the lofi covers record does not pass as the album', () => {
  const searchResults = [
    r("a fever you can't sweat out, but lofi", 'géraud'),
    r('Chocolate Factory', 'R. Kelly'),
    r('The Getaway', 'Red Hot Chili Peppers'),
  ]
  assert.equal(pickItunesArt(searchResults, 'Panic! At The Disco', "A Fever You Can't Sweat Out"), null)
})

test('the same matcher works on /lookup records, which carry extra fields', () => {
  const lookupResults = [
    { wrapperType: 'artist', artistName: 'Panic! At the Disco' },
    { wrapperType: 'collection', collectionName: "A Fever You Can't Sweat Out (20th Anniversary Deluxe)", artistName: 'Panic! At the Disco', collectionPrice: 9.99, artworkUrl100: art('deluxe') },
    { wrapperType: 'collection', collectionName: "A Fever You Can't Sweat Out", artistName: 'Panic! At the Disco', collectionPrice: 9.99, artworkUrl100: art('fever') },
  ]
  assert.equal(
    pickItunesArt(lookupResults as never, 'Panic! At The Disco', "A Fever You Can't Sweat Out"),
    art('fever').replace('100x100bb', '600x600bb'),
  )
})
