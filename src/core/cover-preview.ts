// The customization editor's crossfade preview (docs/customization-editor-spec.md,
// "Crossfade preview"): whether it runs, for how long, and what the card says.
// Pure, so the rules are tested apart from the DOM; renderer.js _cePreviewPlay
// gathers the inputs and runs the slice.

export interface CoverPreviewInput {
  /** Something is queued after the current song (or repeat-one replays it). */
  hasNext: boolean
  nextIsVideo: boolean
  /** The next song has the current song's cover. */
  sameCover: boolean
  /** displayPrefs.coverSlice: cover transitions switched on. */
  coverSlice: boolean
  reduceMotion: boolean
  crossfadeOn: boolean
  crossfadeSeconds: number
}

export interface CoverPreviewPlan {
  run: boolean
  /** How long the transition holds: the real crossfade length, or the fallback. */
  seconds: number
  /** Lines shown under the card. Always text, never only a visual. */
  notes: string[]
}

/** The length previewed while audio crossfade is off. */
export const PREVIEW_FALLBACK_SECONDS = 6

export function coverPreviewPlan(i: CoverPreviewInput): CoverPreviewPlan {
  const real = i.crossfadeOn && Number.isFinite(i.crossfadeSeconds) && i.crossfadeSeconds > 0
  const seconds = real ? i.crossfadeSeconds : PREVIEW_FALLBACK_SECONDS
  const stop = (note: string): CoverPreviewPlan => ({ run: false, seconds, notes: [note] })
  if (i.reduceMotion) return stop('Cover transitions are off while Reduce Motion is on.')
  if (!i.coverSlice) return stop('Cover transitions are off.')
  if (!i.hasNext) return stop('Queue another song to preview the transition.')
  if (i.nextIsVideo) return stop("The next item is a video, which doesn't use a cover transition.")
  const notes: string[] = []
  if (i.sameCover) notes.push("These two share a cover, so this transition won't show between them.")
  if (!real) notes.push(`Previewing a ${PREVIEW_FALLBACK_SECONDS}s crossfade.`)
  return { run: true, seconds, notes }
}
