// Bulk playlist editing: remove and move-to-top/bottom over a selection of
// rows. Pure, no DOM - renderer.js owns the checkbox selection (a Set of
// entry ids) and the actual POST /Playlists/{id} write; this only computes
// the new row order it should send.

import type { JfItem } from './types.ts'

/** The id that identifies one row in a real playlist - the entry id when
 *  present (a track can appear more than once), the track id otherwise. Same
 *  fallback renderer.js already uses for drag-reorder and remove-from-playlist. */
export function entryIdOf(item: JfItem): string {
  return item.PlaylistItemId || item.Id
}

/** Drop every selected row, keeping the rest in their existing order. */
export function removeSelected(items: JfItem[], selected: ReadonlySet<string>): JfItem[] {
  return items.filter(item => !selected.has(entryIdOf(item)))
}

/** Pull every selected row to the front, in their existing relative order. */
export function moveSelectedToTop(items: JfItem[], selected: ReadonlySet<string>): JfItem[] {
  const sel: JfItem[] = []
  const rest: JfItem[] = []
  for (const item of items) (selected.has(entryIdOf(item)) ? sel : rest).push(item)
  return [...sel, ...rest]
}

/** Push every selected row to the back, in their existing relative order. */
export function moveSelectedToBottom(items: JfItem[], selected: ReadonlySet<string>): JfItem[] {
  const sel: JfItem[] = []
  const rest: JfItem[] = []
  for (const item of items) (selected.has(entryIdOf(item)) ? sel : rest).push(item)
  return [...rest, ...sel]
}

/** Spaces writes to one playlist at least `spacingMs` apart. Jellyfin 10.11.11
 *  rewrites playlist.xml from a background metadata saver shortly after each
 *  playlist change; a second write landing inside that window collides with
 *  it on the file ("being used by another process" in the server log) and the
 *  playlist is left in an older state, though every request answered 204.
 *  Measured: writes 100 ms apart lost the final state 7 runs in 10, 300 ms
 *  apart none in 10. The slot is taken before sleeping, so concurrent writes
 *  queue in turn. The native app does the same (PlaylistWriteGate). */
export function createPlaylistWriteGate(
  spacingMs = 400,
  now: () => number = () => Date.now(),
  sleep: (ms: number) => Promise<void> = ms => new Promise(resolve => setTimeout(resolve, ms)),
): (playlistId: string) => Promise<void> {
  const nextSlot = new Map<string, number>()
  return async playlistId => {
    const t = now()
    const slot = Math.max(t, nextSlot.get(playlistId) ?? t)
    nextSlot.set(playlistId, slot + spacingMs)
    if (slot > t) await sleep(slot - t)
  }
}

// ── Playlist details: picture and description ───────────────────────────────

/** Largest picture accepted for a playlist, the same cap Cascade Server's
 *  playlist image route enforces (docs/cascade-server-plugin-tasks.md). */
export const PLAYLIST_IMAGE_MAX_BYTES = 10 * 1024 * 1024

/** Longest description accepted, matching the plugin route. */
export const PLAYLIST_OVERVIEW_MAX = 2000

export type PlaylistImageType = 'image/jpeg' | 'image/png' | 'image/webp'

/**
 * What an image file really is, from its first bytes, or null for anything
 * else. The file picker's own type comes from the extension, and a renamed
 * file would be sent to the server under the wrong Content-Type.
 */
export function sniffImageType(bytes: Uint8Array): PlaylistImageType | null {
  const at = (i: number, ...v: number[]) => v.every((b, k) => bytes[i + k] === b)
  if (bytes.length >= 3 && at(0, 0xff, 0xd8, 0xff)) return 'image/jpeg'
  if (bytes.length >= 8 && at(0, 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return 'image/png'
  // RIFF....WEBP
  if (bytes.length >= 12 && at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50)) return 'image/webp'
  return null
}

/**
 * How a playlist's picture and description can be changed for this user:
 * through Cascade Server, which lets the playlist's owner do it; through
 * Jellyfin's own routes, which require an admin; or not at all. The plugin
 * is preferred even for an admin, so both kinds of account take one path.
 */
export function playlistDetailsRoute(pluginCaps: ReadonlySet<string>, pluginPresent: boolean, isAdmin: boolean): 'plugin' | 'admin' | null {
  if (pluginPresent && pluginCaps.has('playlist-edit')) return 'plugin'
  return isAdmin ? 'admin' : null
}

/** Bytes to base64, in chunks: Jellyfin's own image upload route takes the
 *  body as base64 text, and spreading a multi-megabyte array into one
 *  String.fromCharCode call overflows the stack. */
export function bytesToBase64(bytes: Uint8Array): string {
  let binary = ''
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  }
  return btoa(binary)
}
