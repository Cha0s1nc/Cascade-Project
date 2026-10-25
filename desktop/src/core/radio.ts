// Internet radio, played through Jellyfin's Live TV channel pipeline.
//
// Why Live TV and not a music-library .strm file: verified against a real
// Jellyfin 10.11 server and its own source. A .strm file in a MUSIC library
// scans as an Audio item, but Jellyfin's shortcut-URL resolution
// (BaseItem.cs, the branch that swaps a .strm's Path for the URL inside it)
// only runs for a `Video` entity - an Audio item's MediaSource keeps
// Protocol=File and the on-disk .strm path forever. Streaming it hands ffmpeg
// the literal text file as input ("-i file:.../station.strm"), which fails
// (verified: HTTP 500, "FFmpeg exited with code 183"). A Live TV channel from
// an M3U tuner has none of this problem - PlaybackInfo correctly resolves it
// to Protocol=Http, IsInfiniteStream=true, with a working LiveStreamId, and
// /Audio/{channelId}/stream actually returns real audio (verified: valid
// MPEG audio bytes back from a SomaFM stream through the test server).
//
// The one thing Jellyfin does NOT do reliably: mark which Live TV channels
// are radio versus real TV. M3uParser.cs never sets ChannelType away from
// its default (TV), and the server's own `type=Radio` filter on
// /LiveTv/Channels is a no-op regardless of value (verified: type=Bogus
// returns the same unfiltered list). So Cascade cannot auto-detect "this
// channel is radio" - see the Settings toggle this feeds instead
// (renderer.js, radioEnabled).

import type { JellyfinClient } from './jellyfin.ts'
import type { ServerConfig } from './types.ts'
import type { DeviceProfile } from './playback.ts'

/** Loosely typed on purpose, matching the other item-shaped types in this
 *  codebase - only the fields this file actually reads. */
export interface RadioItem {
  Id?: string
  Type?: string
}

/** A Live TV channel is the one kind of item this whole feature ever hands
 *  to the playback choke points below, so checking `Type` is a completely
 *  reliable guard wherever an "is this radio" check is needed - independent
 *  of how the Radio view itself decided what to list. */
export function isRadioItem(item: RadioItem | null | undefined): boolean {
  return item?.Type === 'TvChannel'
}

interface RadioMediaSource {
  Id?: string
  Container?: string
  LiveStreamId?: string
}

interface RadioPlaybackInfoResponse {
  MediaSources?: RadioMediaSource[]
  PlaySessionId?: string
}

export interface ResolvedRadioStream {
  url: string
  playSessionId: string | null
  mediaSourceId: string | null
  liveStreamId: string | null
}

/** The stream URL a resolved Live TV source plays through - the plain
 *  `/Audio/{id}/stream` endpoint, same family as an ordinary track, just
 *  carrying LiveStreamId so the server knows which open tuner session to
 *  read from. No `static=true`: that flag means "hand over the file
 *  byte-for-byte", which for a remote channel is the wrong request entirely
 *  (verified) - omitting it is what makes the server actually transcode/relay
 *  the live source instead. */
export function buildRadioStreamUrl(
  config: ServerConfig,
  channelId: string,
  source: RadioMediaSource,
  playSessionId: string | null,
): string {
  const params = new URLSearchParams({ ApiKey: config.token })
  if (source.Id) params.set('mediaSourceId', source.Id)
  if (source.LiveStreamId) params.set('LiveStreamId', source.LiveStreamId)
  if (playSessionId) params.set('PlaySessionId', playSessionId)
  const ext = source.Container ? `.${source.Container.split(',')[0]}` : ''
  return `${config.url}/Audio/${channelId}/stream${ext}?${params}`
}

/**
 * Ask the server to open and describe a Live TV channel's stream.
 *
 * Deliberately separate from playback.ts's resolveStream(): that function's
 * direct-play/transcode branching assumes an ordinary finite Audio/Video item
 * (it reads TranscodingUrl, bakes in a start offset, etc.), none of which
 * applies to a channel - AutoOpenLiveStream is what actually matters here,
 * and the channel's own MediaSource never carries a TranscodingUrl at all
 * (verified against the real server). Reusing resolveStream would have meant
 * bending its branches around a shape they were never meant to describe.
 */
export async function resolveRadioStream(
  client: JellyfinClient,
  config: ServerConfig,
  channelId: string,
  profile: DeviceProfile,
  maxBitrate: number,
): Promise<ResolvedRadioStream> {
  const info = await client.post<RadioPlaybackInfoResponse>(
    `/Items/${channelId}/PlaybackInfo`,
    {
      UserId: config.userId,
      MaxStreamingBitrate: maxBitrate,
      DeviceProfile: { ...profile, MaxStreamingBitrate: maxBitrate },
      AutoOpenLiveStream: true,
    },
    { UserId: config.userId },
  )

  const source = info.MediaSources?.[0]
  if (!source) throw new Error('PlaybackInfo returned no media source for this channel')

  const playSessionId = info.PlaySessionId ?? null
  return {
    url: buildRadioStreamUrl(config, channelId, source, playSessionId),
    playSessionId,
    mediaSourceId: source.Id ?? null,
    liveStreamId: source.LiveStreamId ?? null,
  }
}

/**
 * Release the server-side tuner/ffmpeg session behind a channel.
 *
 * Best-effort and never throws, same reasoning as playback.ts's
 * stopActiveEncoding: a failure here costs the server a lingering process,
 * never correctness on the client, and the caller is always mid-teardown
 * (switching stations, stopping playback) with nothing better to do about it.
 */
export async function closeRadioStream(client: JellyfinClient, liveStreamId: string | null): Promise<void> {
  if (!liveStreamId) return
  try {
    await client.post('/LiveStreams/Close', null, { liveStreamId })
  } catch { /* best effort */ }
}
