// Playback reporting: telling Jellyfin what this client is doing.
//
// Three endpoints - start, progress, stopped. The app previously called only
// start and stopped, which meant the server's view froze at the moment a track
// began: position never advanced, pause never registered, and volume was never
// reported at all. A controller (the web UI, a phone) renders its transport
// from this state, so without progress reports its scrubber sits still and its
// volume slider has nothing to bind to.
//
// Progress must be sent periodically *and* on every state change.

import type { JellyfinClient } from './jellyfin.ts'

/** How often to check in while playing. Jellyfin's own clients use ~10s. */
export const PROGRESS_INTERVAL_MS = 10_000

export type PlayMethod = 'DirectPlay' | 'DirectStream' | 'Transcode'

/** A snapshot of local playback, in Jellyfin's units. */
export interface PlaybackState {
  itemId: string
  /** 100ns units. */
  positionTicks: number
  isPaused: boolean
  isMuted: boolean
  /** 0-100, Jellyfin's scale - not the 0-1 an <audio> element uses. */
  volumeLevel: number
  playSessionId?: string | null
  mediaSourceId?: string | null
  playMethod?: PlayMethod
  canSeek?: boolean
}

/**
 * The payload shape shared by start and progress.
 *
 * `VolumeLevel` and `IsMuted` are the fields a controller binds its volume UI
 * to; omitting them is why remote volume appeared to do nothing.
 */
export function buildPlaybackReport(s: PlaybackState): Record<string, unknown> {
  return {
    ItemId: s.itemId,
    PositionTicks: Math.max(0, Math.round(s.positionTicks)),
    IsPaused: s.isPaused,
    IsMuted: s.isMuted,
    VolumeLevel: clampVolume(s.volumeLevel),
    CanSeek: s.canSeek ?? true,
    PlayMethod: s.playMethod ?? 'DirectPlay',
    QueueableMediaTypes: ['Audio'],
    ...(s.playSessionId ? { PlaySessionId: s.playSessionId } : {}),
    ...(s.mediaSourceId ? { MediaSourceId: s.mediaSourceId } : {}),
  }
}

/** Playback began. */
export function reportStart(client: JellyfinClient, s: PlaybackState): Promise<void> {
  return post(client, '/Sessions/Playing', buildPlaybackReport(s))
}

/** Periodic check-in, and every play/pause/seek/volume change. */
export function reportProgress(client: JellyfinClient, s: PlaybackState): Promise<void> {
  return post(client, '/Sessions/Playing/Progress', {
    ...buildPlaybackReport(s),
    EventName: s.isPaused ? 'Pause' : 'TimeUpdate',
  })
}

/** Playback ended. Drives watch history, so position matters. */
export function reportStopped(client: JellyfinClient, s: PlaybackState): Promise<void> {
  return post(client, '/Sessions/Playing/Stopped', {
    ItemId: s.itemId,
    PositionTicks: Math.max(0, Math.round(s.positionTicks)),
    ...(s.playSessionId ? { PlaySessionId: s.playSessionId } : {}),
    ...(s.mediaSourceId ? { MediaSourceId: s.mediaSourceId } : {}),
  })
}

/**
 * Reporting is best-effort: a dropped check-in must never interrupt playback,
 * and these fire on a timer where an unhandled rejection would be noise.
 */
async function post(client: JellyfinClient, path: string, body: unknown): Promise<void> {
  try {
    await client.post(path, body)
  } catch {
    /* server unreachable or session gone; the next check-in re-syncs */
  }
}

function clampVolume(n: number): number {
  if (!Number.isFinite(n)) return 100
  return Math.min(100, Math.max(0, Math.round(n)))
}
