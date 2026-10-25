// Sorting and filtering for the library grids (Albums, Artists, Playlists,
// Movies, TV Shows) and the day-grouping used by the History view.
//
// Songs already has its own sort (songSortValue/sortSongs in queue.ts),
// mutating a long-lived array other code holds a reference to. These views
// have no such shared reference - loadAlbums etc. keep the raw fetch and
// re-derive the displayed list from it - so these are pure functions that
// return a new array rather than sorting in place.

import type { JfItem } from './types.ts'
import type { SortDirection } from './queue.ts'
import { shuffleInPlace } from './queue.ts'

export type LibSortField = 'name' | 'artist' | 'year' | 'added' | 'played' | 'count' | 'random'

/** Sort key for an album/artist/playlist/movie/show. Missing values fall back
 *  to 0 (or '', for the tiebreak), same convention as songSortValue - it sorts
 *  first ascending rather than throwing or producing NaN. */
export function librarySortValue(item: JfItem, field: string): string | number {
  switch (field) {
    case 'artist': return (item.AlbumArtist || item.Artists?.[0] || '').toLowerCase()
    case 'year':   return item.ProductionYear || 0
    case 'added':  return item.DateCreated ? Date.parse(item.DateCreated) || 0 : 0
    case 'played': return item.UserData?.LastPlayedDate ? Date.parse(item.UserData.LastPlayedDate) || 0 : 0
    case 'count':  return item.ChildCount || 0
    default:       return (item.SortName || item.Name || '').toLowerCase()
  }
}

/**
 * Sort a copy of `items`. 'random' shuffles instead of comparing (there is
 * nothing to compare), reusing the same Fisher-Yates queue uses so there is
 * only one shuffle implementation in the app.
 *
 * Ties break on SortName/Name regardless of field or direction: with more
 * than one library merged, items that tie on year or date-added would
 * otherwise fall back to whatever order the merge happened to concatenate
 * them in, which looks random to the user and changes if a library is added
 * or removed.
 */
export function sortLibraryItems(items: JfItem[], field: string, dir: SortDirection): JfItem[] {
  if (field === 'random') return shuffleInPlace([...items])
  const mul = dir === 'desc' ? -1 : 1
  const tieKey = (item: JfItem) => (item.SortName || item.Name || '').toLowerCase()
  return [...items].sort((a, b) => {
    const va = librarySortValue(a, field)
    const vb = librarySortValue(b, field)
    if (va < vb) return -1 * mul
    if (va > vb) return 1 * mul
    return tieKey(a).localeCompare(tieKey(b))
  })
}

export interface LibraryFilters {
  favorite?: boolean
  /** Exact genre name. Matched against item.Genres, not a substring. */
  genre?: string | null
  /** Decade start year (1990 means 1990-1999), from ProductionYear. */
  decade?: number | null
  played?: 'played' | 'unplayed' | null
}

export function matchesLibraryFilters(item: JfItem, f: LibraryFilters): boolean {
  if (f.favorite && !item.UserData?.IsFavorite) return false
  if (f.genre && !(item.Genres || []).includes(f.genre)) return false
  if (f.decade != null) {
    const y = item.ProductionYear
    if (y == null || Math.floor(y / 10) * 10 !== f.decade) return false
  }
  if (f.played === 'played' && !item.UserData?.Played) return false
  if (f.played === 'unplayed' && item.UserData?.Played) return false
  return true
}

export function filterLibraryItems(items: JfItem[], f: LibraryFilters): JfItem[] {
  if (!f.favorite && !f.genre && f.decade == null && !f.played) return items
  return items.filter(i => matchesLibraryFilters(i, f))
}

export interface LibraryFilterOptions {
  genres: string[]     // sorted A-Z, only genres actually present
  decades: number[]     // sorted newest first, only decades actually present
}

/** Filter option lists are derived from the items already loaded rather than
 *  a separate /Genres request - the whole point of filtering client-side is
 *  that the data is already here, and this keeps the options naturally
 *  scoped to whatever libraries are currently selected. */
export function libraryFilterOptions(items: JfItem[]): LibraryFilterOptions {
  const genres = new Set<string>()
  const decades = new Set<number>()
  for (const item of items) {
    for (const g of item.Genres || []) genres.add(g)
    if (item.ProductionYear) decades.add(Math.floor(item.ProductionYear / 10) * 10)
  }
  return {
    genres: [...genres].sort((a, b) => a.localeCompare(b)),
    decades: [...decades].sort((a, b) => b - a),
  }
}

export interface LibraryPrefs {
  field: string
  dir: SortDirection
  favorite: boolean
  genre: string | null
  decade: number | null
  played: 'played' | 'unplayed' | null
}

const DEFAULT_PREFS: LibraryPrefs = {
  field: 'name', dir: 'asc', favorite: false, genre: null, decade: null, played: null,
}

/**
 * Turns whatever is in the store back into a safe LibraryPrefs.
 *
 * The store is untrusted (a corrupted or hand-edited value must never reach
 * a filter as garbage): a bad JSON payload, a field the caller no longer
 * offers, a direction that isn't asc/desc, or a non-finite decade all fall
 * back to the default rather than propagating.
 */
export function normalizeLibraryPrefs(raw: string | null | undefined, allowedFields: readonly string[]): LibraryPrefs {
  let parsed: Record<string, unknown> | null = null
  if (raw) {
    try {
      const p = JSON.parse(raw)
      if (p && typeof p === 'object' && !Array.isArray(p)) parsed = p as Record<string, unknown>
    } catch { /* corrupted store value - fall through to defaults */ }
  }
  const d = parsed || {}
  const field = typeof d.field === 'string' && allowedFields.includes(d.field) ? d.field : DEFAULT_PREFS.field
  const dir: SortDirection = d.dir === 'desc' ? 'desc' : 'asc'
  const favorite = d.favorite === true
  const genre = typeof d.genre === 'string' && d.genre ? d.genre : null
  const decade = typeof d.decade === 'number' && Number.isFinite(d.decade) ? d.decade : null
  const played = d.played === 'played' || d.played === 'unplayed' ? d.played : null
  return { field, dir, favorite, genre, decade, played }
}

export interface DayGroup {
  label: string
  items: JfItem[]
}

/** Local midnight of `d`, so grouping matches the user's own calendar rather
 *  than UTC (a play at 11pm should not land in "tomorrow"'s group). */
function startOfDay(d: Date): number {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

function dayLabel(dayMs: number, todayMs: number): string {
  const diffDays = Math.round((todayMs - dayMs) / 86_400_000)
  if (diffDays === 0) return 'Today'
  if (diffDays === 1) return 'Yesterday'
  const d = new Date(dayMs)
  const sameYear = d.getFullYear() === new Date(todayMs).getFullYear()
  return d.toLocaleDateString('en-US', sameYear
    ? { month: 'long', day: 'numeric' }
    : { month: 'long', day: 'numeric', year: 'numeric' })
}

/**
 * Groups already-newest-first items by the local calendar day they were last
 * played on. An item with no parseable LastPlayedDate is dropped rather than
 * crashing the grouping or landing in a bogus "Invalid Date" bucket - it
 * shouldn't happen given Filters=IsPlayed, but UserData is server data, not
 * something this function should trust blindly.
 */
export function groupByDay(items: JfItem[], now: Date = new Date()): DayGroup[] {
  const todayMs = startOfDay(now)
  const groups: DayGroup[] = []
  let lastDayMs: number | null = null
  for (const item of items) {
    const ts = item.UserData?.LastPlayedDate ? Date.parse(item.UserData.LastPlayedDate) : NaN
    if (Number.isNaN(ts)) continue
    const dayMs = startOfDay(new Date(ts))
    if (dayMs !== lastDayMs) {
      groups.push({ label: dayLabel(dayMs, todayMs), items: [] })
      lastDayMs = dayMs
    }
    groups[groups.length - 1].items.push(item)
  }
  return groups
}
