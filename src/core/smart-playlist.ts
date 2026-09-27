// User-defined smart playlists: a rule builder that Jellyfin itself has no
// concept of, so the definitions live only in Cascade's local store
// (window.cascade.store), read back through parseSmartPlaylists() since a
// stored value is untrusted - a corrupt or hand-edited JSON blob must degrade
// to "no smart playlists" rather than crash the Playlists view.
//
// Evaluation is a two-step split on purpose:
//   1. toItemsQuery() translates whatever of the rule set CAN become a
//      Jellyfin /Items query parameter, to avoid pulling the whole library
//      for a narrow rule set. It only has to return a SUPERSET of the true
//      matches - it is a prefilter, never the source of truth.
//   2. matchesRules() / applySmartPlaylistRules() re-check every rule against
//      every item client-side, always, regardless of what the query already
//      filtered. That is the actual definition of "matches this playlist".
// This split means a query that pushes too little (or even nothing, e.g. an
// ANY match) is a performance question, never a correctness one.

import type { JfItem, JfParams } from './types.ts'

export type SmartPlaylistRule =
  | { field: 'genre', op: 'is' | 'isNot', value: string }
  | { field: 'artist', op: 'is', value: string }
  | { field: 'year', op: 'between', min: number, max: number }
  | { field: 'addedWithinDays', op: 'lte', days: number }
  | { field: 'played', op: 'is', value: boolean }
  | { field: 'playCount', op: 'gte', value: number }
  | { field: 'favorite', op: 'is', value: boolean }

export type SmartPlaylistSortField = 'name' | 'artist' | 'album' | 'dateAdded' | 'playCount'

export interface SmartPlaylistDef {
  /** `user:<uuid>`, generated at creation. Never reused, so a deleted
   *  playlist's id can never collide with a later one. */
  id: string
  name: string
  match: 'all' | 'any'
  rules: SmartPlaylistRule[]
  sortBy: SmartPlaylistSortField
  sortDir: 'asc' | 'desc'
  limit: number
}

const SORT_FIELDS: readonly SmartPlaylistSortField[] = ['name', 'artist', 'album', 'dateAdded', 'playCount']
const MAX_LIMIT = 500
const DEFAULT_LIMIT = 100
const MAX_DAYS = 3650        // ~10 years - long enough to mean "no real limit", short enough to reject garbage
const MIN_YEAR = 1000
const MAX_YEAR = 2100
const DAY_MS = 24 * 60 * 60 * 1000

function clampInt(n: unknown, min: number, max: number, fallback: number): number {
  const v = typeof n === 'number' ? Math.trunc(n) : NaN
  if (!Number.isFinite(v)) return fallback
  return Math.min(max, Math.max(min, v))
}

function validateRule(raw: unknown): SmartPlaylistRule | null {
  if (!raw || typeof raw !== 'object') return null
  const r = raw as Record<string, unknown>
  switch (r.field) {
    case 'genre':
      if ((r.op !== 'is' && r.op !== 'isNot') || typeof r.value !== 'string' || !r.value.trim()) return null
      return { field: 'genre', op: r.op, value: r.value.trim() }
    case 'artist':
      if (r.op !== 'is' || typeof r.value !== 'string' || !r.value.trim()) return null
      return { field: 'artist', op: 'is', value: r.value.trim() }
    case 'year': {
      if (r.op !== 'between') return null
      const a = clampInt(r.min, MIN_YEAR, MAX_YEAR, MIN_YEAR)
      const b = clampInt(r.max, MIN_YEAR, MAX_YEAR, MAX_YEAR)
      return { field: 'year', op: 'between', min: Math.min(a, b), max: Math.max(a, b) }
    }
    case 'addedWithinDays':
      if (r.op !== 'lte') return null
      return { field: 'addedWithinDays', op: 'lte', days: clampInt(r.days, 1, MAX_DAYS, 30) }
    case 'played':
      if (r.op !== 'is' || typeof r.value !== 'boolean') return null
      return { field: 'played', op: 'is', value: r.value }
    case 'playCount':
      if (r.op !== 'gte') return null
      return { field: 'playCount', op: 'gte', value: clampInt(r.value, 0, 1000000, 1) }
    case 'favorite':
      if (r.op !== 'is' || typeof r.value !== 'boolean') return null
      return { field: 'favorite', op: 'is', value: r.value }
    default:
      return null
  }
}

function validateDef(raw: unknown): SmartPlaylistDef | null {
  if (!raw || typeof raw !== 'object') return null
  const d = raw as Record<string, unknown>
  const id = typeof d.id === 'string' ? d.id.trim() : ''
  const name = typeof d.name === 'string' ? d.name.trim() : ''
  if (!id || !name) return null   // nothing to open or show without both
  const rules = Array.isArray(d.rules) ? d.rules.map(validateRule).filter((r): r is SmartPlaylistRule => r !== null) : []
  return {
    id,
    name,
    match: d.match === 'any' ? 'any' : 'all',
    rules,
    sortBy: SORT_FIELDS.includes(d.sortBy as SmartPlaylistSortField) ? (d.sortBy as SmartPlaylistSortField) : 'name',
    sortDir: d.sortDir === 'desc' ? 'desc' : 'asc',
    limit: clampInt(d.limit, 1, MAX_LIMIT, DEFAULT_LIMIT),
  }
}

/** Parses and validates whatever is in the store's `smartPlaylists` key.
 *  Never throws: malformed JSON, a non-array, or a malformed entry are all
 *  just dropped rather than breaking the whole Playlists view. */
export function parseSmartPlaylists(raw: string | null | undefined): SmartPlaylistDef[] {
  if (!raw) return []
  let arr: unknown
  try { arr = JSON.parse(raw) } catch { return [] }
  if (!Array.isArray(arr)) return []
  return arr.map(validateDef).filter((d): d is SmartPlaylistDef => d !== null)
}

export function serializeSmartPlaylists(defs: readonly SmartPlaylistDef[]): string {
  return JSON.stringify(defs)
}

/** Best-effort /Items query narrowing for an ALL match. Only the first rule
 *  of each translatable kind is used - a second "genre is" rule in the same
 *  ALL match must stay an AND, but Jellyfin's `Genres` param ORs together
 *  whatever list you give it, so pushing both would silently turn it into an
 *  OR. matchesRules() enforces the real AND afterward regardless. An ANY
 *  match can't be expressed as one query at all (each param is its own AND
 *  against the others), so it pushes nothing extra. */
export function toItemsQuery(def: Pick<SmartPlaylistDef, 'match' | 'rules'>): JfParams {
  const params: JfParams = {}
  if (def.match !== 'all') return params
  for (const rule of def.rules) {
    if (rule.field === 'genre' && rule.op === 'is' && params.Genres === undefined) {
      params.Genres = rule.value
    } else if (rule.field === 'artist' && params.Artists === undefined) {
      params.Artists = rule.value
    } else if (rule.field === 'year' && params.Years === undefined && rule.max - rule.min <= 100) {
      // A wide range is left unpushed rather than building a huge query
      // string - still correct, just no server-side narrowing for it.
      const years: number[] = []
      for (let y = rule.min; y <= rule.max; y++) years.push(y)
      params.Years = years.join(',')
    } else if (rule.field === 'played' && params.IsPlayed === undefined) {
      params.IsPlayed = rule.value
    } else if (rule.field === 'favorite' && params.IsFavorite === undefined) {
      params.IsFavorite = rule.value
    }
  }
  return params
}

/** The one place a rule is checked against an item. `now` is a parameter
 *  (not Date.now() inline) so addedWithinDays is actually testable. */
export function ruleMatches(item: JfItem, rule: SmartPlaylistRule, now: number): boolean {
  switch (rule.field) {
    case 'genre': {
      const has = (item.Genres || []).some(g => g.toLowerCase() === rule.value.toLowerCase())
      return rule.op === 'is' ? has : !has
    }
    case 'artist': {
      const name = rule.value.toLowerCase()
      const artists = item.Artists || []
      return artists.some(a => a.toLowerCase() === name) || (item.AlbumArtist || '').toLowerCase() === name
    }
    case 'year': {
      const y = item.ProductionYear
      return typeof y === 'number' && y >= rule.min && y <= rule.max
    }
    case 'addedWithinDays': {
      const created = item.DateCreated ? Date.parse(item.DateCreated) : NaN
      if (!Number.isFinite(created)) return false
      return now - created <= rule.days * DAY_MS
    }
    case 'played':
      return !!item.UserData?.Played === rule.value
    case 'playCount':
      return (item.UserData?.PlayCount || 0) >= rule.value
    case 'favorite':
      return !!item.UserData?.IsFavorite === rule.value
  }
}

/** A definition with no rules matches everything - a "browse all my music,
 *  sorted my way" playlist is a legitimate (if degenerate) use of the builder,
 *  not a state to special-case as empty. */
export function matchesRules(item: JfItem, def: Pick<SmartPlaylistDef, 'match' | 'rules'>, now: number): boolean {
  if (!def.rules.length) return true
  return def.match === 'any'
    ? def.rules.some(r => ruleMatches(item, r, now))
    : def.rules.every(r => ruleMatches(item, r, now))
}

function sortKey(item: JfItem, sortBy: SmartPlaylistSortField): string | number {
  switch (sortBy) {
    case 'name': return (item.SortName || item.Name || '').toLowerCase()
    case 'artist': return (item.AlbumArtist || item.Artists?.[0] || '').toLowerCase()
    case 'album': return (item.Album || '').toLowerCase()
    case 'dateAdded': return item.DateCreated ? (Date.parse(item.DateCreated) || 0) : 0
    case 'playCount': return item.UserData?.PlayCount || 0
  }
}

/** Filters (the real, full rule check - see the module comment), sorts and
 *  limits. This is what the caller actually renders; toItemsQuery() output is
 *  only ever a prefilter feeding into this, never a substitute for it. */
export function applySmartPlaylistRules(items: readonly JfItem[], def: SmartPlaylistDef, now: number): JfItem[] {
  const filtered = items.filter(item => matchesRules(item, def, now))
  const dir = def.sortDir === 'desc' ? -1 : 1
  filtered.sort((a, b) => {
    const ka = sortKey(a, def.sortBy)
    const kb = sortKey(b, def.sortBy)
    if (ka < kb) return -1 * dir
    if (ka > kb) return 1 * dir
    return 0
  })
  return filtered.slice(0, def.limit)
}
