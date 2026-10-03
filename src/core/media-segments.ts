// Jellyfin Media Segments (10.10 and later): typed time ranges inside a video,
// such as an intro or the end credits, that a client can offer to skip.
// `GET /MediaSegments/{itemId}` answers `{ Items: [{ Id, ItemId, Type,
// StartTicks, EndTicks }], TotalRecordCount, StartIndex }`. The server only has
// data when a provider produced it (the Intro Skipper plugin, chapter-based
// detection), so an older server (404) or an empty list both mean "nothing to
// show", never an error.

const TICKS_PER_SEC = 10_000_000

export type MediaSegmentType = 'Intro' | 'Outro' | 'Recap' | 'Preview' | 'Commercial'

const KNOWN_TYPES: ReadonlySet<string> = new Set(['Intro', 'Outro', 'Recap', 'Preview', 'Commercial'])

/** A segment as the player uses it, in seconds. */
export interface MediaSegment { type: MediaSegmentType; startSec: number; endSec: number }

/** The types the player offers a skip button for. A recap or a commercial
 *  has no agreed meaning for "skip", so they are parsed and left alone. */
const SKIPPABLE: ReadonlySet<string> = new Set(['Intro', 'Outro'])

/**
 * The segment list out of a `/MediaSegments/{id}` response, sorted by start.
 * Anything malformed (a type this build does not know, a non-finite or
 * negative tick, an end that is not after its start) is dropped rather than
 * trusted: the body comes from a server plugin.
 */
export function parseMediaSegments(raw: unknown): MediaSegment[] {
  const items = (raw as { Items?: unknown } | null | undefined)?.Items
  if (!Array.isArray(items)) return []
  const out: MediaSegment[] = []
  for (const it of items) {
    const type = it?.Type
    const start = it?.StartTicks
    const end = it?.EndTicks
    if (typeof type !== 'string' || !KNOWN_TYPES.has(type)) continue
    if (typeof start !== 'number' || typeof end !== 'number') continue
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end <= start) continue
    out.push({ type: type as MediaSegmentType, startSec: start / TICKS_PER_SEC, endSec: end / TICKS_PER_SEC })
  }
  return out.sort((a, b) => a.startSec - b.startSec || a.endSec - b.endSec)
}

/**
 * The skippable segment playing at `sec`, or null. The start is inside it and
 * the end is not, so a skip that lands exactly on the end does not offer the
 * button again. Where segments overlap, the one that ends last wins, so one
 * skip leaves all of them.
 */
export function activeSegment(segments: readonly MediaSegment[], sec: number): MediaSegment | null {
  if (!Number.isFinite(sec)) return null
  let best: MediaSegment | null = null
  for (const s of segments) {
    if (!SKIPPABLE.has(s.type)) continue
    if (sec >= s.startSec && sec < s.endSec && (!best || s.endSec > best.endSec)) best = s
  }
  return best
}

/** The button's label: "Skip Intro", "Skip Credits". */
export function skipLabel(segment: MediaSegment): string {
  return segment.type === 'Outro' ? 'Skip Credits' : 'Skip Intro'
}

export type SkipAction = { kind: 'seek'; sec: number } | { kind: 'next' }

/** Within this many seconds of the end counts as "runs to the end". */
export const SEGMENT_END_SLACK_SEC = 1

/**
 * What skipping `segment` does. An outro that runs to the end of the item has
 * nothing after it to seek to, so it means "go on to what is next" (the next
 * episode, if there is one; the caller decides what to do when there is not).
 * Everything else seeks to the segment's end.
 */
export function skipAction(segment: MediaSegment, durationSec: number): SkipAction {
  const toTheEnd = segment.type === 'Outro' && durationSec > 0 && segment.endSec >= durationSec - SEGMENT_END_SLACK_SEC
  return toTheEnd ? { kind: 'next' } : { kind: 'seek', sec: segment.endSec }
}

/** A stable key for "this segment of this item", so auto-skip fires once. */
export function segmentKey(itemId: string, segment: MediaSegment): string {
  return `${itemId}:${segment.type}:${segment.startSec}`
}
