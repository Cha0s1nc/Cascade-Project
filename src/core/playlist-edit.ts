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
