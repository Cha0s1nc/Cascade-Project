// Driving OTHER Jellyfin sessions from Cascade (Spotify Connect style device
// picking). remote-control.ts is the other half of this: it makes Cascade a
// castable TARGET. This half makes Cascade a controller of anyone else's
// session - the web UI's, a phone's, another Cascade's.
//
// Pure pieces only: which sessions are real targets, and the request shapes
// for the commands the device panel sends. The HTTP calls and polling live in
// renderer.js, same split as remote-control.ts.

/** Loosely typed on purpose - a session's shape depends on which fields
 *  Jellyfin decided to include, same reasoning as jellyfin.ts's jfGet. */
export interface RemoteSessionPlayState {
  PositionTicks?: number | null
  IsPaused?: boolean
  VolumeLevel?: number | null
  IsMuted?: boolean
}

export interface RemoteSessionItem {
  Id?: string
  Name?: string
  AlbumArtist?: string
  Artists?: string[]
  RunTimeTicks?: number
}

export interface RemoteSession {
  Id: string
  DeviceId?: string | null
  DeviceName?: string | null
  UserName?: string | null
  Client?: string | null
  SupportsRemoteControl?: boolean
  NowPlayingItem?: RemoteSessionItem | null
  PlayState?: RemoteSessionPlayState | null
}

/**
 * Sessions Cascade can actually drive.
 *
 * The server already filters `GET /Sessions` to `controllableByUserId`, but
 * that still includes Cascade's OWN session - it registers itself as
 * controllable too, so a phone can cast TO it (see remote-control.ts) - and
 * anything that dropped SupportsRemoteControl between the filter running and
 * the response landing. Both would show a "device" that is either us or dead,
 * so both are excluded here rather than trusted to the server's filter alone.
 */
export function filterControllableSessions(sessions: RemoteSession[], ownDeviceId: string): RemoteSession[] {
  return sessions.filter(s => s.SupportsRemoteControl && s.DeviceId !== ownDeviceId)
}

const TICKS_PER_SEC = 10_000_000

/** NaN/garbage in, 0 out - a corrupted seek target must never reach the server. */
export function secondsToTicks(sec: number): number {
  return Number.isFinite(sec) && sec > 0 ? Math.round(sec * TICKS_PER_SEC) : 0
}

/** Jellyfin's own 0-100 scale, same clamp as remote-control.ts's private
 *  clampPercent - duplicated rather than imported, since that one belongs to
 *  the cast-target half and this is the drive-other-sessions half; they only
 *  happen to agree on 0-100 today. */
export function clampVolumePercent(n: number): number {
  if (!Number.isFinite(n)) return 0
  return Math.min(100, Math.max(0, Math.round(n)))
}

/**
 * Query params for `POST /Sessions/{id}/Playing`.
 *
 * Null when there is nothing to play - an empty itemIds array is still a
 * "valid" request the server quietly does nothing with, which is a worse
 * failure mode than not sending it at all (it would look like the device
 * just ignored the command).
 */
export function buildPlayOnDeviceParams(
  itemIds: string[],
  playCommand: 'PlayNow' | 'PlayNext' | 'PlayLast' = 'PlayNow',
  startIndex = 0,
): { playCommand: string, itemIds: string[], startIndex: number } | null {
  const ids = (itemIds || []).filter(Boolean)
  if (!ids.length) return null
  return { playCommand, itemIds: ids, startIndex: Math.max(0, Math.trunc(startIndex) || 0) }
}

/**
 * Body for `POST /Sessions/{id}/Command` (the "full general command" route).
 *
 * That route, not `/Sessions/{id}/Command/{command}`, on purpose: the
 * path-only route has nowhere to carry a volume value, only the command
 * name.
 */
export function buildSetVolumeCommand(percent: number): { Name: string, Arguments: { Volume: string } } {
  return { Name: 'SetVolume', Arguments: { Volume: String(clampVolumePercent(percent)) } }
}

/**
 * A polled PlayState goes stale the instant it arrives - the target keeps
 * playing between polls. This projects the position forward from the last
 * poll so the panel's progress bar does not visibly freeze for the few
 * seconds between polls.
 *
 * ponytail: linear interpolation, no correction for the target's own
 * playback rate or a mid-poll buffering stall. Good enough for a progress
 * bar; revisit only if a target's reported position is ever measurably off.
 */
export function interpolatedPositionTicks(
  playState: RemoteSessionPlayState | null | undefined,
  polledAtMs: number,
  nowMs: number,
): number {
  const base = playState?.PositionTicks
  if (typeof base !== 'number' || !Number.isFinite(base)) return 0
  if (playState?.IsPaused) return base
  const elapsedMs = Math.max(0, nowMs - polledAtMs)
  return base + elapsedMs * (TICKS_PER_SEC / 1000)
}
