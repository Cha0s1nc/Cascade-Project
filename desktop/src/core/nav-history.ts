// Per-tab page history. Every sidebar tab keeps its own stack of pages, so a
// link opens its page in the tab you're in (an artist from a playlist stays
// under Playlists) and Back walks that tab's own way back. The renderer owns
// the panels; this only decides where a page goes and what Back lands on.

import { sectionMode } from './browse-mode.ts'

export type PageKind = 'album' | 'artist' | 'playlist' | 'smart' | 'genre' | 'movie' | 'series'

/** One step in a tab: its home (page null) or a page and what opened it. */
export interface NavEntry {
  page: PageKind | null
  args: unknown[]
  /** The tab's scroll position when it was left, put back on return. */
  scroll: number
}

export type NavStacks = Record<string, NavEntry[]>

/** Each page's own category, where it opened before pages followed the tab. */
export const PAGE_CATEGORY: Record<PageKind, string> = {
  album: 'albums', artist: 'artists', playlist: 'playlists', smart: 'playlists',
  genre: 'genres', movie: 'movies', series: 'shows',
}

/** Oldest steps go past this, so a long session can't grow a tab without end. */
export const NAV_MAX_DEPTH = 50

/** The tab a page opens in: the one you're in, unless that's Settings or a
 *  tab of the other browse mode (a movie opened while on Albums), where it
 *  goes to its own category as before. */
export function navHost(current: string, page: PageKind): string {
  const own = PAGE_CATEGORY[page]
  if (current === 'settings') return own
  const mode = sectionMode(current)
  return mode && mode !== sectionMode(own) ? own : current
}

export function navStack(stacks: NavStacks, view: string): NavEntry[] {
  return (stacks[view] ??= [{ page: null, args: [], scroll: 0 }])
}

export function navTop(stacks: NavStacks, view: string): NavEntry {
  const s = navStack(stacks, view)
  return s[s.length - 1]
}

export function navPush(stacks: NavStacks, view: string, page: PageKind | null, args: unknown[]): NavEntry {
  const s = navStack(stacks, view)
  const entry: NavEntry = { page, args, scroll: 0 }
  s.push(entry)
  if (s.length > NAV_MAX_DEPTH) s.splice(0, s.length - NAV_MAX_DEPTH)
  return entry
}

export function navCanGoBack(stacks: NavStacks, view: string): boolean {
  return navStack(stacks, view).length > 1
}

/** Drops the current step and returns the one Back lands on, or null at the start. */
export function navBack(stacks: NavStacks, view: string): NavEntry | null {
  const s = navStack(stacks, view)
  if (s.length < 2) return null
  s.pop()
  return s[s.length - 1]
}

/** Clicking the tab you're already on: its home, as a step Back can undo.
 *  Null when it's already home. */
export function navHome(stacks: NavStacks, view: string): NavEntry | null {
  return navTop(stacks, view).page ? navPush(stacks, view, null, []) : null
}

/** A page that no longer exists (a deleted playlist) leaves every tab's
 *  history, along with any home step that only separated two copies of it.
 *  Returns the tabs whose current step changed. */
export function navForget(stacks: NavStacks, page: PageKind, id: unknown): string[] {
  const changed: string[] = []
  for (const [view, s] of Object.entries(stacks)) {
    const top = s[s.length - 1]
    const kept = s.filter((e, i) => i === 0 || !(e.page === page && e.args[0] === id))
    // Two homes in a row are one step.
    const merged = kept.filter((e, i) => !(i > 0 && !e.page && !kept[i - 1].page))
    stacks[view] = merged
    if (merged[merged.length - 1] !== top) changed.push(view)
  }
  return changed
}
