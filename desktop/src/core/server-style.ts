// The server style: a look an administrator sets in Cascade Server (the
// `server-style` capability, GET /CascadeServer/Style) for everyone on the
// server. "default" fills in what a person never set themselves; "enforced"
// puts the server's colors and/or lyrics over their own. Light or dark mode
// and the font always stay theirs.
//
// Nothing here writes a person's stored settings: the server's look is layered
// over them each time they are applied, so turning the style off on the server
// gives everyone their own look back.

import { parsePreset, type Preset } from './presets.ts'

export interface ServerStyle {
  mode: 'off' | 'default' | 'enforced'
  enforceTheme: boolean
  enforceLyrics: boolean
  preset: Preset | null
}

export const SERVER_STYLE_OFF: ServerStyle = { mode: 'off', enforceTheme: false, enforceLyrics: false, preset: null }

const isObject = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === 'object' && !Array.isArray(v)

/** The plugin's reply, checked the way any preset is (parsePreset clamps
 *  every value). Anything unexpected reads as off. */
export function parseServerStyle(raw: unknown): ServerStyle {
  if (!isObject(raw) || (raw.mode !== 'default' && raw.mode !== 'enforced') || !isObject(raw.preset)) return SERVER_STYLE_OFF
  const r = parsePreset(JSON.stringify(raw.preset))
  if (!r.ok) return SERVER_STYLE_OFF
  const enforce = isObject(raw.enforce) ? raw.enforce : {}
  const enforced = raw.mode === 'enforced'
  return { mode: raw.mode, enforceTheme: enforced && enforce.theme === true, enforceLyrics: enforced && enforce.lyrics === true, preset: r.preset }
}

/** How the server's look meets one part of a person's settings: not at all,
 *  filling in what they never set, or over their own. */
export function serverStylePart(s: ServerStyle, part: 'theme' | 'lyrics'): 'none' | 'fill' | 'force' {
  if (s.mode === 'off' || !(part === 'theme' ? s.preset?.theme : s.preset?.lyrics)) return 'none'
  return (part === 'theme' ? s.enforceTheme : s.enforceLyrics) ? 'force' : 'fill'
}

/** The lyric knob changes to use: the person's stored ones with the server's
 *  under them (fill) or instead of them (force, the server's look whole). */
export function layeredLyricChanges(user: unknown, s: ServerStyle): Record<string, unknown> {
  const mine = isObject(user) ? user : {}
  const server = s.preset?.lyrics?.style ?? {}
  switch (serverStylePart(s, 'lyrics')) {
    case 'force': return { ...server }
    case 'fill': return { ...server, ...mine }
    default: return { ...mine }
  }
}

export interface ThemeLook {
  gradStart: string
  gradEnd: string
  albumArt: boolean
  bgDim: number
  bgBlend: boolean
  lyricScale: number
}

/** Which of a person's values they stored themselves: the colors (gradient
 *  and album-art accent, kept together) and each Now Playing tuning value. */
export interface LookSet { colors: boolean; bgDim: boolean; bgBlend: boolean; lyricScale: boolean }

/** The look to use. Values not stored are the shipped defaults in `user`. */
export function layeredLook(user: ThemeLook, set: LookSet, s: ServerStyle): ThemeLook {
  const out = { ...user }
  const t = s.preset?.theme, l = s.preset?.lyrics
  const theme = serverStylePart(s, 'theme'), lyrics = serverStylePart(s, 'lyrics')
  if (t && (theme === 'force' || (theme === 'fill' && !set.colors))) {
    out.gradStart = t.gradStart; out.gradEnd = t.gradEnd; out.albumArt = t.albumArt
  }
  if (t && (theme === 'force' || (theme === 'fill' && !set.bgDim))) out.bgDim = t.bgDim
  if (t && (theme === 'force' || (theme === 'fill' && !set.bgBlend))) out.bgBlend = t.bgBlend
  if (l && (lyrics === 'force' || (lyrics === 'fill' && !set.lyricScale))) out.lyricScale = l.lyricScale
  return out
}

/** What to save for one setting while a server style is on: a value that only
 *  shows the server's look through is not the person's own, so what they had
 *  stored (or nothing) stays. Otherwise switching light/dark, or moving one
 *  slider, would keep the server's look after the admin turned it off. */
export function ownValue<T>(shown: T, server: T | undefined, stored: T | undefined, active: boolean): T | undefined {
  return active && server !== undefined && shown === server ? stored : shown
}
