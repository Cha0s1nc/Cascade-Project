// Right-click menus, generalised beyond tracks.
//
// Three card kinds (album, artist, movie/series/playlist) had no context menu
// at all before this - only track rows did. Rather than four separate menu
// elements, renderer.js reuses one (#item-ctx-menu) and shows/hides rows per
// kind. This file is the pure part of that: which rows apply to which kind,
// and the on-screen clamping math every context menu in the app needs.

/** What a right-clicked card actually is. 'video' covers both a standalone
 *  movie and an episode - both have their own playable media and their own
 *  UserData.Played, unlike a series, which is a container with neither. */
export type MenuItemKind = 'album' | 'artist' | 'video' | 'series' | 'playlist' | 'smart-playlist'

export interface MenuItemOptions {
  /** Only meaningful for 'video'/'series'. Undefined (no known played state,
   *  e.g. nothing populated UserData yet) hides both mark-played rows rather
   *  than guessing. */
  isPlayed?: boolean
}

export interface MenuItemVisibility {
  play: boolean
  playNext: boolean
  playLast: boolean
  shuffle: boolean
  instantMix: boolean
  addPlaylist: boolean
  markPlayed: boolean
  markUnplayed: boolean
  goArtist: boolean
  viewDetail: boolean
  rename: boolean
  deleteItem: boolean
  refreshMeta: boolean
  editMeta: boolean
}

const NONE: MenuItemVisibility = {
  play: false, playNext: false, playLast: false, shuffle: false, instantMix: false,
  addPlaylist: false, markPlayed: false, markUnplayed: false, goArtist: false,
  viewDetail: false, rename: false, deleteItem: false, refreshMeta: false, editMeta: false,
}

/**
 * Which rows a right-click menu should show for a given kind of card.
 *
 * Deliberately a flat table, not a class hierarchy or a plugin registry -
 * six kinds with mostly-disjoint action sets is a lookup, not an abstraction.
 */
export function menuItemsForKind(kind: MenuItemKind, opts: MenuItemOptions = {}): MenuItemVisibility {
  switch (kind) {
    case 'album':
      return { ...NONE, play: true, playNext: true, playLast: true, shuffle: true,
        addPlaylist: true, goArtist: true, refreshMeta: true, editMeta: true }
    case 'artist':
      return { ...NONE, play: true, shuffle: true, instantMix: true, viewDetail: true }
    case 'video':
      return { ...NONE, play: true, viewDetail: true,
        markPlayed: opts.isPlayed === false, markUnplayed: opts.isPlayed === true }
    case 'series':
      return { ...NONE, viewDetail: true,
        markPlayed: opts.isPlayed === false, markUnplayed: opts.isPlayed === true }
    case 'playlist':
      return { ...NONE, play: true, shuffle: true, rename: true, deleteItem: true }
    case 'smart-playlist':
      return { ...NONE, play: true, shuffle: true }
  }
}

/**
 * Nudge a menu fully back on screen if opening it at (x, y) would run it off
 * the right or bottom edge. Also floors it at (0, 0) so a menu wider or
 * taller than the viewport (a narrow window, a long admin-gated list) still
 * has its top-left corner reachable instead of drifting off the top-left too.
 */
export function clampMenuPosition(
  x: number, y: number,
  menuWidth: number, menuHeight: number,
  viewportWidth: number, viewportHeight: number,
): { left: number; top: number } {
  const left = x + menuWidth  > viewportWidth  ? x - menuWidth  : x
  const top  = y + menuHeight > viewportHeight ? y - menuHeight : y
  return { left: Math.max(0, left), top: Math.max(0, top) }
}
