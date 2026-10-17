// Sending what happened offline (docs/offline-mode-plan.md, section 5). Pure:
// the renderer fetches and posts, this decides. CascadeKit's OfflineSync.swift
// is the same rules, and both pass test/fixtures/offline-sync.json.
//
// Two kinds of thing are sent, by two rules:
// - Plays are history. They are replayed only when the server's history still
//   matches the snapshot taken while online (nothing was played anywhere else
//   meanwhile), oldest first with their own dates; otherwise they are held for
//   the person to add or discard.
// - Positions, played marks and favorites are per item. Coalesced first, each
//   is sent only when the server's LastPlayedDate is older than the change.

import type { JfItem } from './types.ts'
import type { HistoryEntry, HistorySnapshot, OfflinePlay, UserDataChange } from './offline-index.ts'
import { historyEntriesOf, MAX_HISTORY_ENTRIES } from './offline-index.ts'

/** The history the snapshot keeps, and the list reconnecting compares with:
 *  one request, the same on both apps, across every library. */
export const HISTORY_QUERY: Readonly<Record<string, string>> = {
  Filters: 'IsPlayed',
  SortBy: 'DatePlayed',
  SortOrder: 'Descending',
  Recursive: 'true',
  IncludeItemTypes: 'Audio,Movie,Episode',
  Limit: String(MAX_HISTORY_ENTRIES),
}

/** What one item's queued changes come to: the fields for
 *  POST /UserItems/{id}/UserData, and a favorite for /UserFavoriteItems. */
export interface PendingUpdate {
  itemId: string
  userId: string
  /** The latest change's time (ISO 8601): what the conflict rule compares. */
  at: string
  userData?: { PlaybackPositionTicks?: number; Played?: boolean; LastPlayedDate?: string }
  favorite?: boolean
}

/** Each item's changes as one update, in the order items were first changed.
 *  Later changes win (only the last position matters); a favorite that ends
 *  where it started is no change. */
export function coalesceChanges(changes: UserDataChange[]): PendingUpdate[] {
  const out = new Map<string, PendingUpdate & { firstWas?: boolean }>()
  const ordered = changes.map((c, i) => ({ c, i })).sort((a, b) => Date.parse(a.c.at) - Date.parse(b.c.at) || a.i - b.i)
  for (const { c } of ordered) {
    const key = `${c.userId}/${c.itemId}`
    let u = out.get(key)
    if (!u) { u = { itemId: c.itemId, userId: c.userId, at: c.at }; out.set(key, u) }
    u.at = c.at
    if (c.kind === 'favorite') {
      if (u.firstWas === undefined) u.firstWas = c.was ?? !c.favorite
      u.favorite = !!c.favorite
      continue
    }
    const ud = u.userData ?? (u.userData = {})
    if (c.kind === 'position') {
      ud.PlaybackPositionTicks = c.ticks ?? 0
      ud.LastPlayedDate = c.at
    } else if (c.played) {
      ud.Played = true
      ud.PlaybackPositionTicks = 0
      ud.LastPlayedDate = c.at
    } else {
      ud.Played = false
      ud.PlaybackPositionTicks = 0
    }
  }
  const result: PendingUpdate[] = []
  for (const { firstWas, ...u } of out.values()) {
    if (u.favorite !== undefined && u.favorite === firstWas) delete u.favorite
    if (u.userData || u.favorite !== undefined) result.push(u)
  }
  return result
}

/** What to send for one update, given the item as the server has it now
 *  (null: the server no longer has it, so nothing). The change wins only
 *  when the server's LastPlayedDate is older than it: a position set on the
 *  TV after this device went offline is newer, and stays. Fields the server
 *  already holds are left out; null when nothing is left. */
export function updateToSend(update: PendingUpdate, server: JfItem | null): Omit<PendingUpdate, 'itemId' | 'userId' | 'at'> | null {
  if (!server) return null
  const sud = server.UserData ?? {}
  const serverAt = typeof sud.LastPlayedDate === 'string' ? Date.parse(sud.LastPlayedDate) : NaN
  if (Number.isFinite(serverAt) && serverAt >= Date.parse(update.at)) return null
  const out: Omit<PendingUpdate, 'itemId' | 'userId' | 'at'> = {}
  if (update.userData) {
    const ud = { ...update.userData }
    if (ud.Played !== undefined && ud.Played === !!sud.Played) delete ud.Played
    if (ud.PlaybackPositionTicks !== undefined && ud.PlaybackPositionTicks === (sud.PlaybackPositionTicks ?? 0) && ud.Played === undefined) delete ud.PlaybackPositionTicks
    // A date alone changes nothing a person sees.
    if (ud.Played !== undefined || ud.PlaybackPositionTicks !== undefined) out.userData = ud
  }
  if (update.favorite !== undefined && update.favorite !== !!sud.IsFavorite) out.favorite = update.favorite
  return out.userData || out.favorite !== undefined ? out : null
}

/** One fixed order for a list of rows, newest first and ties by id: the
 *  server may order two plays with one date either way from one request to
 *  the next. Text order, so both apps sort alike; both lists go through it,
 *  so it only has to be the same order every time. */
function ordered(entries: HistoryEntry[]): HistoryEntry[] {
  return [...entries].sort((a, b) => {
    const da = a.LastPlayedDate ?? '', db = b.LastPlayedDate ?? ''
    if (da !== db) return da < db ? 1 : -1
    return a.Id < b.Id ? -1 : a.Id > b.Id ? 1 : 0
  })
}

/** Whether the server's history (HISTORY_QUERY's answer) is the snapshot's:
 *  same items, dates and counts in the same order. No snapshot never matches. */
export function snapshotMatches(snapshot: HistorySnapshot | null, serverItems: JfItem[]): boolean {
  if (!snapshot) return false
  const a = ordered(snapshot.entries)
  const b = ordered(historyEntriesOf(serverItems))
  return a.length === b.length && a.every((e, i) => e.Id === b[i].Id && e.LastPlayedDate === b[i].LastPlayedDate && e.PlayCount === b[i].PlayCount)
}

export type CatchUp = 'none' | 'replay' | 'hold'

/** What to do with the plays queued offline, back online: nothing to do,
 *  replay them, or hold them for the person (already held, or someone played
 *  on this account elsewhere meanwhile). */
export function playsCatchUp(state: { plays: OfflinePlay[]; history: HistorySnapshot | null; playsHeld: boolean }, serverItems: JfItem[]): CatchUp {
  if (!state.plays.length) return 'none'
  if (state.playsHeld) return 'hold'
  return snapshotMatches(state.history, serverItems) ? 'replay' : 'hold'
}

/** The order plays are replayed in, so the server's history reads as if they
 *  had happened online. */
export const playsOldestFirst = (plays: OfflinePlay[]): OfflinePlay[] =>
  plays.map((p, i) => ({ p, i })).sort((a, b) => Date.parse(a.p.date) - Date.parse(b.p.date) || a.i - b.i).map(x => x.p)
