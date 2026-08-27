// Stream resolution via Jellyfin's PlaybackInfo negotiation.
//
// Replaces the old hardcoded /universal URL. The point is that the *client*
// declares what it can decode (a DeviceProfile) and the server decides between
// direct play and transcoding - so a TV client with different codec support
// gets a stream it can actually play. See profiles/PLATFORM-NOTES.md.

import type { JellyfinClient } from './jellyfin.ts'
import type { JfItem, JfMediaStream, ServerConfig } from './types.ts'

/** Which family of Jellyfin stream endpoints an item uses. Movies and episodes
 *  are both 'Video'; everything Cascade played before B2 is 'Audio'. */
export type MediaKind = 'Audio' | 'Video'

export interface DirectPlayProfile {
  Type: MediaKind
  /** Comma-separated container list, e.g. "mp3,flac". */
  Container: string
  AudioCodec?: string
  /** Video only. Comma-separated, e.g. "h264,vp9". */
  VideoCodec?: string
}

export interface TranscodingProfile {
  Type: MediaKind
  Container: string
  AudioCodec: string
  Protocol: string
  Context?: string
  MaxAudioChannels?: string
  /** Video only. */
  VideoCodec?: string
}

/** One clause of a CodecProfile, in Jellyfin's condition vocabulary. */
export interface CodecCondition {
  Condition: 'Equals' | 'EqualsAny' | 'LessThanEqual' | 'GreaterThanEqual' | 'NotEquals'
  Property: string
  Value: string
  /** false lets the server relax the clause rather than reject the codec outright. */
  IsRequired?: boolean
}

/**
 * Limits on a codec the client otherwise supports.
 *
 * This is the difference between "can decode HEVC" and "can decode *this* HEVC",
 * and leaving it empty is not neutral - without it the server assumes the worst
 * about anything unusual (10-bit, in practice) and re-encodes a stream it could
 * have copied.
 */
export interface CodecProfile {
  Type: MediaKind
  Codec: string
  Conditions: CodecCondition[]
}

export interface SubtitleProfile {
  Format: string
  /** 'External' = we fetch and render it ourselves (a native <track>).
   *  'Encode' = the server must burn it into the video. */
  Method: 'External' | 'Embed' | 'Encode' | 'Hls'
}

export interface DeviceProfile {
  Name?: string
  MaxStreamingBitrate?: number
  DirectPlayProfiles: DirectPlayProfile[]
  TranscodingProfiles: TranscodingProfile[]
  ContainerProfiles?: unknown[]
  CodecProfiles?: CodecProfile[]
  SubtitleProfiles?: SubtitleProfile[]
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

/**
 * Put a start offset on a transcoding URL.
 *
 * A progressive transcode is a plain HTTP body the server encodes as it sends,
 * so the element only ever knows about the part that has arrived - seeking past
 * it is not possible client-side. Jellyfin's answer is to ask for a *new* stream
 * that begins at the offset, which is why seeking a transcode costs a request
 * rather than a currentTime assignment.
 *
 * Exported because seeking should not go back through PlaybackInfo: the URL the
 * first resolve handed over is still valid, and re-negotiating just to change a
 * number puts a whole extra round trip in front of every scrub.
 */
export function withStartTicks(url: string, ticks: number): string {
  if (ticks <= 0) return url
  const [base, query = ''] = url.split('?')
  const params = new URLSearchParams(query)
  params.set('StartTimeTicks', String(Math.round(ticks)))
  return `${base}?${params}`
}

/**
 * The parts of a stream request that are not "which item, how big".
 *
 * A bag rather than more positional parameters: resolveStream already takes six,
 * and `resolveStream(c, cfg, id, p, rate, 'Video', 0, 3)` says nothing about
 * what the 0 and the 3 are.
 */
export interface StreamOptions {
  /** Start the stream this far into the item. Only a transcode can honour it;
   *  direct play returns the whole file and seeks locally. */
  startTicks?: number
  /**
   * Which audio track to play, as a MediaStreams index. null leaves it to the
   * server.
   *
   * ponytail: this forces a transcode in practice, and that is not a bug to fix
   * later. HTML5 has no way to select between the audio tracks inside one file -
   * Chromium exposes no audioTracks - so the only way to hear the commentary is
   * to have the server mux a file that has it first.
   */
  audioStreamIndex?: number | null
}

export interface ResolvedStream {
  url: string
  /** Needed so playback reporting ties to the right server-side session. */
  playSessionId: string | null
  mediaSourceId: string | null
  /** false when the server chose to transcode. */
  direct: boolean
  /**
   * Where this stream begins, in ticks. Non-zero only for a transcode that was
   * asked to start partway in, because that is the one case where the element's
   * own currentTime is measured from somewhere other than the start of the item.
   * Add it to currentTime to get a real position.
   */
  startTicks: number
}

/** Matches the old hardcoded URL, and the Electron profile default. */
export const DEFAULT_MAX_BITRATE = 140_000_000

/** Past this fraction of the runtime, an item counts as finished rather than
 *  in-progress. Jellyfin keeps a position on things you watched to the end, and
 *  resuming 90 seconds before the credits is nobody's intent. */
export const RESUME_COMPLETE_RATIO = 0.95

/**
 * Where playback should pick up, in ticks. 0 means "start from the beginning".
 *
 * Jellyfin fills UserData.PlaybackPositionTicks from the PositionTicks we
 * already report, so this needs no extra bookkeeping - only the judgement about
 * when a stored position is worth honouring.
 */
export function resumeTicks(item: JfItem | null | undefined): number {
  const ticks = item?.UserData?.PlaybackPositionTicks || 0
  if (ticks <= 0) return 0
  // Explicitly watched: the position is a leftover, not an intent to resume.
  if (item?.UserData?.Played) return 0
  const total = item?.RunTimeTicks || 0
  if (total && ticks > total * RESUME_COMPLETE_RATIO) return 0
  return ticks
}

/**
 * The pre-B1 stream URL, kept as a fallback.
 *
 * If PlaybackInfo fails (older server, network blip, unexpected shape) this
 * still plays audio. `/universal` makes the server guess, which is exactly what
 * Cascade did before - acceptable as a degraded path, not as the default.
 *
 * There is no video equivalent of `/universal`: for video the degraded path is
 * `/Videos/{id}/stream?static=true`, which asks the server for the file as-is.
 * That direct-plays or fails outright - it never transcodes - which is the
 * right trade for a fallback nobody should normally hit.
 */
export function universalStreamUrl(
  config: ServerConfig,
  itemId: string,
  maxBitrate: number = DEFAULT_MAX_BITRATE,
  kind: MediaKind = 'Audio',
): string {
  const { url, userId, token } = config
  if (kind === 'Video') {
    return `${url}/Videos/${itemId}/stream?static=true&api_key=${token}`
  }
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
/**
 * Tell the server to stop transcoding for a play session.
 *
 * Abandoning a transcode is not free and the server will not always notice.
 * Pointing the element at a new offset leaves the previous ffmpeg running - and
 * with throttling off it keeps encoding at full speed for a file nobody is
 * watching. A few scrubs is a few encoders competing for the same cores, which
 * looks exactly like "transcoding got slow" while being self-inflicted.
 *
 * Best effort: a failure here costs CPU on the server, never correctness on the
 * client, so it never throws and is never awaited on a path the user is waiting
 * behind.
 */
export async function stopActiveEncoding(
  client: JellyfinClient,
  config: ServerConfig,
  playSessionId: string | null,
): Promise<void> {
  if (!playSessionId || !config.deviceId) return
  await client.del('/Videos/ActiveEncodings', {
    deviceId: config.deviceId,
    playSessionId,
  })
}

/**
 * Which audio stream to explicitly request, given the item's own tracks and
 * the codecs this client can actually decode - or null if nothing needs to be
 * forced.
 *
 * Direct play hands over the raw file with every audio stream still inside it;
 * the server's compatibility check only has to find ONE decodable stream
 * somewhere in the file to call the whole thing direct-playable, but an HTML5
 * <video> cannot pick between embedded audio tracks (see StreamOptions.
 * audioStreamIndex) - it just decodes whichever one the container itself
 * flags as default. When those two are different streams, the server thinks
 * direct play is fine, the video plays, and the audio the browser actually
 * tried to decode is a codec it does not have - silent, no error.
 *
 * A single-track item has no such gap: whatever the server picks and whatever
 * the container flags as default are the same stream. Multi-track items are
 * mostly a movie thing (a Blu-ray rip's default track is often TrueHD/DTS,
 * with a compatible commentary or stereo track lower in the list) - episodes
 * are almost always one track - which is why this shows up as "movies have no
 * sound, TV is fine" rather than anything codec-profile tuning alone fixes.
 */
export function neededAudioStreamIndex(
  streams: JfMediaStream[] | undefined,
  decodableCodecs: string[],
): number | null {
  const audio = (streams || []).filter(s => s.Type === 'Audio')
  if (audio.length <= 1) return null

  const decodable = new Set(decodableCodecs.map(c => c.toLowerCase()))
  const effectiveDefault = audio.find(s => s.IsDefault) ?? audio[0]
  if (decodable.has((effectiveDefault.Codec || '').toLowerCase())) return null

  const fallback = audio.find(s => decodable.has((s.Codec || '').toLowerCase()))
  return fallback?.Index ?? null
}

export async function resolveStream(
  client: JellyfinClient,
  config: ServerConfig,
  itemId: string,
  profile: DeviceProfile,
  maxBitrate: number = DEFAULT_MAX_BITRATE,
  kind: MediaKind = 'Audio',
  opts: StreamOptions = {},
): Promise<ResolvedStream> {
  const startTicks = opts.startTicks ?? 0
  const audioStreamIndex = opts.audioStreamIndex ?? null

  try {
    const info = await client.post<PlaybackInfoResponse>(
      `/Items/${itemId}/PlaybackInfo`,
      {
        UserId: config.userId,
        MaxStreamingBitrate: maxBitrate,
        DeviceProfile: { ...profile, MaxStreamingBitrate: maxBitrate },
        AutoOpenLiveStream: true,
        // Sent rather than omitted-when-default so the server decides whether
        // the requested track is reachable by direct play. It usually is not,
        // and that transcode is the point - see StreamOptions.
        ...(audioStreamIndex != null ? { AudioStreamIndex: audioStreamIndex } : {}),
      },
      { UserId: config.userId },
    )

    const source = info.MediaSources?.[0]
    if (!source) throw new Error('PlaybackInfo returned no media source')

    const playSessionId = info.PlaySessionId ?? null

    if (source.TranscodingUrl) {
      return {
        url: withStartTicks(`${config.url}${source.TranscodingUrl}`, startTicks),
        // TranscodingUrl already carries the audio index the server settled on,
        // so nothing is appended here.
        playSessionId,
        mediaSourceId: source.Id ?? null,
        direct: false,
        startTicks,
      }
    }

    // Direct play hands over the whole file, so the element can seek inside it
    // on its own and the offset is never baked into the URL.
    return {
      url: directStreamUrl(config, itemId, source, playSessionId, kind),
      playSessionId,
      mediaSourceId: source.Id ?? null,
      direct: true,
      startTicks: 0,
    }
  } catch {
    return {
      url: universalStreamUrl(config, itemId, maxBitrate, kind),
      playSessionId: null,
      mediaSourceId: null,
      direct: false,
      startTicks: 0,
    }
  }
}

function directStreamUrl(
  config: ServerConfig,
  itemId: string,
  source: MediaSource,
  playSessionId: string | null,
  kind: MediaKind,
): string {
  const params = new URLSearchParams({ static: 'true', api_key: config.token })
  if (source.Id) params.set('mediaSourceId', source.Id)
  if (playSessionId) params.set('PlaySessionId', playSessionId)

  // The container extension matters: without it some servers re-probe the file
  // on every request.
  const ext = source.Container ? `.${source.Container.split(',')[0]}` : ''

  // Jellyfin splits its stream endpoints by media kind, and the plural is not a
  // typo on their side: audio is /Audio/{id}, video is /Videos/{id}.
  const base = kind === 'Video' ? 'Videos' : 'Audio'
  return `${config.url}/${base}/${itemId}/stream${ext}?${params}`
}

/**
 * The same profile with `drop` removed from every video direct-play entry's
 * audio codec list.
 *
 * For a codec the client CLAIMED it could decode and then demonstrably could
 * not. canPlayType is a promise, not a guarantee: it answers from a codec
 * registry, not from a decoder that has actually run, and a claim it gets wrong
 * is silent - the container demuxes, the picture plays, and the audio decoder
 * produces nothing at all. Withdrawing the claim makes the next negotiation
 * transcode instead of direct playing into silence.
 *
 * Video entries only. The audio path plays single-stream music files whose
 * codec the server picked against this same list, and it is not where this
 * failure happens.
 */
export function withoutAudioCodecs(profile: DeviceProfile, drop: string[]): DeviceProfile {
  if (!drop.length) return profile
  const dropped = new Set(drop.map(c => c.toLowerCase()))
  return {
    ...profile,
    DirectPlayProfiles: profile.DirectPlayProfiles.map(p => {
      if (p.Type !== 'Video' || !p.AudioCodec) return p
      const kept = p.AudioCodec.split(',').filter(c => !dropped.has(c.trim().toLowerCase()))
      return { ...p, AudioCodec: kept.join(',') }
    }),
  }
}
