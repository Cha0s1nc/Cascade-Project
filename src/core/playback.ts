// Stream resolution via Jellyfin's PlaybackInfo negotiation.
//
// Replaces the old hardcoded /universal URL. The point is that the *client*
// declares what it can decode (a DeviceProfile) and the server decides between
// direct play and transcoding - so a TV client with different codec support
// gets a stream it can actually play. See profiles/PLATFORM-NOTES.md.

import type { JellyfinClient } from './jellyfin.ts'
import type { ServerConfig } from './types.ts'

export interface DirectPlayProfile {
  Type: 'Audio'
  /** Comma-separated container list, e.g. "mp3,flac". */
  Container: string
  AudioCodec?: string
}

export interface TranscodingProfile {
  Type: 'Audio'
  Container: string
  AudioCodec: string
  Protocol: string
  Context?: string
  MaxAudioChannels?: string
}

export interface DeviceProfile {
  Name?: string
  MaxStreamingBitrate?: number
  DirectPlayProfiles: DirectPlayProfile[]
  TranscodingProfiles: TranscodingProfile[]
  ContainerProfiles?: unknown[]
  CodecProfiles?: unknown[]
  SubtitleProfiles?: unknown[]
}

interface MediaSource {
  Id?: string
  Container?: string
  SupportsDirectPlay?: boolean
  SupportsDirectStream?: boolean
  SupportsTranscoding?: boolean
  /** Server-relative when present; means "transcode, use this". */
  TranscodingUrl?: string
}

interface PlaybackInfoResponse {
  MediaSources?: MediaSource[]
  PlaySessionId?: string
}

export interface ResolvedStream {
  url: string
  /** Needed so playback reporting ties to the right server-side session. */
  playSessionId: string | null
  mediaSourceId: string | null
  /** false when the server chose to transcode. */
  direct: boolean
}

/** Matches the old hardcoded URL, and the Electron profile default. */
export const DEFAULT_MAX_BITRATE = 140_000_000

/**
 * The pre-B1 stream URL, kept as a fallback.
 *
 * If PlaybackInfo fails (older server, network blip, unexpected shape) this
 * still plays audio. `/universal` makes the server guess, which is exactly what
 * Cascade did before - acceptable as a degraded path, not as the default.
 */
export function universalStreamUrl(
  config: ServerConfig,
  itemId: string,
  maxBitrate: number = DEFAULT_MAX_BITRATE,
): string {
  const { url, userId, token } = config
  return `${url}/Audio/${itemId}/universal`
    + `?UserId=${userId}&api_key=${token}`
    + `&Container=opus,mp3,aac,flac,wav,ogg`
    + `&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac`
    + `&MaxStreamingBitrate=${maxBitrate}`
}

/**
 * Ask the server how to play an item, given what this client can decode.
 *
 * Never throws: on any failure it falls back to `universalStreamUrl` so
 * playback degrades rather than dying.
 */
export async function resolveStream(
  client: JellyfinClient,
  config: ServerConfig,
  itemId: string,
  profile: DeviceProfile,
  maxBitrate: number = DEFAULT_MAX_BITRATE,
): Promise<ResolvedStream> {
  try {
    const info = await client.post<PlaybackInfoResponse>(
      `/Items/${itemId}/PlaybackInfo`,
      {
        UserId: config.userId,
        MaxStreamingBitrate: maxBitrate,
        DeviceProfile: { ...profile, MaxStreamingBitrate: maxBitrate },
        AutoOpenLiveStream: true,
      },
      { UserId: config.userId },
    )

    const source = info.MediaSources?.[0]
    if (!source) throw new Error('PlaybackInfo returned no media source')

    const playSessionId = info.PlaySessionId ?? null

    if (source.TranscodingUrl) {
      return {
        url: `${config.url}${source.TranscodingUrl}`,
        playSessionId,
        mediaSourceId: source.Id ?? null,
        direct: false,
      }
    }

    return {
      url: directStreamUrl(config, itemId, source, playSessionId),
      playSessionId,
      mediaSourceId: source.Id ?? null,
      direct: true,
    }
  } catch {
    return {
      url: universalStreamUrl(config, itemId, maxBitrate),
      playSessionId: null,
      mediaSourceId: null,
      direct: false,
    }
  }
}

function directStreamUrl(
  config: ServerConfig,
  itemId: string,
  source: MediaSource,
  playSessionId: string | null,
): string {
  const params = new URLSearchParams({ static: 'true', api_key: config.token })
  if (source.Id) params.set('mediaSourceId', source.Id)
  if (playSessionId) params.set('PlaySessionId', playSessionId)

  // The container extension matters: without it some servers re-probe the file
  // on every request.
  const ext = source.Container ? `.${source.Container.split(',')[0]}` : ''
  return `${config.url}/Audio/${itemId}/stream${ext}?${params}`
}
