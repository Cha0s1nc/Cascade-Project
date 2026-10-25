// Pure logic for the artist detail page's Top Songs shelf.

import type { JfItem } from './types.ts'

/** How many of the artist's own tracks to show in the Top Songs shelf. */
export const ARTIST_TOP_SONGS_MAX = 10

/**
 * Top songs are the artist's own tracks ordered by this user's PlayCount,
 * ties broken alphabetically so the list is stable rather than reflecting
 * whatever order the server happened to return.
 *
 * Jellyfin has no server-wide popularity figure it hands us for free - only
 * this user's own PlayCount - so "top songs you have on your server" is
 * necessarily local-listen-based. A global-popularity version (ListenBrainz,
 * matched via a MusicBrainz id in ProviderIds) was considered and skipped:
 * it would mean sending this user's local track/artist data to a third-party
 * service, which is exactly the kind of privacy trade-off this app opts into
 * deliberately elsewhere (see the README's iTunes art and translation
 * sections) rather than by default. Play-count is what "the top songs that
 * you have on your server" most plainly means anyway.
 */
export function topSongsOf(songs: readonly JfItem[], max = ARTIST_TOP_SONGS_MAX): JfItem[] {
  // A track nobody has played is not a "top song" - without this, an artist
  // with zero plays got a shelf that was really just the same track list
  // again, alphabetized, which is not what the section promises.
  return songs
    .filter(item => (item.UserData?.PlayCount || 0) > 0)
    .sort((a, b) => (b.UserData?.PlayCount || 0) - (a.UserData?.PlayCount || 0) || (a.Name || '').localeCompare(b.Name || ''))
    .slice(0, max)
}
