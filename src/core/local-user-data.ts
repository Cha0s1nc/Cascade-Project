// Local mode's favorites, plays and positions (docs/local-mode-plan.md,
// section 4): written straight into the catalog's UserData, kept by item id so
// they outlive a rescan. Not Offline Mode's queue of changes (offline-sync.ts):
// there is no server to send them to, so nothing is capped or coalesced.
//
// Apart from local-scan.ts because the renderer runs these too: it patches its
// copy of the catalog in place rather than have a whole library sent again
// for one heart.

import type { JfItem } from './types.ts'
import { type OfflineIndex, isSafeId } from './offline-index.ts'

/** The user Local mode signs in as: there is nobody else. */
export const LOCAL_USER_ID = 'local'

/** What the person did with an item. */
export interface LocalUserData {
  IsFavorite?: boolean
  Played?: boolean
  PlayCount?: number
  PlaybackPositionTicks?: number
  LastPlayedDate?: string
}

export type LocalChange =
  | { kind: 'favorite'; favorite: boolean }
  | { kind: 'played'; played: boolean }
  | { kind: 'position'; ticks: number }
  /** Playback started: Jellyfin counts a play then. */
  | { kind: 'play' }

const isPlainObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** A change sent by the renderer, checked. */
export function parseLocalChange(v: unknown): LocalChange | null {
  if (!isPlainObject(v)) return null
  if (v.kind === 'favorite' && typeof v.favorite === 'boolean') return { kind: 'favorite', favorite: v.favorite }
  if (v.kind === 'played' && typeof v.played === 'boolean') return { kind: 'played', played: v.played }
  if (v.kind === 'position' && finite(v.ticks) && v.ticks >= 0) return { kind: 'position', ticks: Math.round(v.ticks) }
  if (v.kind === 'play') return { kind: 'play' }
  return null
}

/** One item's user data after a change, as the server would have it. */
export function applyLocalChange(ud: LocalUserData | undefined, change: LocalChange, now: Date): LocalUserData {
  const out: LocalUserData = { ...ud }
  const at = now.toISOString()
  switch (change.kind) {
    case 'favorite': out.IsFavorite = change.favorite; break
    case 'play':
      out.Played = true
      out.PlayCount = (out.PlayCount ?? 0) + 1
      out.LastPlayedDate = at
      break
    case 'position':
      out.PlaybackPositionTicks = change.ticks
      out.LastPlayedDate = at
      break
    case 'played':
      out.Played = change.played
      out.PlaybackPositionTicks = 0
      if (change.played) out.LastPlayedDate = at
      break
  }
  return out
}

/** Writes an item's user data into every copy the catalog keeps of it: its
 *  file's, its album's or playlist's, its show's or season's. */
export function setLocalUserData(index: OfflineIndex, itemId: string, ud: LocalUserData): void {
  const copies: JfItem[] = []
  if (index.tracks[itemId]) copies.push(index.tracks[itemId].item)
  for (const c of index.collections) if (c.item.Id === itemId) copies.push(c.item)
  if (index.containers[itemId]) copies.push(index.containers[itemId])
  for (const item of copies) item.UserData = { ...ud }
}

/** Stored user data, checked; an id that is not a plain id is dropped. */
export function parseUserData(raw: unknown): Record<string, LocalUserData> {
  const out: Record<string, LocalUserData> = {}
  if (!isPlainObject(raw)) return out
  for (const [id, v] of Object.entries(raw)) {
    if (!isSafeId(id) || !isPlainObject(v)) continue
    const ud: LocalUserData = {}
    if (typeof v.IsFavorite === 'boolean') ud.IsFavorite = v.IsFavorite
    if (typeof v.Played === 'boolean') ud.Played = v.Played
    if (finite(v.PlayCount) && v.PlayCount >= 0) ud.PlayCount = Math.floor(v.PlayCount)
    if (finite(v.PlaybackPositionTicks) && v.PlaybackPositionTicks >= 0) ud.PlaybackPositionTicks = Math.round(v.PlaybackPositionTicks)
    if (typeof v.LastPlayedDate === 'string' && Number.isFinite(Date.parse(v.LastPlayedDate))) ud.LastPlayedDate = new Date(Date.parse(v.LastPlayedDate)).toISOString()
    if (Object.keys(ud).length) out[id] = ud
  }
  return out
}
