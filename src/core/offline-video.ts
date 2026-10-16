// Video downloads (docs/offline-mode-plan.md, section 6): which file to ask
// the server for, what it will do to make it, and whether what arrived is the
// whole film. Pure, shared with main.js (offline.js downloads) and the
// renderer; CascadeKit's OfflineVideo.swift is the same rules, tested against
// the same fixture (test/fixtures/offline-video.json).
//
// Measured on jellyfin12 (12.2) before any of this was written:
// - A progressive transcode in Streaming context is a fragmented MP4
//   (frag_keyframe+empty_moov+delay_moov). Both players seek in it as fast as
//   in an indexed MP4, so it is kept as it arrives. Static context would write
//   a plain MP4 whose header is patched after it was already sent: unusable.
// - It is not throttled (readrate is for HLS only): a remux arrived at network
//   speed, a 720p re-encode at 32x realtime on the server's GPU.
// - It has no Content-Length, so length cannot tell a finished transcode from
//   one that died partway; the last fragment's time can (fragmentedEndSeconds).

import type { DeviceProfile, CodecProfile, SubtitleProfile, TranscodingProfile } from './playback.ts'
import type { JfMediaStream } from './types.ts'

export type VideoQuality = 'original' | '1080p' | '720p'
export const VIDEO_QUALITIES: readonly VideoQuality[] = ['original', '1080p', '720p']

/** A stored setting, read back: anything unknown is the platform default. */
export function parseVideoQuality(stored: unknown, fallback: VideoQuality = 'original'): VideoQuality {
  return VIDEO_QUALITIES.includes(stored as VideoQuality) ? stored as VideoQuality : fallback
}

const QUALITY_HEIGHT: Record<VideoQuality, number | null> = { original: null, '1080p': 1080, '720p': 720 }

/** No bitrate limit of its own: a download is not a stream, and the
 *  streaming cap (or the phone's 20 Mbps) would re-encode most Blu-ray
 *  files at Original. Jellyfin reads it as an int32. */
export const DOWNLOAD_MAX_BITRATE = 400_000_000

/** Formats a <track> or the side-loaded WebVTT can show: the server converts
 *  each to WebVTT, saved beside the file. */
const TEXT_SUBTITLES = ['vtt', 'webvtt', 'srt', 'subrip', 'ass', 'ssa', 'ttml', 'mov_text']
/** Picture subtitles only exist burned into the picture (a re-encode). */
const IMAGE_SUBTITLES = ['pgssub', 'dvdsub', 'dvbsub']

export const DOWNLOAD_SUBTITLE_PROFILES: SubtitleProfile[] = [
  ...TEXT_SUBTITLES.map(Format => ({ Format, Method: 'External' as const })),
  ...IMAGE_SUBTITLES.map(Format => ({ Format, Method: 'Encode' as const })),
]

/**
 * The profile a download is negotiated with: the device's own video
 * direct-play entries (the original file whenever it plays here), and, when
 * it does not, one progressive MP4 the server makes with the video copied
 * where it can be. The quality setting is a height condition with no codec,
 * so it applies to every codec and the server decides: a file at or under
 * the height downloads as is, a taller one is scaled (a re-encode).
 */
export function downloadProfile(device: DeviceProfile, quality: VideoQuality, opts: { audioCodecs: string, maxAudioChannels: string }): DeviceProfile {
  const direct = device.DirectPlayProfiles.filter(p => p.Type === 'Video')
  const codecs = new Set(direct.flatMap(p => (p.VideoCodec ?? '').split(',').map(c => c.trim().toLowerCase())))
  // Only what an MP4 can carry and this device decodes. HEVC only where the
  // device claims it: copying it is what makes the usual MKV a fast remux.
  const VideoCodec = ['h264', 'hevc'].filter(c => c === 'h264' || codecs.has(c)).join(',')
  const transcode: TranscodingProfile = {
    Type: 'Video', Container: 'mp4', VideoCodec, AudioCodec: opts.audioCodecs,
    Protocol: 'http', Context: 'Streaming', MaxAudioChannels: opts.maxAudioChannels,
  }
  const height = QUALITY_HEIGHT[quality]
  const cap: CodecProfile[] = height === null ? [] : [{
    Type: 'Video',
    Conditions: [{ Condition: 'LessThanEqual', Property: 'Height', Value: String(height), IsRequired: true }],
  }]
  return {
    Name: `${device.Name ?? 'Cascade'} Download`,
    MaxStreamingBitrate: DOWNLOAD_MAX_BITRATE,
    DirectPlayProfiles: direct,
    TranscodingProfiles: [transcode],
    ContainerProfiles: [],
    CodecProfiles: [...(device.CodecProfiles ?? []).filter(p => p.Type === 'Video'), ...cap],
    SubtitleProfiles: DOWNLOAD_SUBTITLE_PROFILES,
  }
}

/** The PlaybackInfo request body for a download. `burnIn` is a picture
 *  subtitle's stream index, which the server can only burn in. */
export function downloadPlaybackInfoBody(userId: string, profile: DeviceProfile, burnIn: number | null): Record<string, unknown> {
  return {
    UserId: userId,
    MaxStreamingBitrate: profile.MaxStreamingBitrate,
    DeviceProfile: profile,
    AutoOpenLiveStream: false,
    ...(burnIn !== null ? { SubtitleStreamIndex: burnIn } : {}),
  }
}

/** direct: the original file. remux: the server's MP4 with the video copied
 *  (container or audio changed), close to network speed. reencode: the video
 *  itself is encoded again, which takes real time on the server. */
export type DownloadOutcome = 'direct' | 'remux' | 'reencode'

export interface DownloadSource {
  TranscodingUrl?: string | null
  SupportsDirectPlay?: boolean
  MediaStreams?: (JfMediaStream & { BitRate?: number, BitDepth?: number, Profile?: string })[]
  Size?: number
}

function queryOf(url: string): Map<string, string> {
  const q = new Map<string, string>()
  for (const [k, v] of new URLSearchParams(url.split('?')[1] ?? '')) q.set(k.toLowerCase(), v)
  return q
}

/**
 * What the server will do for this download. TranscodeReasons cannot say it:
 * it explains why direct play failed (an HEVC MKV reads VideoCodecNotSupported
 * on the desktop, whose MKV entry leaves HEVC out), not whether the video is
 * copied. The server copies when the source fits what the URL allows, the
 * same comparison its CanStreamCopyVideo makes, so that is what is compared.
 * Checked against jellyfin12's own ffmpeg command for each fixture case.
 */
export function downloadOutcome(source: DownloadSource): DownloadOutcome {
  const url = source.TranscodingUrl
  if (!url) return 'direct'
  const q = queryOf(url)
  if ((q.get('subtitlemethod') ?? '').toLowerCase() === 'encode') return 'reencode'
  const video = (source.MediaStreams ?? []).find(s => s.Type === 'Video')
  if (!video) return 'remux'
  const codec = (video.Codec ?? '').toLowerCase()
  const allowed = (q.get('videocodec') ?? '').toLowerCase().split(',').map(c => c.trim())
  if (!allowed.includes(codec)) return 'reencode'
  const over = (key: string, value: number | undefined) => {
    const limit = Number(q.get(key))
    return q.has(key) && Number.isFinite(limit) && value !== undefined && value > limit
  }
  if (over('maxheight', video.Height) || over('maxwidth', video.Width) || over('videobitrate', video.BitRate)) return 'reencode'
  if (over(`${codec}-videobitdepth`, video.BitDepth)) return 'reencode'
  const profiles = q.get(`${codec}-profile`)
  if (profiles && video.Profile && !profiles.toLowerCase().split(/[,|]/).includes(video.Profile.toLowerCase())) return 'reencode'
  return 'remux'
}

/** Played this far, a video counts as watched: Jellyfin's own default
 *  (MaxResumePct 90), so the end credits or a skipped outro still count. */
export const WATCHED_RATIO = 0.9

export function isWatchedPosition(positionTicks: number, runTimeTicks: number | undefined): boolean {
  return !!runTimeTicks && runTimeTicks > 0 && positionTicks >= runTimeTicks * WATCHED_RATIO
}

/** What the person is told a download is doing. */
export function outcomeLabel(outcome: DownloadOutcome): string {
  return outcome === 'reencode' ? 'Converting on the server' : outcome === 'remux' ? 'Downloading (repackaged by the server)' : 'Downloading'
}

/** Roughly how big the file will be, for a progress bar and an estimate when
 *  the server sends no length: the source's size for the original or a remux,
 *  the requested bitrates times the runtime for a re-encode. Null when there
 *  is nothing to go on. */
export function estimatedBytes(outcome: DownloadOutcome, source: DownloadSource, runTimeTicks: number | undefined): number | null {
  if (outcome !== 'reencode') return source.Size && source.Size > 0 ? source.Size : null
  if (!source.TranscodingUrl || !runTimeTicks) return null
  const q = queryOf(source.TranscodingUrl)
  const bps = (Number(q.get('videobitrate')) || 0) + (Number(q.get('audiobitrate')) || 0)
  return bps > 0 ? Math.round(bps / 8 * runTimeTicks / 10_000_000) : null
}

/** Seconds left at the current rate, or null when it cannot be guessed. */
export function secondsLeft(received: number, estimate: number | null, bytesPerSecond: number): number | null {
  if (!estimate || bytesPerSecond <= 0 || received >= estimate) return null
  return Math.round((estimate - received) / bytesPerSecond)
}

// ── Is the whole film there? ──────────────────────────────────────────────────

/** Reads `length` bytes at `offset` (fewer at the end of the file). */
export type ByteReader = (offset: number, length: number) => Uint8Array

const u32 = (b: Uint8Array, i: number) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3]
const u64 = (b: Uint8Array, i: number) => u32(b, i) * 4294967296 + u32(b, i + 4)
const type = (b: Uint8Array, i: number) => String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3])

/** Boxes directly inside `b[start, end)`: [type, payload start, box end]. */
function children(b: Uint8Array, start: number, end: number): [string, number, number][] {
  const out: [string, number, number][] = []
  let i = start
  while (i + 8 <= end) {
    let size = u32(b, i)
    let header = 8
    if (size === 1 && i + 16 <= end) { size = u64(b, i + 8); header = 16 }
    if (size < header || i + size > end) break
    out.push([type(b, i + 4), i + header, i + size])
    i += size
  }
  return out
}

/** Every whole top-level box's [type, offset, size], reading headers only.
 *  A box that runs past the end of the file was cut off and ends the list. */
function topLevel(read: ByteReader, fileSize: number): [string, number, number][] {
  const out: [string, number, number][] = []
  let i = 0
  while (i + 8 <= fileSize) {
    const h = read(i, 16)
    if (h.length < 8) break
    let size = u32(h, 0)
    if (size === 1 && h.length >= 16) size = u64(h, 8)
    else if (size === 0) size = fileSize - i
    if (size < 8 || i + size > fileSize) break
    out.push([type(h, 4), i, size])
    i += size
  }
  return out
}

/**
 * Where a fragmented MP4's last fragment ends, in seconds, or null when the
 * file is not one (no moov with timescales, or no fragment). A transcode cut
 * off partway is still a valid file up to its last whole fragment, and reads
 * as that much shorter: a 674 s episode truncated read as 395 s in both
 * AVFoundation and ffprobe. Only box headers and the small moov and moof
 * boxes are read, never the media.
 */
export function fragmentedEndSeconds(read: ByteReader, fileSize: number): number | null {
  const boxes = topLevel(read, fileSize)
  const moovBox = boxes.find(b => b[0] === 'moov')
  // A fragment counts once its samples (the mdat after it) are all there.
  const moofs = boxes.filter((b, i) => b[0] === 'moof' && boxes[i + 1]?.[0] === 'mdat')
  if (!moovBox || !moofs.length) return null
  const moov = read(moovBox[1], moovBox[2])
  const timescale = new Map<number, number>()
  const defaultDuration = new Map<number, number>()
  for (const [t, s, e] of children(moov, 8, moov.length)) {
    if (t === 'trak') {
      let id = 0, scale = 0
      for (const [tt, ts, te] of children(moov, s, e)) {
        if (tt === 'tkhd') id = moov[ts] === 1 ? u32(moov, ts + 20) : u32(moov, ts + 12)
        if (tt === 'mdia') for (const [mt, ms] of children(moov, ts, te)) {
          if (mt === 'mdhd') scale = moov[ms] === 1 ? u32(moov, ms + 20) : u32(moov, ms + 12)
        }
      }
      if (id && scale) timescale.set(id, scale)
    }
    if (t === 'mvex') for (const [xt, xs] of children(moov, s, e)) {
      if (xt === 'trex') defaultDuration.set(u32(moov, xs + 4), u32(moov, xs + 12))
    }
  }
  const [, off, size] = moofs[moofs.length - 1]
  const moof = read(off, size)
  let end: number | null = null
  for (const [t, s, e] of children(moof, 8, moof.length)) {
    if (t !== 'traf') continue
    let track = 0, base = 0, dflt = 0, total = 0
    for (const [ft, fs] of children(moof, s, e)) {
      if (ft === 'tfhd') {
        const flags = u32(moof, fs) & 0xffffff
        track = u32(moof, fs + 4)
        dflt = defaultDuration.get(track) ?? 0
        let p = fs + 8
        if (flags & 0x01) p += 8
        if (flags & 0x02) p += 4
        if (flags & 0x08) dflt = u32(moof, p)
      } else if (ft === 'tfdt') {
        base = moof[fs] === 1 ? u64(moof, fs + 4) : u32(moof, fs + 4)
      } else if (ft === 'trun') {
        const flags = u32(moof, fs) & 0xffffff
        const count = u32(moof, fs + 4)
        let p = fs + 8 + (flags & 0x01 ? 4 : 0) + (flags & 0x04 ? 4 : 0)
        const per = [0x100, 0x200, 0x400, 0x800].filter(f => flags & f).length * 4
        if (flags & 0x100) for (let i = 0; i < count; i++, p += per) total += u32(moof, p)
        else total += count * dflt
      }
    }
    const scale = timescale.get(track)
    if (scale) end = Math.max(end ?? 0, (base + total) / scale)
  }
  return end
}

/** How far short of the runtime a transcode may end and still be whole: a
 *  container's length and the server's RunTimeTicks differ by a frame or a
 *  last fragment, never by this much. */
export const TRUNCATION_TOLERANCE_SECONDS = 15

/** Whether a transcode that ended at `endSeconds` holds the whole item.
 *  An unknown runtime is not judged here. */
export function isWholeTranscode(endSeconds: number | null, runTimeTicks: number | undefined): boolean {
  if (!runTimeTicks) return true
  // A progressive transcode is always fragmented (see the top of this file):
  // no fragment at all is a stream cut off before its first one.
  if (endSeconds === null) return false
  return endSeconds >= runTimeTicks / 10_000_000 - TRUNCATION_TOLERANCE_SECONDS
}
