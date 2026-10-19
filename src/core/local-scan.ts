// Local mode's rules (docs/local-mode-plan.md): a folder on this computer read
// as a library. Pure, so what decides an id, whether a file is a song, a movie
// or an episode, and what this machine can play is tested here; local-library.js
// (main process) walks the folder, reads the tags and owns the files.
//
// The output is the Offline Mode catalog (offline-index.ts), the same value a
// download builds, so offline-query.ts answers every screen from it unchanged.
// Each file's catalog path is a made-up "media/<id>.<ext>": the real path stays
// in the main process, which is the only side that may resolve it.

import { createHash } from 'node:crypto'
import type { JfItem, JfMediaStream, JfNameId } from './types.ts'
import type { DeviceProfile } from './playback.ts'
import { ELECTRON_PROFILE } from './profiles/electron.ts'
import type { LocalUserData } from './local-user-data.ts'
// The main process reads one bundle (build/local-scan.js), so the user data
// rules the renderer shares come along.
export { applyLocalChange, parseLocalChange, parseUserData, setLocalUserData, type LocalChange, type LocalUserData } from './local-user-data.ts'
import {
  type OfflineIndex, type OfflineSubtitle, emptyIndex, addCollection, markReady, setLibraries, setSubtitles, setUser, isSafeId,
} from './offline-index.ts'

// ── Ids ──────────────────────────────────────────────────────────────────────

/** Names compare without case, outer space or doubled spaces, in one Unicode
 *  form (macOS hands back file names decomposed). */
export const normName = (s: string): string => s.normalize('NFC').trim().replace(/\s+/g, ' ').toLowerCase()

/** A path relative to the library root, with forward slashes, in NFC. */
export const normRel = (rel: string): string => rel.normalize('NFC').replace(/\\/g, '/').replace(/^\/+/, '')

/** 32 hex characters, which isSafeId accepts and Jellyfin's own ids look like.
 *  `kind` keeps an artist and a genre of the same name apart. */
function hashId(kind: string, seed: string): string {
  return createHash('sha1').update(`${kind}:${seed}`).digest('hex').slice(0, 32)
}

// ponytail: an id is the file's path, so moving or renaming a file loses its
// plays and favorites. Key on an audio fingerprint if that bites.
export const fileId = (rel: string): string => hashId('file', normRel(rel))
export const albumId = (albumArtist: string, album: string): string => hashId('album', `${normName(albumArtist)}\u0000${normName(album)}`)
export const artistId = (name: string): string => hashId('artist', normName(name))
export const genreId = (name: string): string => hashId('genre', normName(name))
export const seriesId = (name: string): string => hashId('series', normName(name))
export const seasonId = (series: string, season: number): string => hashId('season', `${normName(series)}\u0000${season}`)
export const playlistFileId = (rel: string): string => hashId('m3u', normRel(rel))

/** The library views Local mode lists, each only while it holds something. */
export const LOCAL_LIBRARIES = {
  music: { Id: 'cascade-local-music', Name: 'Music', CollectionType: 'music' },
  movies: { Id: 'cascade-local-movies', Name: 'Movies', CollectionType: 'movies' },
  tvshows: { Id: 'cascade-local-shows', Name: 'TV Shows', CollectionType: 'tvshows' },
} as const

/** The user Local mode signs in as: there is nobody else. */
export const LOCAL_USER_ID = 'local'

// ── What a file is ───────────────────────────────────────────────────────────

const AUDIO_EXTS = new Set(['mp3', 'flac', 'm4a', 'm4b', 'aac', 'ogg', 'oga', 'opus', 'wav', 'wma', 'aif', 'aiff', 'ape', 'wv', 'dsf', 'dff', 'mpc', 'alac'])
const VIDEO_EXTS = new Set(['avi', 'ts', 'm2ts', 'mts', 'mpg', 'mpeg', 'wmv', 'ogv', 'flv', '3gp'])
/** A container that holds music or film: the file's own streams decide. */
const AMBIGUOUS_EXTS = new Set(['mp4', 'm4v', 'webm', 'mkv', 'mka', 'mov'])
/** What an ambiguous container is taken for when its streams could not be read. */
const AMBIGUOUS_DEFAULT: Record<string, 'audio' | 'video'> = { mp4: 'video', m4v: 'video', webm: 'video', mkv: 'video', mka: 'audio', mov: 'video' }

export const extOf = (rel: string): string => {
  const name = rel.slice(rel.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ''
}

const baseOf = (rel: string): string => {
  const name = rel.slice(rel.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(0, dot) : name
}

const dirOf = (rel: string): string => {
  const i = rel.lastIndexOf('/')
  return i < 0 ? '' : rel.slice(0, i)
}

/** Whether the scanner should read a file as media, and what its extension
 *  alone says it is. */
export function kindByExtension(rel: string): 'audio' | 'video' | 'ambiguous' | null {
  const ext = extOf(rel)
  if (AUDIO_EXTS.has(ext)) return 'audio'
  if (VIDEO_EXTS.has(ext)) return 'video'
  if (AMBIGUOUS_EXTS.has(ext)) return 'ambiguous'
  return null
}

/** Files the scanner keeps beside the media: lyrics, subtitles, art, playlists. */
export function isSidecar(rel: string): boolean {
  return ['lrc', 'elrc', 'srt', 'vtt', 'jpg', 'jpeg', 'png', 'webp', 'm3u', 'm3u8'].includes(extOf(rel))
}

/** Song or film, from the extension, then the file's own streams. */
export function classify(rel: string, probe: LocalProbe | null): 'audio' | 'video' | null {
  const byExt = kindByExtension(rel)
  if (byExt !== 'ambiguous') return byExt
  if (probe && typeof probe.hasVideo === 'boolean') return probe.hasVideo ? 'video' : 'audio'
  return AMBIGUOUS_DEFAULT[extOf(rel)] ?? null
}

// ── What the tag reader found ────────────────────────────────────────────────

/** One file's tags and streams. Kept in the scan cache, so read back through
 *  parseProbe, never trusted. */
export interface LocalProbe {
  title?: string
  artists?: string[]
  albumArtist?: string
  album?: string
  track?: number
  disc?: number
  year?: number
  genres?: string[]
  durationSec?: number
  /** ReplayGain, in dB. */
  trackGainDb?: number
  albumGainDb?: number
  hasVideo?: boolean
  /** Jellyfin's codec names (codecName below). */
  videoCodec?: string
  audioCodec?: string
  width?: number
  height?: number
  channels?: number
  /** A picture is embedded, so an album with no cover file can use it. */
  embeddedArt?: boolean
}

const PROBE_STRINGS = ['title', 'albumArtist', 'album', 'videoCodec', 'audioCodec'] as const
const PROBE_NUMBERS = ['track', 'disc', 'year', 'durationSec', 'trackGainDb', 'albumGainDb', 'width', 'height', 'channels'] as const

const isPlainObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)
const cleanText = (v: unknown, max = 500): string | undefined => {
  if (typeof v !== 'string') return undefined
  const s = v.replace(/[\u0000-\u001f]/g, ' ').trim()
  return s ? s.slice(0, max) : undefined
}
const cleanList = (v: unknown): string[] | undefined => {
  if (!Array.isArray(v)) return undefined
  const out: string[] = []
  for (const x of v) {
    const s = cleanText(x)
    if (s && !out.some(o => normName(o) === normName(s))) out.push(s)
    if (out.length >= 50) break
  }
  return out.length ? out : undefined
}

/** A stored probe, checked field by field. */
export function parseProbe(raw: unknown): LocalProbe | null {
  if (!isPlainObject(raw)) return null
  const out: LocalProbe = {}
  for (const k of PROBE_STRINGS) { const s = cleanText(raw[k]); if (s) out[k] = s }
  for (const k of PROBE_NUMBERS) if (finite(raw[k])) out[k] = raw[k] as number
  const artists = cleanList(raw.artists)
  if (artists) out.artists = artists
  const genres = cleanList(raw.genres)
  if (genres) out.genres = genres
  if (typeof raw.hasVideo === 'boolean') out.hasVideo = raw.hasVideo
  if (raw.embeddedArt === true) out.embeddedArt = true
  return out
}

/**
 * Jellyfin's name for a codec, from what a tag reader calls it: Matroska codec
 * ids (V_MPEG4/ISO/AVC), MP4 sample entries (avc1, hvc1, mp4a) or display
 * names (MPEG-4/AAC, MPEG 1 Layer 3). Undefined when it is not one Cascade
 * knows, which never counts as playable.
 */
export function codecName(raw: unknown): string | undefined {
  if (typeof raw !== 'string') return undefined
  const s = raw.trim().toLowerCase().replace(/^<|>$/g, '')
  if (!s) return undefined
  const table: [RegExp, string][] = [
    [/^(avc[1-4]|h\.?264|v_mpeg4\/iso\/avc|mpeg4\/iso\/avc)/, 'h264'],
    [/^(hvc1|hev1|h\.?265|hevc|v_mpegh\/iso\/hevc|mpegh\/iso\/hevc)/, 'hevc'],
    [/^(vp08|v_vp8|vp8)/, 'vp8'],
    [/^(vp09|v_vp9|vp9)/, 'vp9'],
    [/^(av01|v_av1|av1)/, 'av1'],
    [/^(v_mpeg2|mp2v|mpeg-?2 video|mpeg2video)/, 'mpeg2video'],
    [/^(mp4v|v_mpeg4\/iso\/(asp|sp|ap)|xvid|divx)/, 'mpeg4'],
    [/^(wvc1|v_ms\/vfw\/wvc1|vc-?1)/, 'vc1'],
    [/^(v_theora|theora)/, 'theora'],
    [/^(a_aac|mp4a|mpeg-4\/aac|aac)/, 'aac'],
    [/^(a_mpeg\/l3|\.mp3|mpeg [12](\.5)? layer 3|mp3)/, 'mp3'],
    [/^(a_mpeg\/l2|mpeg [12] layer 2|mp2)/, 'mp2'],
    [/^(a_flac|flac)/, 'flac'],
    [/^(a_opus|opus)/, 'opus'],
    [/^(a_vorbis|vorbis)/, 'vorbis'],
    [/^(a_eac3|ec-3|e-ac-?3|eac3)/, 'eac3'],
    [/^(a_ac3|ac-3|ac3)/, 'ac3'],
    [/^(a_dts|dts)/, 'dts'],
    [/^(a_truehd|mlpa|truehd)/, 'truehd'],
    [/^(alac)/, 'alac'],
    [/^(a_pcm|pcm|lpcm|sowt|twos|ipcm)/, 'pcm'],
    [/^(wma|windows media audio)/, 'wma'],
  ]
  for (const [re, name] of table) if (re.test(s)) return name
  return undefined
}

/** Picks one value per field from what music-metadata hands back
 *  (IAudioMetadata: { format, common }), shaped as a stored probe. */
export function probeFromMetadata(meta: unknown): LocalProbe | null {
  if (!isPlainObject(meta)) return null
  const format = isPlainObject(meta.format) ? meta.format : {}
  const common = isPlainObject(meta.common) ? meta.common : {}
  const tracks = Array.isArray(format.trackInfo) ? format.trackInfo.filter(isPlainObject) : []
  // music-metadata's track types follow Matroska: 1 video, 2 audio.
  const video = tracks.find(t => t.type === 1 || isPlainObject(t.video))
  const audioTracks = tracks.filter(t => t.type === 2 || isPlainObject(t.audio))
  // Chromium plays the default audio track, and the first when none is marked.
  const audio = audioTracks.find(t => t.flagDefault === true) ?? audioTracks[0]
  const codecOf = (t: Record<string, unknown> | undefined) => t ? codecName(t.codecName) ?? codecName(t.codecId) : undefined
  const gain = (v: unknown) => isPlainObject(v) && finite(v.dB) ? v.dB : undefined
  const genres = Array.isArray(common.genre) ? common.genre.flatMap(g => typeof g === 'string' ? g.split(/\s*[;|/]\s*/) : []) : []
  const raw: Record<string, unknown> = {
    title: common.title,
    artists: Array.isArray(common.artists) ? common.artists : typeof common.artist === 'string' ? [common.artist] : undefined,
    albumArtist: common.albumartist,
    album: common.album,
    track: isPlainObject(common.track) ? common.track.no : undefined,
    disc: isPlainObject(common.disk) ? common.disk.no : undefined,
    year: common.year,
    genres,
    durationSec: format.duration,
    trackGainDb: gain(common.replaygain_track_gain),
    albumGainDb: gain(common.replaygain_album_gain),
    hasVideo: typeof format.hasVideo === 'boolean' ? format.hasVideo : !!video,
    videoCodec: codecOf(video),
    // A plain audio file has no track list for some formats: its codec is the format's.
    audioCodec: codecOf(audio) ?? (video ? undefined : codecName(format.codec)),
    width: isPlainObject(video?.video) ? (video.video.displayWidth ?? video.video.pixelWidth) : undefined,
    height: isPlainObject(video?.video) ? (video.video.displayHeight ?? video.video.pixelHeight) : undefined,
    channels: isPlainObject(audio?.audio) ? audio.audio.channels : format.numberOfChannels,
    embeddedArt: Array.isArray(common.picture) && common.picture.length > 0,
  }
  if (!(finite(raw.track) && raw.track > 0)) delete raw.track
  if (!(finite(raw.disc) && raw.disc > 0)) delete raw.disc
  if (!(finite(raw.year) && raw.year > 0)) delete raw.year
  if (!(finite(raw.durationSec) && raw.durationSec > 0)) delete raw.durationSec
  return parseProbe(raw)
}

// ── Can this machine play it ─────────────────────────────────────────────────

/** The container a direct-play profile names a file by. */
export function containerOf(rel: string): string {
  const ext = extOf(rel)
  return ({ m4v: 'mp4', m4b: 'm4a', oga: 'ogg', mpeg: 'mpg', mts: 'm2ts' } as Record<string, string>)[ext] ?? ext
}

const listHas = (list: string | undefined, v: string) => (list ?? '').split(',').map(s => s.trim().toLowerCase()).includes(v)

/**
 * Whether the device profile says Chromium plays this file as it is, and if
 * not, what to tell the person. Without ffmpeg nothing is converted, so a file
 * the profile does not cover would sit at readyState 0 with no error: it is
 * listed instead of indexed (plan, section 7).
 */
export function playability(profile: DeviceProfile, kind: 'audio' | 'video', rel: string, probe: LocalProbe | null):
  { ok: true } | { ok: false; reason: string } {
  const container = containerOf(rel)
  const type = kind === 'audio' ? 'Audio' : 'Video'
  const entries = profile.DirectPlayProfiles.filter(p => p.Type === type && listHas(p.Container, container))
  if (!entries.length) return { ok: false, reason: `Cascade can't play .${extOf(rel)} files without ffmpeg.` }
  const audioCodec = probe?.audioCodec
  const videoCodec = probe?.videoCodec
  if (kind === 'video') {
    if (!videoCodec) return { ok: false, reason: probe ? "Cascade couldn't tell this video's format." : "Cascade couldn't read this file." }
    const fits = entries.some(p => listHas(p.VideoCodec, videoCodec) && (!audioCodec || !p.AudioCodec || listHas(p.AudioCodec, audioCodec)))
    if (fits) return { ok: true }
    if (!entries.some(p => listHas(p.VideoCodec, videoCodec))) return { ok: false, reason: `${videoCodec.toUpperCase()} video in .${extOf(rel)} needs ffmpeg here.` }
    return { ok: false, reason: `Its ${(audioCodec ?? '').toUpperCase()} sound needs ffmpeg here.` }
  }
  // Audio: an entry with no codec list takes any codec its container holds.
  if (entries.some(p => !p.AudioCodec)) return { ok: true }
  if (audioCodec && entries.some(p => listHas(p.AudioCodec, audioCodec))) return { ok: true }
  return { ok: false, reason: audioCodec ? `${audioCodec.toUpperCase()} audio needs ffmpeg here.` : "Cascade couldn't tell this file's audio format." }
}

// ── Names ────────────────────────────────────────────────────────────────────

/** Release details a scene-style name carries after the title. */
const RELEASE_TAG = /[\s._[(-](?:2160p|1080p|720p|576p|480p|4k|uhd|web-?dl|web-?rip|webrip|hdtv|blu-?ray|bdrip|brrip|dvdrip|hdrip|remux|x26[45]|h\.?26[45]|hevc|avc|10bit|aac|ac3|dts|proper|repack|extended|unrated)(?=$|[\s._\])-])/i

/** A scene-style name ("The.Matrix.1080p") as words, release tags dropped.
 *  Names with spaces keep their dots ("Mr. Robot"). */
const words = (x: string): string => (x.includes(' ') ? x : x.replace(/[._]+/g, ' ')).replace(/\s+/g, ' ').replace(/[\s-]+$/, '').trim()
const cleanName = (s: string): string => {
  // Padded, so text that is all tags ("720p.WEB" after an episode number)
  // comes to nothing; the match sits one character later in the padding.
  const tag = RELEASE_TAG.exec(` ${s}`)
  return words(tag ? s.slice(0, Math.max(0, tag.index - 1)) : s)
}

/** "Name (2010)", "Name [2010]", "Name.2010.1080p": the name and the year. A
 *  year in brackets wins ("Blade Runner 2049 (2017)"), else the last bare one
 *  after the name. */
export function parseNameYear(s: string): { name: string; year?: number } {
  const paren = /^(.*?\S)[\s._]*[([]((?:19|20)\d{2})[)\]]/.exec(s)
  if (paren) {
    const name = cleanName(paren[1])
    if (name) return { name, year: Number(paren[2]) }
  }
  let bare: RegExpExecArray | null = null
  const re = /[\s._]((?:19|20)\d{2})(?=[\s._-]|$)/g
  for (let m = re.exec(s); m; m = re.exec(s)) bare = m
  if (bare && bare.index > 0) {
    const name = cleanName(s.slice(0, bare.index))
    if (name) return { name, year: Number(bare[1]) }
  }
  // A name that is nothing but a tag ("Extended") is still its name.
  return { name: cleanName(s) || words(s) }
}

const SEASON_FOLDER = /^(?:season|series|staffel|saison|temporada|s)[\s._-]*(\d{1,3})$/i
const SPECIALS_FOLDER = /^specials?$/i
const EPISODE_SXE = /[Ss](\d{1,3})[\s._-]*[Ee](\d{1,4})(?:[-Ee]+\d{1,4})*/
const EPISODE_X = /(?:^|[^\d])(\d{1,2})x(\d{1,3})(?![\d])/

export interface EpisodeName {
  series: string
  season: number
  episode?: number
  title: string
}

/**
 * Jellyfin's TV naming: S01E02 or 1x02 in the file name, or a "Season 01"
 * (or "Specials") folder. The show is the folder above the season folder,
 * else the folder the file is in when the file name starts with it, else the
 * file name before the episode number. Null when nothing says episode.
 */
export function parseEpisode(rel: string): EpisodeName | null {
  const parts = normRel(rel).split('/')
  const base = baseOf(parts[parts.length - 1])
  const folders = parts.slice(0, -1)
  let seasonAt = -1, folderSeason: number | undefined
  for (let i = folders.length - 1; i >= 0; i--) {
    const m = SEASON_FOLDER.exec(folders[i])
    if (m) { seasonAt = i; folderSeason = Number(m[1]); break }
    if (SPECIALS_FOLDER.test(folders[i])) { seasonAt = i; folderSeason = 0; break }
  }
  const sxe = EPISODE_SXE.exec(base) ?? EPISODE_X.exec(base)
  if (!sxe && seasonAt < 0) return null

  let season = folderSeason ?? 1
  let episode: number | undefined
  let before = '', after = base
  if (sxe) {
    season = Number(sxe[1])
    episode = Number(sxe[2])
    before = base.slice(0, sxe.index)
    after = base.slice(sxe.index + sxe[0].length)
  } else {
    // In a season folder: "E02 Title", "02 - Title", "Show 02".
    const m = /(?:^|[\s._-])[Ee](\d{1,4})(?![\d])/.exec(base) ?? /^(\d{1,4})(?![\d])/.exec(base)
    if (m) {
      episode = Number(m[1])
      before = base.slice(0, m.index)
      after = base.slice(m.index + m[0].length)
    }
  }

  const fromFolder = (f: string | undefined) => f ? parseNameYear(f).name : ''
  const prefix = cleanName(before.replace(/[\s._-]+$/, ''))
  // The folder the episode sits in, unless that is its season folder.
  const own = seasonAt < 0 ? fromFolder(folders[folders.length - 1]) : ''
  let series = seasonAt > 0 ? fromFolder(folders[seasonAt - 1]) : ''
  if (!series && own && (!prefix || normName(prefix).startsWith(normName(own)))) series = own
  if (!series) series = parseNameYear(prefix).name || own || 'Unknown Show'

  const title = cleanName(after.replace(/^[\s._-]+/, ''))
  return { series, season, ...(episode !== undefined ? { episode } : {}), title: title || (episode !== undefined ? `Episode ${episode}` : cleanName(base)) }
}

/** A movie's name and year: its folder's when that reads "Name (2010)", else
 *  the file's. */
export function parseMovie(rel: string): { name: string; year?: number } {
  const parts = normRel(rel).split('/')
  const file = parseNameYear(baseOf(parts[parts.length - 1]))
  const folder = parts.length > 1 ? parseNameYear(parts[parts.length - 2]) : null
  if (folder?.year !== undefined) return folder
  return file
}

/** "01 Title", "1-01 Title", "01. Title": the disc, the track and the title. */
export function parseTrackFileName(base: string): { disc?: number; track?: number; title: string } {
  const m = /^(?:(\d{1,2})[-.])?(\d{1,3})(?:[\s._-]+|\.\s*)(.+)$/.exec(base)
  if (m && m[3].trim()) {
    return { ...(m[1] ? { disc: Number(m[1]) } : {}), track: Number(m[2]), title: m[3].trim() }
  }
  return { title: base.trim() }
}

const DISC_FOLDER = /^(?:cd|disc|disk)[\s._-]*\d{1,2}$/i

// ── Sidecars ─────────────────────────────────────────────────────────────────

const ART_NAMES = ['cover', 'folder', 'front', 'album', 'poster']
const ART_EXTS = ['jpg', 'jpeg', 'png', 'webp']

/** The first art file in a folder named like a cover, in ART_NAMES order. */
function folderArt(dir: string, byDir: Map<string, string[]>): string | undefined {
  const files = byDir.get(dir) ?? []
  for (const name of ART_NAMES) {
    const hit = files.find(f => {
      const base = baseOf(f).toLowerCase()
      return base === name && ART_EXTS.includes(extOf(f))
    })
    if (hit) return hit
  }
  return undefined
}

/** "<file>.jpg" or "<file>-poster.jpg" beside a video. */
function fileArt(rel: string, byDir: Map<string, string[]>): string | undefined {
  const base = baseOf(rel).toLowerCase()
  return (byDir.get(dirOf(rel)) ?? []).find(f => {
    const b = baseOf(f).toLowerCase()
    return ART_EXTS.includes(extOf(f)) && (b === base || b === `${base}-poster` || b === `${base}-thumb`)
  })
}

/** "<file>.lrc", matched without case. */
export function lyricsSidecar(rel: string, sidecars: readonly string[]): string | undefined {
  const base = baseOf(rel).toLowerCase()
  const dir = dirOf(rel)
  return sidecars.find(f => dirOf(f) === dir && ['lrc', 'elrc'].includes(extOf(f)) && baseOf(f).toLowerCase() === base)
}

export interface SubtitleSidecar { rel: string; language?: string; forced?: boolean; default?: boolean }

/** "<file>.srt", "<file>.en.srt", "<file>.en.forced.vtt": Jellyfin's naming. */
export function subtitleSidecars(rel: string, sidecars: readonly string[]): SubtitleSidecar[] {
  const base = baseOf(rel).toLowerCase()
  const dir = dirOf(rel)
  const out: SubtitleSidecar[] = []
  for (const f of sidecars) {
    if (dirOf(f) !== dir || !['srt', 'vtt'].includes(extOf(f))) continue
    const b = baseOf(f)
    if (b.toLowerCase() !== base && !b.toLowerCase().startsWith(`${base}.`)) continue
    const flags = b.slice(base.length).split('.').filter(Boolean).map(s => s.toLowerCase())
    const sub: SubtitleSidecar = { rel: f }
    for (const flag of flags) {
      if (flag === 'forced') sub.forced = true
      else if (flag === 'default') sub.default = true
      else if (/^[a-z]{2,3}(-[a-z0-9]{2,8})?$/.test(flag) && !sub.language) sub.language = flag
    }
    out.push(sub)
  }
  return out.sort((a, b) => a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0)
}

/**
 * SubRip to WebVTT, which is what a <track> reads. Timestamps take a dot,
 * the cue numbers stay (WebVTT allows ids), SSA override tags and <font>
 * (which WebVTT does not have) go, <i>, <b> and <u> stay.
 */
export function srtToVtt(srt: string): string {
  const text = srt.replace(/^﻿/, '').replace(/\r\n?/g, '\n')
  const time = (h: string, m: string, s: string, ms: string) => `${h.padStart(2, '0')}:${m}:${s}.${ms.padEnd(3, '0')}`
  const blocks = text.split(/\n{2,}/).map(b => b.trim()).filter(Boolean)
  const out: string[] = []
  for (const block of blocks) {
    const lines = block.split('\n')
    const at = lines.findIndex(l => /-->/.test(l))
    if (at < 0) continue
    const cue = lines[at].replace(/(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})/g, (_m, h, m, s, ms) => time(h, m, s, ms))
    if (!/^\d{2}:\d{2}:\d{2}\.\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}\.\d{3}/.test(cue)) continue
    const body = lines.slice(at + 1)
      .map(l => l.replace(/\{\\[^}]*\}/g, '').replace(/<\/?font[^>]*>/gi, ''))
      // A blank line would end the cue early.
      .filter(l => l.trim())
    out.push([...(at > 0 ? [lines[at - 1].trim()] : []), cue, ...body].join('\n'))
  }
  return `WEBVTT\n\n${out.join('\n\n')}\n`
}

/**
 * The library files an .m3u or .m3u8 lists, relative to the root, in order.
 * Entries are relative to the playlist's folder or absolute; URLs, comments
 * and anything outside the root are dropped. `root` is the library's absolute
 * path, either slash.
 */
export function parseM3u(text: string, playlistRel: string, root: string): string[] {
  const rootNorm = root.replace(/\\/g, '/').replace(/\/+$/, '')
  const windows = /^[A-Za-z]:\//.test(rootNorm)
  const out: string[] = []
  for (let line of text.replace(/^﻿/, '').split(/\r?\n/)) {
    line = line.trim()
    if (!line || line.startsWith('#')) continue
    if (/^file:\/\//i.test(line)) {
      try { line = decodeURIComponent(new URL(line).pathname).replace(/^\/([A-Za-z]:\/)/, '$1') } catch { continue }
    } else if (/^[a-z][a-z0-9+.-]+:\/\//i.test(line)) continue
    let p = line.replace(/\\/g, '/')
    if (p.startsWith('/') || /^[A-Za-z]:\//.test(p)) {
      const within = windows ? p.toLowerCase().startsWith(`${rootNorm.toLowerCase()}/`) : p.startsWith(`${rootNorm}/`)
      if (!within) continue
      p = p.slice(rootNorm.length + 1)
    } else {
      const dir = dirOf(normRel(playlistRel))
      p = dir ? `${dir}/${p}` : p
    }
    const parts: string[] = []
    let escaped = false
    for (const seg of p.split('/')) {
      if (seg === '' || seg === '.') continue
      if (seg === '..') { if (!parts.length) { escaped = true; break } parts.pop(); continue }
      parts.push(seg)
    }
    if (!escaped && parts.length) out.push(normRel(parts.join('/')))
  }
  return out
}

// ── Playlists made in Cascade ────────────────────────────────────────────────

export interface LocalPlaylist {
  Id: string
  Name: string
  trackIds: string[]
  /** ISO 8601. */
  createdAt: string
}

/** Most entries one playlist keeps. */
export const MAX_PLAYLIST_ENTRIES = 10_000

export function parseLocalPlaylists(raw: unknown): LocalPlaylist[] {
  if (!Array.isArray(raw)) return []
  const seen = new Set<string>()
  const out: LocalPlaylist[] = []
  for (const p of raw) {
    if (!isPlainObject(p) || !isSafeId(p.Id) || seen.has(p.Id)) continue
    const name = cleanText(p.Name, 200)
    if (!name) continue
    seen.add(p.Id)
    const created = typeof p.createdAt === 'string' && Number.isFinite(Date.parse(p.createdAt)) ? new Date(Date.parse(p.createdAt)).toISOString() : new Date(0).toISOString()
    out.push({ Id: p.Id, Name: name, trackIds: Array.isArray(p.trackIds) ? p.trackIds.filter(isSafeId).slice(0, MAX_PLAYLIST_ENTRIES) : [], createdAt: created })
  }
  return out
}

// ── The catalog ──────────────────────────────────────────────────────────────

/** One media file as the scan found it. */
export interface LocalFile {
  rel: string
  size: number
  /** When the scan first saw it (ISO 8601): Recently Added sorts by it. */
  added: string
  /** Null when its tags could not be read. */
  probe: LocalProbe | null
}

export interface LocalBuildInput {
  files: LocalFile[]
  /** Every lyrics, subtitle, art and playlist file found, relative. */
  sidecars: string[]
  /** .m3u and .m3u8 playlists, as parseM3u read them. */
  m3u: { rel: string; entries: string[] }[]
  playlists: LocalPlaylist[]
  userData: Record<string, LocalUserData>
  /** Ids whose art is on disk. */
  art: ReadonlySet<string>
  /** What this machine decodes; the shipped floor when the renderer has not said. */
  profile?: DeviceProfile | null
}

/** Where an item's art comes from: a picture file, or the picture embedded in
 *  a media file. */
export type ArtSource = { file: string } | { embedded: string }

export interface LocalCatalog {
  index: OfflineIndex
  /** Item id to its file, relative to the root. */
  paths: Record<string, string>
  /** Item id to its sidecar lyrics file. */
  lyrics: Record<string, string>
  /** Item id to its subtitle files, by the stream index the catalog gives them. */
  subs: Record<string, { index: number; rel: string }[]>
  /** Files found that this machine cannot play as they are. */
  unplayable: { rel: string; reason: string }[]
  /** Art the catalog would show, by item id. */
  artSources: Record<string, ArtSource>
}

const ticksOf = (sec: number | undefined) => sec && sec > 0 ? Math.round(sec * 10_000_000) : undefined
const nameIds = (names: string[], idOf: (n: string) => string): JfNameId[] => names.map(n => ({ Id: idOf(n), Name: n }))
const cmp = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0

interface Song { file: LocalFile; id: string; probe: LocalProbe; title: string; track?: number; disc?: number; artists: string[]; album: string; groupKey: string; year?: number }

/** Builds the catalog the query engine answers from. Deterministic: the same
 *  files give the same catalog, whatever order they were found in. */
export function buildCatalog(input: LocalBuildInput): LocalCatalog {
  const profile = input.profile ?? ELECTRON_PROFILE
  const index = emptyIndex()
  const paths: Record<string, string> = {}
  const sizes: Record<string, number> = {}
  const lyrics: Record<string, string> = {}
  const subs: Record<string, { index: number; rel: string }[]> = {}
  const unplayable: { rel: string; reason: string }[] = []
  const artSources: Record<string, ArtSource> = {}
  const ud = (id: string) => input.userData[id] ? { UserData: { ...input.userData[id] } } : {}
  const tag = (id: string) => input.art.has(id) ? 'local' : undefined

  const byDir = new Map<string, string[]>()
  for (const s of input.sidecars) {
    const d = dirOf(normRel(s))
    const into = byDir.get(d)
    if (into) into.push(normRel(s))
    else byDir.set(d, [normRel(s)])
  }
  // The sidecars in a file's own folder: the only ones that can be its own.
  const near = (rel: string) => byDir.get(dirOf(rel)) ?? []

  const files = [...input.files].map(f => ({ ...f, rel: normRel(f.rel) })).sort((a, b) => cmp(a.rel, b.rel))
  const songs: Song[] = []
  const movies: { file: LocalFile; id: string; probe: LocalProbe }[] = []
  const episodes: { file: LocalFile; id: string; probe: LocalProbe; ep: EpisodeName }[] = []

  for (const f of files) {
    const kind = classify(f.rel, f.probe)
    if (!kind) continue
    const verdict = playability(profile, kind, f.rel, f.probe)
    if (!verdict.ok) { unplayable.push({ rel: f.rel, reason: verdict.reason }); continue }
    const id = fileId(f.rel)
    const probe = f.probe ?? {}
    if (kind === 'video') {
      const ep = parseEpisode(f.rel)
      if (ep) episodes.push({ file: f, id, probe, ep })
      else movies.push({ file: f, id, probe })
      continue
    }
    const fromName = parseTrackFileName(baseOf(f.rel))
    const parts = f.rel.split('/')
    let albumDir = dirOf(f.rel)
    if (DISC_FOLDER.test(parts[parts.length - 2] ?? '')) albumDir = dirOf(albumDir)
    const folderName = albumDir ? albumDir.slice(albumDir.lastIndexOf('/') + 1) : ''
    const folder = folderName ? parseNameYear(folderName) : null
    const album = probe.album ?? folder?.name ?? 'Unknown Album'
    const artistFolder = albumDir.includes('/') ? parseNameYear(dirOf(albumDir).slice(dirOf(albumDir).lastIndexOf('/') + 1)).name : ''
    songs.push({
      file: f, id, probe,
      title: probe.title ?? fromName.title,
      track: probe.track ?? fromName.track,
      disc: probe.disc ?? fromName.disc,
      artists: probe.artists ?? (probe.albumArtist ? [probe.albumArtist] : artistFolder ? [artistFolder] : ['Unknown Artist']),
      album,
      groupKey: `${albumDir}\u0000${normName(album)}`,
      year: probe.year ?? folder?.year,
    })
  }

  // ── Music: an album is a folder's tracks that name one album. Its artist is
  // the album artist tag, else the one artist they share, else Various Artists,
  // so a compilation stays one album.
  const groups = new Map<string, Song[]>()
  for (const s of songs) {
    const into = groups.get(s.groupKey)
    if (into) into.push(s)
    else groups.set(s.groupKey, [s])
  }
  const albums = new Map<string, { item: JfItem; tracks: JfItem[]; dir: string; embedded?: string }>()
  for (const group of [...groups.values()]) {
    const tagged = group.map(s => s.probe.albumArtist).find(Boolean)
    const firstArtists = group[0].artists
    const shared = group.every(s => normName(s.artists[0]) === normName(firstArtists[0])) ? firstArtists[0] : null
    const albumArtist = tagged ?? shared ?? 'Various Artists'
    const aid = albumId(albumArtist, group[0].album)
    let entry = albums.get(aid)
    if (!entry) {
      const year = group.map(s => s.year).find(y => y !== undefined)
      const gain = group.map(s => s.probe.albumGainDb).find(g => g !== undefined)
      entry = {
        item: {
          Id: aid, Name: group[0].album, Type: 'MusicAlbum', AlbumArtist: albumArtist,
          AlbumArtists: nameIds([albumArtist], artistId),
          ...(year !== undefined ? { ProductionYear: year } : {}),
          ...(gain !== undefined ? { NormalizationGain: gain } : {}),
          ...(tag(aid) ? { ImageTags: { Primary: 'local' } } : {}),
          ...ud(aid),
        },
        tracks: [], dir: dirOf(group[0].file.rel),
      }
      albums.set(aid, entry)
    }
    entry.embedded ??= group.find(s => s.probe.embeddedArt)?.file.rel
    for (const s of group) {
      const genres = s.probe.genres ?? []
      entry.tracks.push({
        Id: s.id, Name: s.title, Type: 'Audio', MediaType: 'Audio',
        Album: s.album, AlbumId: aid, AlbumArtist: albumArtist,
        ...(tag(aid) ? { AlbumPrimaryImageTag: 'local' } : {}),
        Artists: s.artists, ArtistItems: nameIds(s.artists, artistId), AlbumArtists: nameIds([albumArtist], artistId),
        Genres: genres, GenreItems: nameIds(genres, genreId),
        ...(s.track !== undefined ? { IndexNumber: s.track } : {}),
        ...(s.disc !== undefined ? { ParentIndexNumber: s.disc } : {}),
        ...(s.year !== undefined ? { ProductionYear: s.year } : {}),
        ...(ticksOf(s.probe.durationSec) ? { RunTimeTicks: ticksOf(s.probe.durationSec) } : {}),
        ...(s.probe.trackGainDb !== undefined ? { NormalizationGain: s.probe.trackGainDb } : {}),
        DateCreated: s.file.added,
        MediaSources: [{ Id: s.id, Container: containerOf(s.file.rel), Size: s.file.size }],
        ...ud(s.id),
      })
      const lrc = lyricsSidecar(s.file.rel, near(s.file.rel))
      if (lrc) lyrics[s.id] = lrc
      paths[s.id] = s.file.rel
      sizes[s.id] = s.file.size
    }
  }
  for (const [aid, a] of [...albums.entries()].sort((x, y) => cmp(x[0], y[0]))) {
    a.tracks.sort((x, y) => (x.ParentIndexNumber ?? 1) - (y.ParentIndexNumber ?? 1) || (x.IndexNumber ?? 1e9) - (y.IndexNumber ?? 1e9) || cmp(paths[x.Id], paths[y.Id]))
    a.item.ChildCount = a.tracks.length
    a.item.DateCreated = a.tracks.map(t => t.DateCreated!).sort().at(-1)
    addCollection(index, a.item, a.tracks)
    const cover = folderArt(a.dir, byDir)
    if (cover) artSources[aid] = { file: cover }
    else if (a.embedded) artSources[aid] = { embedded: a.embedded }
  }

  // ── Video
  const videoStreams = (probe: LocalProbe, subFiles: SubtitleSidecar[]): JfMediaStream[] => {
    const streams: JfMediaStream[] = [{ Type: 'Video', Index: 0, ...(probe.videoCodec ? { Codec: probe.videoCodec } : {}), ...(probe.width ? { Width: probe.width } : {}), ...(probe.height ? { Height: probe.height } : {}) }]
    if (probe.audioCodec) streams.push({ Type: 'Audio', Index: 1, Codec: probe.audioCodec, IsDefault: true, ...(probe.channels ? { Channels: probe.channels } : {}) })
    subFiles.forEach((s, i) => streams.push({
      Type: 'Subtitle', Index: 2 + i, Codec: extOf(s.rel) === 'srt' ? 'srt' : 'webvtt', IsExternal: true, IsTextSubtitleStream: true,
      ...(s.language ? { Language: s.language } : {}), DisplayTitle: [s.language?.toUpperCase() ?? 'Subtitles', s.forced ? 'Forced' : ''].filter(Boolean).join(' '),
      IsDefault: !!s.default, IsForced: !!s.forced,
    }))
    return streams
  }
  const saveSubs = (id: string, subFiles: SubtitleSidecar[]) => {
    if (!subFiles.length) return
    subs[id] = subFiles.map((s, i) => ({ index: 2 + i, rel: s.rel }))
    const list: OfflineSubtitle[] = subFiles.map((s, i) => ({
      index: 2 + i, file: `subs/${id}.${2 + i}.vtt`,
      ...(s.language ? { language: s.language } : {}), title: [s.language?.toUpperCase() ?? 'Subtitles', s.forced ? 'Forced' : ''].filter(Boolean).join(' '),
      isDefault: !!s.default, isForced: !!s.forced,
    }))
    setSubtitles(index, id, list)
  }
  const videoCount = new Map<string, number>()
  for (const v of [...movies, ...episodes]) videoCount.set(dirOf(v.file.rel), (videoCount.get(dirOf(v.file.rel)) ?? 0) + 1)

  for (const m of movies) {
    const { name, year } = parseMovie(m.file.rel)
    const subFiles = subtitleSidecars(m.file.rel, near(m.file.rel))
    const art = fileArt(m.file.rel, byDir) ?? (videoCount.get(dirOf(m.file.rel)) === 1 ? folderArt(dirOf(m.file.rel), byDir) : undefined)
    if (art) artSources[m.id] = { file: art }
    const item: JfItem = {
      Id: m.id, Name: name, Type: 'Movie', MediaType: 'Video',
      ...(year !== undefined ? { ProductionYear: year } : {}),
      ...(ticksOf(m.probe.durationSec) ? { RunTimeTicks: ticksOf(m.probe.durationSec) } : {}),
      ...(tag(m.id) ? { ImageTags: { Primary: 'local' } } : {}),
      DateCreated: m.file.added,
      MediaSources: [{ Id: m.id, Container: containerOf(m.file.rel), Size: m.file.size }],
      MediaStreams: videoStreams(m.probe, subFiles),
      ...ud(m.id),
    }
    addCollection(index, item, [item])
    paths[m.id] = m.file.rel
    sizes[m.id] = m.file.size
    saveSubs(m.id, subFiles)
  }

  const shows = new Map<string, { item: JfItem; seasons: Map<number, JfItem>; episodes: JfItem[] }>()
  // An episode's subtitles are set once its show's collection holds it.
  const saveSubsLater: [string, SubtitleSidecar[]][] = []
  for (const e of episodes) {
    const sid = seriesId(e.ep.series)
    let show = shows.get(sid)
    // The show's folder: the one above a season folder, or the episode's own.
    const parts = e.file.rel.split('/')
    const inSeason = parts.length > 2 && (SEASON_FOLDER.test(parts[parts.length - 2]) || SPECIALS_FOLDER.test(parts[parts.length - 2]))
    const showDir = inSeason ? dirOf(dirOf(e.file.rel)) : dirOf(e.file.rel)
    if (!show) {
      const year = showDir ? parseNameYear(showDir.slice(showDir.lastIndexOf('/') + 1)).year : undefined
      show = {
        item: { Id: sid, Name: e.ep.series, Type: 'Series', ...(year !== undefined ? { ProductionYear: year } : {}), ...(tag(sid) ? { ImageTags: { Primary: 'local' } } : {}), ...ud(sid) },
        seasons: new Map(), episodes: [],
      }
      shows.set(sid, show)
      const art = showDir && normName(parseNameYear(showDir.slice(showDir.lastIndexOf('/') + 1)).name) === normName(e.ep.series) ? folderArt(showDir, byDir) : undefined
      if (art) artSources[sid] = { file: art }
    }
    const zid = seasonId(e.ep.series, e.ep.season)
    if (!show.seasons.has(e.ep.season)) {
      show.seasons.set(e.ep.season, {
        Id: zid, Name: e.ep.season === 0 ? 'Specials' : `Season ${e.ep.season}`, Type: 'Season', IndexNumber: e.ep.season,
        SeriesId: sid, SeriesName: e.ep.series, ...(tag(zid) ? { ImageTags: { Primary: 'local' } } : {}), ...ud(zid),
      })
      if (inSeason) {
        const art = folderArt(dirOf(e.file.rel), byDir)
        if (art) artSources[zid] = { file: art }
      }
    }
    const subFiles = subtitleSidecars(e.file.rel, near(e.file.rel))
    const still = fileArt(e.file.rel, byDir)
    if (still) artSources[e.id] = { file: still }
    show.episodes.push({
      Id: e.id, Name: e.ep.title, Type: 'Episode', MediaType: 'Video',
      SeriesId: sid, SeriesName: e.ep.series, SeasonId: zid, SeasonName: show.seasons.get(e.ep.season)!.Name,
      ParentIndexNumber: e.ep.season, ...(e.ep.episode !== undefined ? { IndexNumber: e.ep.episode } : {}),
      ...(tag(sid) ? { SeriesPrimaryImageTag: 'local' } : {}),
      ...(tag(e.id) ? { ImageTags: { Primary: 'local' } } : {}),
      ...(ticksOf(e.probe.durationSec) ? { RunTimeTicks: ticksOf(e.probe.durationSec) } : {}),
      DateCreated: e.file.added,
      MediaSources: [{ Id: e.id, Container: containerOf(e.file.rel), Size: e.file.size }],
      MediaStreams: videoStreams(e.probe, subFiles),
      ...ud(e.id),
    })
    paths[e.id] = e.file.rel
    sizes[e.id] = e.file.size
    saveSubsLater.push([e.id, subFiles])
  }
  for (const [, show] of [...shows.entries()].sort((x, y) => cmp(x[0], y[0]))) {
    show.episodes.sort((x, y) => (x.ParentIndexNumber ?? 0) - (y.ParentIndexNumber ?? 0) || (x.IndexNumber ?? 1e9) - (y.IndexNumber ?? 1e9) || cmp(paths[x.Id], paths[y.Id]))
    show.item.DateCreated = show.episodes.map(t => t.DateCreated!).sort().at(-1)
    show.item.ChildCount = show.seasons.size
    addCollection(index, show.item, show.episodes, [show.item, ...[...show.seasons.values()].sort((a, b) => (a.IndexNumber ?? 0) - (b.IndexNumber ?? 0))])
  }
  for (const [id, subFiles] of saveSubsLater) saveSubs(id, subFiles)

  // ── Playlists: the folder's .m3u files, then the ones made in Cascade.
  const idByRel = new Map(Object.entries(paths).map(([id, rel]) => [rel, id]))
  const idByRelLower = new Map(Object.entries(paths).map(([id, rel]) => [rel.toLowerCase(), id]))
  const trackItem = (id: string) => index.tracks[id]?.item
  for (const p of [...input.m3u].sort((a, b) => cmp(a.rel, b.rel))) {
    const ids = p.entries.map(r => idByRel.get(r) ?? idByRelLower.get(r.toLowerCase())).filter((x): x is string => !!x)
    const items = ids.map(trackItem).filter((x): x is JfItem => !!x)
    if (!items.length) continue
    const pid = playlistFileId(p.rel)
    addCollection(index, { Id: pid, Name: cleanName(baseOf(p.rel)), Type: 'Playlist', ChildCount: items.length, ...ud(pid) }, items)
  }
  for (const p of input.playlists) {
    const items = p.trackIds.map(trackItem).filter((x): x is JfItem => !!x)
    // An empty playlist still shows, so a new one can be filled. The engine
    // lists only playlists holding something ready, so it gets no entry yet.
    addCollection(index, { Id: p.Id, Name: p.Name, Type: 'Playlist', ChildCount: items.length, DateCreated: p.createdAt, CanDelete: true, ...ud(p.Id) }, items)
  }

  // Every item is a file on disk, so every one is ready.
  for (const [id, rel] of Object.entries(paths)) {
    markReady(index, id, `media/${id}.${extOf(rel) || 'bin'}`, sizes[id] ?? 0)
    index.tracks[id].library = index.tracks[id].item.Type === 'Movie' ? LOCAL_LIBRARIES.movies.Id
      : index.tracks[id].item.Type === 'Episode' ? LOCAL_LIBRARIES.tvshows.Id : LOCAL_LIBRARIES.music.Id
  }
  const used = new Set(Object.values(index.tracks).map(t => t.library))
  setLibraries(index, Object.values(LOCAL_LIBRARIES).filter(l => used.has(l.Id)).map(l => ({ ...l, Type: 'CollectionFolder' })))
  setUser(index, { Id: LOCAL_USER_ID, Name: 'You', Policy: { IsAdministrator: false, EnableContentDeletion: false, EnableContentDownloading: false } })
  unplayable.sort((a, b) => cmp(a.rel, b.rel))
  return { index, paths, lyrics, subs, unplayable, artSources }
}
