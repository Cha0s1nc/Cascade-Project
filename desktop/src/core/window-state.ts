// Where the main window reopens. main.js saves its normal (unmaximized)
// bounds and whether it was maximized; this decides whether those still fit
// the monitors connected now. A monitor unplugged, or rearranged, since the
// window closed must not reopen it off-screen, so the saved spot is kept only
// if enough of its title bar lands on a display, and its size is shrunk to
// fit that display. Pure, so it is tested; main.js loads it as
// build/window-state.js (see the build:main script).

export interface Rect { x: number, y: number, width: number, height: number }

const TITLE_BAR = 38
// How much of the title bar must be on a display to grab and move it.
const MIN_VISIBLE_WIDTH = 120
const MIN_VISIBLE_HEIGHT = 20

const isRect = (r: unknown): r is Rect => !!r && typeof r === 'object'
  && ['x', 'y', 'width', 'height'].every(k => Number.isFinite((r as Record<string, unknown>)[k]))

const overlap = (a: Rect, b: Rect) => ({
  width: Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x),
  height: Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y),
})

/** The bounds to reopen at and whether to maximize, or null to use the default placement. */
export function windowBoundsToRestore(saved: unknown, workAreas: readonly Rect[], min: { width: number, height: number }): { bounds: Rect, maximized: boolean } | null {
  if (!isRect(saved)) return null
  // At the width it will open at: never under the window's minimum.
  const titleBar = { x: saved.x, y: saved.y, width: Math.max(saved.width, min.width), height: TITLE_BAR }
  const area = workAreas.find(a => {
    const o = overlap(titleBar, a)
    return o.width >= MIN_VISIBLE_WIDTH && o.height >= MIN_VISIBLE_HEIGHT
  })
  if (!area) return null
  const width = Math.round(Math.min(Math.max(saved.width, min.width), area.width))
  const height = Math.round(Math.min(Math.max(saved.height, min.height), area.height))
  // Kept on its display: shrinking can leave the far edge past it.
  const x = Math.round(Math.min(Math.max(saved.x, area.x), area.x + area.width - width))
  const y = Math.round(Math.min(Math.max(saved.y, area.y), area.y + area.height - height))
  return { bounds: { x, y, width, height }, maximized: (saved as unknown as Record<string, unknown>).maximized === true }
}
