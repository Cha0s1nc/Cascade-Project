// Picking the right album out of an iTunes Search response.
//
// The search is a fuzzy text query, so `results[0]` is whatever Apple thought
// was most relevant to "artist album" as a phrase - which for a common album
// name is regularly a tribute record, a karaoke version, a single that happens
// to share the title, or a different artist's album entirely. Taking it blindly
// is why the wrong cover turns up on the now-playing view and in the Discord
// presence.
//
// So: match the candidates against what was actually asked for, and return
// nothing when none of them fit. No art is a correct answer (Discord falls back
// to the app icon); someone else's art is not.

export interface ItunesResult {
  collectionName?: string
  collectionArtistName?: string
  artistName?: string
  artworkUrl100?: string
}

/** Lowercase, unaccent, and reduce to alphanumeric words. "DAMN." and "Damn"
 *  are the same album; "Sigur Rós" and "Sigur Ros" are the same band. */
const clean = (s: string): string =>
  s.normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()

/** `clean`, minus the edition furniture labels disagree about: Jellyfin's
 *  "Kid A" against iTunes' "Kid A (Deluxe Edition)", or "- Single" on a
 *  one-track release. A looser match than `clean`, and scored lower. */
const base = (s: string): string =>
  clean(s.replace(/\s*[([][^)\]]*[)\]]/g, ' ').replace(/\s+-\s+(single|ep)\s*$/i, ''))

/** Whether two artist spellings plausibly name the same act. Also used by the
 *  discography fallback to check that the artist it looked up is the one that
 *  was asked for.
 *
 *  ponytail: substring match, not word-boundary. A false hit on a short name
 *  only ever adds a tiebreak point between albums that already matched by
 *  name, or accepts a slightly-off artist whose albums are then matched by
 *  title anyway. Tighten it if it ever gates a decision on its own. */
export function itunesArtistMatches(got: string, want: string): boolean {
  // Both sides normalised here, not by the caller - `base` is idempotent, so
  // passing an already-normalised name is harmless, and doing it inside means
  // there is no way to call this with one raw and one clean string.
  const w = base(want || '')
  if (!w) return true
  const g = base(got || '')
  return !!g && (g === w || g.includes(w) || w.includes(g))
}

/** Album artists that name no act, so they cannot be held against a result. */
const COMPILATION_ARTISTS = new Set(['various artists', 'various', 'va'])

/**
 * The artwork URL for the best-matching album, upscaled from the 100px
 * thumbnail iTunes returns, or null if nothing in `results` is plausibly the
 * album that was asked for.
 *
 * The album name has to match and so does the artist. Short titles are shared
 * by many acts, and iTunes not having the album at all is common: brakence's
 * "ready or noT" searched up three other artists' "Ready or Not" singles, and
 * with the artist only breaking ties, someone else's breakcore remake became
 * the cover. A miss here sends the caller to the artist's own discography,
 * which is where the right record was. The exception is a compilation
 * AlbumArtist ("Various Artists"), which names no act to check against;
 * itunesArtistMatches already allows a featured-artist spelling. With no album
 * name at all, the artist carries the decision alone.
 */
export function pickItunesArt(
  results: ItunesResult[] | null | undefined,
  artist: string,
  album: string,
  size = 600,
): string | null {
  const wantAlbum  = base(album || '')
  const wantArtist = base(artist || '')
  const anyArtist = !wantArtist || COMPILATION_ARTISTS.has(wantArtist)
  let best: string | null = null
  let bestScore = 0

  for (const r of results ?? []) {
    const url = r?.artworkUrl100
    if (!url) continue
    const name     = r.collectionName ?? ''
    const by       = r.collectionArtistName ?? r.artistName ?? ''
    const byArtist = itunesArtistMatches(by, wantArtist)
    if (!byArtist && !anyArtist) continue   // the same title by somebody else

    const albumScore = !wantAlbum ? (byArtist ? 1 : 0)
      : clean(name) === clean(album) ? 3   // exact, editions included
      : base(name)  === wantAlbum    ? 2   // same album, different edition label
      : 0
    if (!albumScore) continue

    // Doubled so an artist tiebreak can never outrank a better album match.
    const score = albumScore * 2 + (byArtist ? 1 : 0)
    if (score > bestScore) { bestScore = score; best = url }
  }

  // Every iTunes artwork URL ends in a size token: .../100x100bb.jpg. Swapping
  // it is how you ask for a bigger render of the same image.
  return best ? best.replace(/\d+x\d+bb/, `${size}x${size}bb`) : null
}
