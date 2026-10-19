// Local mode's answers to what the screens send a server
// (docs/local-mode-plan.md, section 4). Reads already answer from the catalog
// (offline-query.ts); this is the rest:
//
// - playlistOpFor: the playlist writes the screens send Jellyfin, as the
//   operation local-library.js makes on the playlists kept in Cascade. The
//   screens are left as they are: the renderer's jfFetch hands these routes
//   here in Local mode instead of refusing them.
// - localQuery: the engine, plus the playlists made in Cascade that hold
//   nothing yet. The engine lists a playlist only while it holds something
//   ready, which is right for downloads and leaves a new playlist nowhere to
//   be found and filled. Wrapped here rather than changed there: the engine
//   has a Swift twin tested against the same fixture.

import type { JfItem } from './types.ts'
import type { OfflineIndex } from './offline-index.ts'
import { offlineQuery, type OfflineAnswer, type OfflineQuery } from './offline-query.ts'

/** A playlist change, as local-library.js makes it. */
export type LocalPlaylistOp =
  | { kind: 'create'; name: string; ids: string[] }
  | { kind: 'add'; id: string; ids: string[] }
  /** Every entry of these tracks: in the catalog a playlist entry's id is its
   *  track's (offline-query.ts playlistItems), so two copies of one track
   *  cannot be told apart. */
  | { kind: 'removeIds'; id: string; ids: string[] }
  /** The first entry of a track, to a new position. */
  | { kind: 'move'; id: string; entryId: string; to: number }
  | { kind: 'set'; id: string; name?: string; ids?: string[] }
  | { kind: 'delete'; id: string }

const ID = /^[A-Za-z0-9-]{1,64}$/
const idList = (v: string | null): string[] => (v ?? '').split(',').map(s => s.trim()).filter(s => ID.test(s))

function jsonBody(body: unknown): Record<string, unknown> {
  if (typeof body !== 'string' || !body) return {}
  try {
    const v = JSON.parse(body)
    return v && typeof v === 'object' && !Array.isArray(v) ? v : {}
  } catch { return {} }
}

/**
 * The operation a Jellyfin playlist write stands for, or null when the
 * request is anything else (which then fails as it does offline). `url` may be
 * a path or a whole URL; `isPlaylist` says whether an id is a playlist the
 * catalog holds, so DELETE /Items/{id} never reaches a song.
 */
export function playlistOpFor(method: string, url: string, body: unknown, isPlaylist: (id: string) => boolean): LocalPlaylistOp | null {
  let u: URL
  try { u = new URL(url, 'http://local') } catch { return null }
  const seg = u.pathname.split('/').filter(Boolean).map(decodeURIComponent)
  const q = (k: string) => {
    for (const [key, v] of u.searchParams) if (key.toLowerCase() === k.toLowerCase()) return v
    return null
  }
  const m = method.toUpperCase()
  const json = jsonBody(body)
  const bodyIds = Array.isArray(json.Ids) ? json.Ids.filter((x): x is string => typeof x === 'string' && ID.test(x)) : null
  const name = (typeof json.Name === 'string' ? json.Name : q('Name') ?? '').trim()
  const lower = seg.map(s => s.toLowerCase())

  if (m === 'POST' && lower.length === 1 && lower[0] === 'playlists') {
    return name ? { kind: 'create', name, ids: bodyIds?.length ? bodyIds : idList(q('Ids')) } : null
  }
  if (lower[0] !== 'playlists' && !(lower[0] === 'items' && lower.length === 2)) return null
  const id = seg[1]
  if (!id || !ID.test(id) || !isPlaylist(id)) return null
  if (lower[0] === 'items') return m === 'DELETE' ? { kind: 'delete', id } : null
  if (m === 'POST' && lower.length === 2) {
    const op: LocalPlaylistOp = { kind: 'set', id }
    if (typeof json.Name === 'string' && json.Name.trim()) op.name = json.Name.trim()
    if (bodyIds) op.ids = bodyIds
    return op
  }
  if (lower[2] !== 'items') return null
  if (m === 'POST' && lower.length === 3) return { kind: 'add', id, ids: idList(q('Ids')) }
  if (m === 'DELETE' && lower.length === 3) return { kind: 'removeIds', id, ids: idList(q('EntryIds')) }
  if (m === 'POST' && lower.length === 6 && lower[4] === 'move' && ID.test(seg[3]) && /^\d{1,6}$/.test(seg[5])) {
    return { kind: 'move', id, entryId: seg[3], to: Number(seg[5]) }
  }
  return null
}

/** A playlist's entries after an operation (not create or delete). */
export function applyPlaylistOp(trackIds: readonly string[], op: LocalPlaylistOp, max: number): string[] {
  switch (op.kind) {
    case 'add': return [...trackIds, ...op.ids].slice(0, max)
    case 'removeIds': { const drop = new Set(op.ids); return trackIds.filter(id => !drop.has(id)) }
    case 'move': {
      const from = trackIds.indexOf(op.entryId)
      if (from < 0) return [...trackIds]
      const out = [...trackIds]
      const [moved] = out.splice(from, 1)
      out.splice(Math.min(op.to, out.length), 0, moved)
      return out
    }
    case 'set': return op.ids ? op.ids.slice(0, max) : [...trackIds]
    default: return [...trackIds]
  }
}

const normId = (id: string) => id.toLowerCase().replace(/-/g, '')

/** The engine over Local mode's catalog, with playlists that hold nothing
 *  ready answered too: in the playlist lists, by id, and as empty. */
export function localQuery(index: OfflineIndex): OfflineQuery {
  const engine = offlineQuery(index)
  const empty = index.collections
    .filter(c => c.item.Type === 'Playlist' && !c.trackIds.some(id => index.tracks[id]?.file))
    .map(c => ({ ...c.item, ChildCount: 0 }) as JfItem)
  if (!empty.length) return engine
  const byId = new Map(empty.map(p => [normId(p.Id), p]))
  return {
    answer(path, params = {}, random) {
      const answer = engine.answer(path, params, random)
      const seg = path.split('?')[0].split('/').filter(Boolean).map(s => s.toLowerCase())
      const id = seg[1] ? normId(seg[1]) : ''
      if (seg.length === 2 && seg[0] === 'items' && answer.status === 404 && byId.has(id)) return { status: 200, body: byId.get(id) }
      if (seg.length === 3 && seg[0] === 'playlists' && seg[2] === 'items' && answer.status === 404 && byId.has(id)) {
        return { status: 200, body: { Items: [], TotalRecordCount: 0, StartIndex: 0 } }
      }
      if (seg.length === 2 && seg[0] === 'playlists' && answer.status === 404 && byId.has(id)) {
        return { status: 200, body: { OpenAccess: false, Shares: [], ItemIds: [] } }
      }
      if (seg.length === 1 && seg[0] === 'items' && answer.status === 200) return withEmpty(answer, params, empty)
      return answer
    },
  }
}

/** A playlist list (/Items?IncludeItemTypes=Playlist, nothing narrowing it
 *  further) with the empty playlists added and the list put back in order. */
function withEmpty(answer: OfflineAnswer, params: Record<string, unknown>, empty: JfItem[]): OfflineAnswer {
  const p = new Map(Object.entries(params).map(([k, v]) => [k.toLowerCase(), String(v ?? '')]))
  const types = (p.get('includeitemtypes') ?? '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean)
  if (types.length !== 1 || types[0] !== 'playlist') return answer
  if (['parentid', 'ids', 'searchterm', 'filters', 'isfavorite', 'startindex', 'limit'].some(k => p.get(k))) return answer
  const body = answer.body as { Items?: JfItem[]; TotalRecordCount?: number; StartIndex?: number }
  const items = [...(body.Items ?? []), ...empty]
  const desc = (p.get('sortorder') ?? '').toLowerCase().startsWith('descending')
  const key = (i: JfItem) => (i.SortName ?? i.Name ?? '').toLowerCase()
  items.sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0) * (desc ? -1 : 1))
  return { ...answer, body: { ...body, Items: items, TotalRecordCount: (body.TotalRecordCount ?? 0) + empty.length } }
}
