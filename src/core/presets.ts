// Shareable looks: the theme (mode, colours, font) and the full-screen lyrics
// style, written to a .cascadepreset file or copied as text.
//
// A preset comes from someone else's computer, so it is untrusted in the same
// way a stored setting is, and more so: every value goes through the clamp or
// check the matching setting already uses (lyric-style.ts, np-tuning.ts,
// font.ts) before it can reach CSS or the lyric timing. A field that is
// missing or the wrong type takes the shipped default, so applying a preset
// always lands on one known look rather than a mix of it and whatever was set
// before.
//
// Lyric knob keys are the Apple app's (see lyric-style.ts), so a lyrics preset
// is meant to move between the two apps once the Apple side reads them.

import { lyricStyleChanges, lyricStyleFrom, type LyricStyle } from './lyric-style.ts'
import { clampBgBlend, clampBgDim, clampLyricScale } from './np-tuning.ts'
import { FONT_PRESETS, sanitizeFontName } from './font.ts'

export const PRESET_FORMAT = 'cascade-preset'
export const PRESET_VERSION = 1
export const PRESET_EXTENSION = 'cascadepreset'
/** Larger than any real preset by two orders of magnitude; refuses a pasted
 *  novel before JSON.parse has to read it. */
export const PRESET_MAX_BYTES = 64 * 1024
const NAME_MAX = 60

/** The shipped gradient, used when a preset's colours are missing or bad.
 *  Matches THEME_PRESETS[0] in renderer.js. */
export const PRESET_DEFAULT_GRADIENT = { start: '#4ade80', end: '#7c3aed' } as const

export interface PresetTheme {
  mode: 'dark' | 'light'
  gradStart: string
  gradEnd: string
  albumArt: boolean
  bgDim: number
  bgBlend: boolean
  font: { preset: string; custom: string }
}

export interface PresetLyrics {
  /** Only the knobs that differ from the defaults, as the store keeps them. */
  style: LyricStyle
  lyricScale: number
}

export interface Preset {
  format: typeof PRESET_FORMAT
  version: typeof PRESET_VERSION
  name: string
  theme?: PresetTheme
  lyrics?: PresetLyrics
}

export type PresetResult = { ok: true; preset: Preset } | { ok: false; error: string }

const isObject = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === 'object' && !Array.isArray(v)

const HEX = /^#[0-9a-f]{6}$/i

/** Printable text only, trimmed and capped; a name is shown in the UI and
 *  used as a file name. */
export function presetName(v: unknown): string {
  const s = typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, NAME_MAX) : ''
  return s || 'Untitled'
}

export function presetTheme(v: unknown): PresetTheme {
  const t = isObject(v) ? v : {}
  const font = isObject(t.font) ? t.font : {}
  const preset = font.preset === 'custom' || (typeof font.preset === 'string' && Object.prototype.hasOwnProperty.call(FONT_PRESETS, font.preset))
    ? font.preset as string : 'system'
  return {
    mode: t.mode === 'light' ? 'light' : 'dark',
    gradStart: typeof t.gradStart === 'string' && HEX.test(t.gradStart) ? t.gradStart.toLowerCase() : PRESET_DEFAULT_GRADIENT.start,
    gradEnd: typeof t.gradEnd === 'string' && HEX.test(t.gradEnd) ? t.gradEnd.toLowerCase() : PRESET_DEFAULT_GRADIENT.end,
    albumArt: t.albumArt === true,
    bgDim: clampBgDim(t.bgDim),
    bgBlend: clampBgBlend(t.bgBlend),
    font: { preset, custom: preset === 'custom' ? sanitizeFontName(font.custom) : '' },
  }
}

export function presetLyrics(v: unknown): PresetLyrics {
  const l = isObject(v) ? v : {}
  return { style: lyricStyleChanges(lyricStyleFrom(l.style)), lyricScale: clampLyricScale(l.lyricScale) }
}

/** A clean preset from the app's current values; the same checks as an
 *  import, so an export can never write something an import would refuse. */
export function buildPreset(input: { name?: unknown; theme?: unknown; lyrics?: unknown }): Preset {
  const out: Preset = { format: PRESET_FORMAT, version: PRESET_VERSION, name: presetName(input.name) }
  if (input.theme !== undefined) out.theme = presetTheme(input.theme)
  if (input.lyrics !== undefined) out.lyrics = presetLyrics(input.lyrics)
  return out
}

export function serializePreset(preset: Preset): string {
  return JSON.stringify(preset, null, 2) + '\n'
}

/** Reads a preset file or pasted text. Never throws. */
export function parsePreset(text: unknown): PresetResult {
  if (typeof text !== 'string' || !text.trim()) return { ok: false, error: 'That is empty.' }
  if (text.length > PRESET_MAX_BYTES) return { ok: false, error: 'That is too large to be a Cascade preset.' }
  let raw: unknown
  try { raw = JSON.parse(text) } catch { return { ok: false, error: 'That is not a Cascade preset (it is not valid JSON).' } }
  if (!isObject(raw) || raw.format !== PRESET_FORMAT) return { ok: false, error: 'That is not a Cascade preset.' }
  if (typeof raw.version !== 'number' || !Number.isInteger(raw.version) || raw.version < 1) {
    return { ok: false, error: 'That preset has no valid version.' }
  }
  if (raw.version > PRESET_VERSION) return { ok: false, error: 'That preset was made by a newer Cascade. Update Cascade to use it.' }
  if (!isObject(raw.theme) && !isObject(raw.lyrics)) return { ok: false, error: 'That preset has no theme or lyrics settings in it.' }
  return {
    ok: true,
    preset: buildPreset({
      name: raw.name,
      theme: isObject(raw.theme) ? raw.theme : undefined,
      lyrics: isObject(raw.lyrics) ? raw.lyrics : undefined,
    }),
  }
}

/** A file name for the save dialog: the preset's name with anything a file
 *  system might refuse replaced. */
export function presetFileName(name: string): string {
  const base = presetName(name).replace(/[\\/:*?"<>|]+/g, '-').replace(/^\.+/, '').trim() || 'Cascade preset'
  return `${base}.${PRESET_EXTENSION}`
}
