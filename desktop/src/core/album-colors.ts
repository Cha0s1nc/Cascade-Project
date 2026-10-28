// The album-art background: pulling a few vivid colours out of a cover, and
// drifting them around as blobs.
//
// Lifted out of apps/desktop/renderer.js (extractTopColors ~5547,
// buildBlobBackground ~5632, randomizeDrift ~3296, the drift half of
// startBeatLoop ~3320) so the React Native app renders the same background
// rather than a lookalike. Everything here is pure: it takes raw RGBA bytes and
// a timestamp and returns numbers. How the pixels were obtained is the host's
// problem - a canvas on desktop, a decoded PNG on mobile - and so is how the
// result gets painted.
//
// One thing that did NOT come across: the AudioContext and analyser wired up
// next to the desktop drift loop. The drift is time-based sin/cos and the
// analyser's output is never read, so the whole Web Audio dependency was doing
// nothing visible and is simply absent here.

import { desktopTuning } from './tuning-defaults.ts'

// ---------------------------------------------------------------------------
// Tuning
//
// Every number below that is a matter of taste lives in tuning-defaults.json
// ("albumColors"), shared with the Apple apps' AlbumColors.swift. blobTuning
// is a live copy: the debug tuning panel (.cascade-debug) turns it with no
// rebuild, and npm run tuning bakes what it ends up at back into the file.
// Nothing else writes it, so outside that panel it always equals the file.
// ---------------------------------------------------------------------------

/** Where a blob sits, in percent of the view, and how opaque it is. */
export interface BlobSlot { x: number; y: number; w: number; h: number; alpha: number }

export interface BlobTuning {
  /** Clusters found before ranking. More than are returned, so a small vivid
   *  accent gets its own cluster instead of being absorbed by a big dull one. */
  clusters: number
  /** Iterations of Lloyd's algorithm. Converges well before this on 6400 px. */
  iterations: number
  /** Minimum perceptual gap between two returned colours. Without it the top
   *  three are routinely three shades of the same thing. */
  minSeparation: number
  /** Pixels darker or lighter than these are not "the colour of this cover":
   *  every cover has plenty of near-black and near-white. Loose on purpose,
   *  so a dark cover still yields its dark colours. */
  minSampleL: number
  maxSampleL: number
  /** A cluster covering less of the cover than this is not a real colour. */
  minShare: number
  /** How much colourfulness beats coverage in the ranking (share times chroma
   *  to this power), so a cover that is 80% beige and 5% hot pink reads pink. */
  chromaPower: number
  /** The dark theme's lightness window: below minL a blob is lost against
   *  #0d0d0f, above maxL it washes out the content in front of it. */
  minL: number
  maxL: number
  /** The light theme's. Not a version of the dark pair: with multiply
   *  blending a dark blob over near-white is ink on paper, and pale blobs
   *  multiply to almost nothing (the washed-out first attempt, 2026-08-26). */
  minLLight: number
  maxLLight: number
  /** Below this a colour reads as grey rather than as a colour. */
  minChroma: number
  /** Blob opacity on the light base. 1, no scaling: with the lightness window
   *  doing the work, an extra cut was the biggest cause of the wash-out. */
  lightAlphaScale: number
  /** How far the blobs wander from their slots, as a multiple. */
  driftScale: number
  /** Anchors, near the edges so the middle stays dark enough to read text
   *  over: the background is a mood, not a competitor to the content. */
  slots: BlobSlot[]
  /** How often to move the blobs. The drift has periods of tens of seconds,
   *  so 60 fps is wasted work; ~15 is visually indistinguishable. */
  frameMs: number
  /** The square side a cover is scaled to before extraction (6400 px). */
  sampleSide: number
}

const NUMBER_KEYS = ['clusters', 'iterations', 'minSeparation', 'minSampleL', 'maxSampleL', 'minShare', 'chromaPower',
  'minL', 'maxL', 'minLLight', 'maxLLight', 'minChroma', 'lightAlphaScale', 'driftScale', 'frameMs', 'sampleSide'] as const

/** The file's albumColors section, checked: a missing or mistyped value
 *  throws rather than quietly painting with NaN. */
export function blobTuningFrom(section: Record<string, unknown>): BlobTuning {
  const num = (key: string, v: unknown): number => {
    if (typeof v !== 'number' || !Number.isFinite(v)) throw new Error(`tuning-defaults.json: albumColors.${key} must be a number`)
    return v
  }
  const out = Object.fromEntries(NUMBER_KEYS.map(k => [k, num(k, section[k])])) as Omit<BlobTuning, 'slots'>
  const slots = section.slots
  if (!Array.isArray(slots) || slots.length === 0) throw new Error('tuning-defaults.json: albumColors.slots must be a list')
  return {
    ...out,
    slots: slots.map((s, i) => {
      const o = (s ?? {}) as Record<string, unknown>
      return { x: num(`slots[${i}].x`, o.x), y: num(`slots[${i}].y`, o.y), w: num(`slots[${i}].w`, o.w),
        h: num(`slots[${i}].h`, o.h), alpha: num(`slots[${i}].alpha`, o.alpha) }
    }),
  }
}

/** The shipped values, as tuning-defaults.json has them for the desktop. */
export const SHIPPED_BLOB_TUNING: Readonly<BlobTuning> = blobTuningFrom(desktopTuning('albumColors'))

/** The live copy everything here reads. See the note above. */
export const blobTuning: BlobTuning = structuredClone(SHIPPED_BLOB_TUNING)

/** The person's look on top (lyric-style.ts' Background colors knobs, set by
 *  the host): saturation and brightness as CSS filters would apply them,
 *  intensity on the blobs' opacity, speed on the host's drift clock. At these
 *  values, no change. */
export const blobLook = { saturation: 1, brightness: 0, intensity: 1, speed: 1 }

/** A blob colour. `hue` is the cluster's Oklab hue in degrees, and `chroma`
 *  its colourfulness before toBlobColor lifted it to minChroma: the lift
 *  makes the blob visible, so only the raw value says whether the cover has
 *  a colour there at all. Hand-built grey blobs leave it out. */
export interface BlobColor {
  r: number
  g: number
  b: number
  hue: number
  chroma?: number
}

// ---------------------------------------------------------------------------
// Oklab
//
// The colours are clustered in Oklab rather than by hue, because hue alone was
// the root of most of the desktop's wrong answers. Two problems it cannot see:
// navy and sky blue are the same hue and average into a muddy mid-blue, while a
// colour sitting on a bucket boundary splits its votes between two buckets and
// loses to something less prominent. Oklab is perceptually uniform, so plain
// Euclidean distance in it means "looks different by about this much", which is
// exactly the judgement being made here.
// ---------------------------------------------------------------------------

interface Oklab { L: number; a: number; b: number }

function srgbToLinear(c: number): number {
  const n = c / 255
  return n <= 0.04045 ? n / 12.92 : Math.pow((n + 0.055) / 1.055, 2.4)
}

function linearToSrgb(c: number): number {
  const n = c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055
  return Math.min(255, Math.max(0, Math.round(n * 255)))
}

export function srgbToOklab(r: number, g: number, b: number): Oklab {
  const lr = srgbToLinear(r), lg = srgbToLinear(g), lb = srgbToLinear(b)
  const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
  const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
  const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
  return {
    L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  }
}

/** Linear sRGB, unclamped: outside 0 to 1 means the colour has no sRGB form. */
function oklabToLinear(c: Oklab): [number, number, number] {
  const l_ = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b
  const m_ = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b
  const s_ = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b
  const l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
  return [
    +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  ]
}

export function oklabToSrgb(c: Oklab): { r: number; g: number; b: number } {
  const [r, g, b] = oklabToLinear(c)
  return { r: linearToSrgb(r), g: linearToSrgb(g), b: linearToSrgb(b) }
}

/** Perceptual colourfulness. 0 is grey; roughly 0.25+ is vivid. */
function chroma(c: Oklab): number {
  return Math.hypot(c.a, c.b)
}

function distance(p: Oklab, q: Oklab): number {
  return Math.hypot(p.L - q.L, p.a - q.a, p.b - q.b)
}

/** Hue angle in degrees, for reporting only - nothing clusters on it. */
function hueOf(c: Oklab): number {
  const deg = (Math.atan2(c.b, c.a) * 180) / Math.PI
  return deg < 0 ? deg + 360 : deg
}

/**
 * The dominant vivid colours of a cover, most prominent first.
 *
 * `rgba` is tightly-packed RGBA bytes - 4 per pixel - as produced by a canvas'
 * getImageData or a PNG decoder. Its length must be a multiple of 4; anything
 * else means the caller mislabelled its buffer, and silently reading past a row
 * would produce plausible-looking garbage, so it throws.
 *
 * Deterministic: the same cover always yields the same colours. That is a
 * requirement rather than a nicety, because the background is rebuilt on every
 * track change and a cover that produced different colours each play would read
 * as a bug.
 */
export function extractTopColors(
  rgba: Uint8Array | Uint8ClampedArray | number[],
  n = 3,
  light = false,
): BlobColor[] {
  if (rgba.length % 4 !== 0) {
    throw new Error(`extractTopColors: expected packed RGBA, got ${rgba.length} bytes`)
  }

  // Keep the pixels that could plausibly be "the colour of this cover"
  // (blobTuning.minSampleL and maxSampleL).
  const t = blobTuning
  const samples: Oklab[] = []
  for (let i = 0; i < rgba.length; i += 4) {
    if ((rgba[i + 3] as number) < 128) continue
    const c = srgbToOklab(rgba[i] as number, rgba[i + 1] as number, rgba[i + 2] as number)
    if (c.L < t.minSampleL || c.L > t.maxSampleL) continue
    samples.push(c)
  }
  if (samples.length === 0) return []

  const centroids = seedCentroids(samples, Math.max(1, Math.round(t.clusters)))
  const assignment = new Array<number>(samples.length).fill(0)

  for (let iter = 0; iter < t.iterations; iter++) {
    let moved = false
    for (let i = 0; i < samples.length; i++) {
      const s = samples[i] as Oklab
      let best = 0
      let bestD = Infinity
      for (let k = 0; k < centroids.length; k++) {
        const d = distance(s, centroids[k] as Oklab)
        if (d < bestD) { bestD = d; best = k }
      }
      if (assignment[i] !== best) { assignment[i] = best; moved = true }
    }

    const sums = centroids.map(() => ({ L: 0, a: 0, b: 0, n: 0 }))
    for (let i = 0; i < samples.length; i++) {
      const s = samples[i] as Oklab
      const acc = sums[assignment[i] as number] as { L: number; a: number; b: number; n: number }
      acc.L += s.L; acc.a += s.a; acc.b += s.b; acc.n++
    }
    for (let k = 0; k < centroids.length; k++) {
      const acc = sums[k] as { L: number; a: number; b: number; n: number }
      if (acc.n > 0) centroids[k] = { L: acc.L / acc.n, a: acc.a / acc.n, b: acc.b / acc.n }
    }
    if (!moved) break
  }

  // Weight by how much of the cover a cluster covers *and* how colourful it is,
  // so a vivid accent beats a large dull field. A cover that is 80% beige and
  // 5% hot pink should read as pink - that is the whole point of the feature.
  const counts = new Array<number>(centroids.length).fill(0)
  for (const a of assignment) counts[a] = (counts[a] as number) + 1

  const ranked = centroids
    .map((c, k) => {
      const share = (counts[k] as number) / samples.length
      return { c, share, score: share * Math.pow(chroma(c) + 0.02, t.chromaPower) }
    })
    .filter(x => x.share > t.minShare) // ignore clusters too small to be a real colour
    .sort((a, b) => b.score - a.score)

  const picked: Oklab[] = []
  for (const { c } of ranked) {
    if (picked.length >= n) break
    if (picked.some(p => distance(p, c) < t.minSeparation)) continue
    picked.push(c)
  }
  // If separation left us short (a genuinely monochrome cover), backfill rather
  // than return fewer blobs than the layout expects.
  for (const { c } of ranked) {
    if (picked.length >= n) break
    if (!picked.includes(c)) picked.push(c)
  }

  return picked.map(c => toBlobColor(c, light))
}

/**
 * Deterministic k-means++ style seeding: start from the most colourful sample,
 * then repeatedly take the sample furthest from everything chosen so far.
 *
 * Deliberately not random. Random seeding gives a different palette for the
 * same cover on different runs, and "the background changed colour when I
 * replayed the song" is indistinguishable from a bug.
 */
function seedCentroids(samples: Oklab[], k: number): Oklab[] {
  let first = samples[0] as Oklab
  let bestChroma = -1
  for (const s of samples) {
    const c = chroma(s)
    if (c > bestChroma) { bestChroma = c; first = s }
  }

  const centroids: Oklab[] = [first]
  while (centroids.length < k && centroids.length < samples.length) {
    let far = samples[0] as Oklab
    let farD = -1
    for (const s of samples) {
      let nearest = Infinity
      for (const c of centroids) {
        const d = distance(s, c)
        if (d < nearest) nearest = d
      }
      if (nearest > farD) { farD = nearest; far = s }
    }
    centroids.push(far)
  }
  return centroids
}

/** The lightness window each theme clamps its blobs into, as shipped.
 *  Exported so tests can check the clamping without hardcoding tuning values
 *  that have already moved twice. */
export const BLOB_L_RANGE = {
  dark:  { min: SHIPPED_BLOB_TUNING.minL, max: SHIPPED_BLOB_TUNING.maxL },
  light: { min: SHIPPED_BLOB_TUNING.minLLight, max: SHIPPED_BLOB_TUNING.maxLLight },
}

/**
 * A cluster centre as a paintable blob colour.
 *
 * The desktop forced every colour to exactly L = 0.50 and S >= 0.70, which is
 * the single biggest reason its output looked wrong: a pastel cover and a neon
 * one came out identical, because the "correction" discarded precisely the
 * information that distinguished them. Here the colour is left alone unless it
 * would actually be invisible against the base, and then only nudged to the
 * edge of the usable range for that base - hue is never touched.
 *
 * `light` picks which base the blob is being painted against - true for the
 * light theme's near-white overlay, false (default) for the dark one.
 */
function toBlobColor(c: Oklab, light = false): BlobColor {
  const t = blobTuning
  const minL = light ? t.minLLight : t.minL
  const maxL = light ? t.maxLLight : t.maxL

  let { L, a, b } = c
  L = Math.min(maxL, Math.max(minL, L))

  const ch = Math.hypot(a, b)
  if (ch > 0 && ch < t.minChroma) {
    const scale = t.minChroma / ch
    a *= scale
    b *= scale
  }

  const { r, g, b: bl } = oklabToSrgb({ L, a, b })
  return { r, g, b: bl, hue: hueOf(c), chroma: ch }
}

// ---------------------------------------------------------------------------
// The accent
//
// The player bar, buttons and progress take the cover's colour as a two-stop
// gradient. It used to be the top blob's HSL hue at a fixed HSL saturation
// and lightness, and HSL is not perceptual: a skin-tone cover came out loud
// orange, a grey-blue one electric blue, yellow glared and blue went murky.
// Worse, the grey check ran on the blob after minChroma had lifted it, so
// JPEG noise on a black-and-white cover passed as a colour (a grey After
// Hours gave gold). Here the hue is the cluster's own Oklab hue, the
// lightness is fixed perceptually, and the chroma follows the cover's, so a
// muted cover gets a muted accent rather than a neon one.
// Mirrored in AlbumColors.swift (accent(from:)); keep the numbers in step.
// ---------------------------------------------------------------------------

/** Raw chroma a blob needs to count as the cover's colour. Muted photo covers
 *  measure 0.012 to 0.03 here, JPEG noise on grey art under 0.01. */
const ACCENT_COLORFUL = 0.025
/** Below this even the top blob has no colour to speak of: a grey accent. */
const ACCENT_FAINT = 0.012
/** Oklab lightness of the gradient's two stops. */
const ACCENT_START_L = 0.80
const ACCENT_END_L = 0.56
/** The accent's chroma is the cover's times this, kept in this range. */
const ACCENT_CHROMA_SCALE = 1.6
const ACCENT_MIN_CHROMA = 0.05
const ACCENT_MAX_CHROMA = 0.16

/** The colour at Oklab lightness L, chroma c and hue h (radians), with the
 *  chroma reduced until it fits in sRGB, so the hue is never bent to fit. */
function lchHex(L: number, c: number, h: number): string {
  let k = c
  const fits = () => oklabToLinear({ L, a: k * Math.cos(h), b: k * Math.sin(h) }).every(v => v >= -0.001 && v <= 1.001)
  while (k > 0 && !fits()) k = Math.max(0, k - 0.005)
  const { r, g, b } = oklabToSrgb({ L, a: k * Math.cos(h), b: k * Math.sin(h) })
  return '#' + [r, g, b].map(v => v.toString(16).padStart(2, '0')).join('')
}

/**
 * The accent gradient for a cover's blobs (extractTopColors' output), or null
 * when the cover has no colour to take one from and the accent should go
 * grey. From the most prominent blob that is actually a colour, so a large
 * grey field ranked first does not hide the colour beside it.
 */
export function artAccent(colors: BlobColor[]): { start: string; end: string } | null {
  const raw = (c: BlobColor | undefined) => c?.chroma ?? 0
  const pick = colors.find(c => raw(c) >= ACCENT_COLORFUL) ?? (raw(colors[0]) >= ACCENT_FAINT ? colors[0] : undefined)
  if (!pick) return null
  const h = (pick.hue * Math.PI) / 180
  const c = Math.min(ACCENT_MAX_CHROMA, Math.max(ACCENT_MIN_CHROMA, raw(pick) * ACCENT_CHROMA_SCALE))
  return { start: lchHex(ACCENT_START_L, c, h), end: lchHex(ACCENT_END_L, c * 1.05, h) }
}

/**
 * Per-blob drift parameters. Two independent sin/cos pairs per axis, which is
 * what makes the motion read as organic rather than as a circle: the two
 * periods are incommensurate, so the path is a slow Lissajous figure that does
 * not visibly repeat.
 */
export interface DriftParams {
  xF1: number; xP1: number; xA1: number
  xF2: number; xP2: number; xA2: number
  yF1: number; yP1: number; yA1: number
  yF2: number; yP2: number; yA2: number
}

/**
 * Fresh drift parameters, one set per blob. Re-rolled on every colour change so
 * two tracks in a row do not trace the same path.
 *
 * `rand` is injectable purely so the test can pin it; callers pass nothing.
 */
export function randomizeDrift(count = 3, rand: () => number = Math.random): DriftParams[] {
  return Array.from({ length: count }, () => ({
    xF1: 0.11 + rand() * 0.13, xP1: rand() * Math.PI * 2, xA1: 10 + rand() * 10,
    xF2: 0.04 + rand() * 0.09, xP2: rand() * Math.PI * 2, xA2: 3 + rand() * 6,
    yF1: 0.10 + rand() * 0.13, yP1: rand() * Math.PI * 2, yA1: 10 + rand() * 10,
    yF2: 0.04 + rand() * 0.09, yP2: rand() * Math.PI * 2, yA2: 3 + rand() * 6,
  }))
}

/** A blob placed on screen. Positions and sizes are percentages. */
export interface Blob {
  x: number
  y: number
  w: number
  h: number
  alpha: number
  color: BlobColor
}

/**
 * Where the blobs are at time `t` (seconds). Pure given the current tuning -
 * same inputs, same blobTuning and blobLook, same output - so a host can drive
 * it from a clock, a test can drive it from a constant.
 *
 * `light` scales blob opacity for the light theme's base (lightAlphaScale).
 * blobLook's saturation, brightness and intensity are applied here, so every
 * path that paints blobs shows them.
 */
export function driftedBlobs(colors: BlobColor[], drift: DriftParams[], t: number, light = false): Blob[] {
  const { slots, lightAlphaScale, driftScale: d } = blobTuning
  const alphaScale = (light ? lightAlphaScale : 1) * blobLook.intensity
  return colors.map((raw, i) => {
    const s = slots[i] ?? slots[slots.length - 1] as BlobSlot
    const alpha = Math.min(1, s.alpha * alphaScale)
    const color = lookColor(raw)
    const p = drift[i] ?? drift[0]
    if (!p) return { x: s.x, y: s.y, w: s.w, h: s.h, alpha, color }
    return {
      x: s.x + (Math.sin(t * p.xF1 + p.xP1) * p.xA1 + Math.sin(t * p.xF2 + p.xP2) * p.xA2) * d,
      y: s.y + (Math.cos(t * p.yF1 + p.yP1) * p.yA1 + Math.cos(t * p.yF2 + p.yP2) * p.yA2) * d,
      w: s.w,
      h: s.h,
      alpha,
      color,
    }
  })
}

/**
 * A colour as blobLook's saturation and brightness show it: the matrices CSS's
 * saturate() and SwiftUI's .saturation() use, then brightness added to each
 * channel, as SwiftUI's .brightness() does. Unchanged at the defaults.
 */
export function lookColor(c: BlobColor): BlobColor {
  const s = blobLook.saturation, add = blobLook.brightness * 255
  if (s === 1 && add === 0) return c
  const ch = (v: number) => Math.min(255, Math.max(0, Math.round(v + add)))
  return {
    r: ch((0.213 + 0.787 * s) * c.r + (0.715 - 0.715 * s) * c.g + (0.072 - 0.072 * s) * c.b),
    g: ch((0.213 - 0.213 * s) * c.r + (0.715 + 0.285 * s) * c.g + (0.072 - 0.072 * s) * c.b),
    b: ch((0.213 - 0.213 * s) * c.r + (0.715 - 0.715 * s) * c.g + (0.072 + 0.928 * s) * c.b),
    hue: c.hue,
  }
}

/** The base colour with blobLook's brightness on it, as a CSS colour: the
 *  Apple apps' filter lifts the base along with the blobs. */
export function blobBaseCss(light: boolean): string {
  const hex = light ? BLOB_BASE_COLOR_LIGHT : BLOB_BASE_COLOR
  if (blobLook.brightness === 0) return hex
  const n = parseInt(hex.slice(1), 16)
  const { r, g, b } = lookColor({ r: n >> 16, g: (n >> 8) & 255, b: n & 255, hue: 0 })
  return `rgb(${r},${g},${b})`
}

/**
 * How light the background reads, 0 to 1: the blobs' Oklab lightness weighted
 * by how much of the screen each covers (its slot's size and opacity). 0 with
 * no colours, when the near-black base is all there is. The Apple apps'
 * AlbumColors.brightness, which the lyrics dim scales by.
 */
export function blobBrightness(colors: BlobColor[]): number {
  let sum = 0, total = 0
  colors.forEach((c, i) => {
    const s = blobTuning.slots[i]
    if (!s) return
    const w = s.w * s.h * s.alpha
    sum += srgbToOklab(c.r, c.g, c.b).L * w
    total += w
  })
  return total > 0 ? sum / total : 0
}

/**
 * The blobs as a CSS background-image value.
 *
 * Shared by both hosts, which is the whole reason it is a string: the desktop
 * assigns it to style.backgroundImage, and React Native 0.83 parses the very
 * same syntax for its experimental_backgroundImage, radial-gradient and all.
 * That is what made this feature possible on tvOS without Skia, Reanimated and
 * Worklets - three native dependencies the plan had budgeted for.
 *
 * The dark base colour is deliberately not included: a bare hex is not a valid
 * background-image, so both hosts set it as a background colour instead.
 */
export function blobBackgroundCss(blobs: Blob[]): string {
  return blobs
    .map(b => {
      const { r, g, b: bl } = b.color
      const rgba = `rgba(${r},${g},${bl},${b.alpha})`
      // Two stops at the same colour (0% and 42%) give the blob a solid core
      // before it falls off, instead of fading from the very centre.
      return `radial-gradient(ellipse ${b.w}% ${b.h}% at ${b.x.toFixed(1)}% ${b.y.toFixed(1)}%, ${rgba} 0%, ${rgba} 42%, transparent 100%)`
    })
    .join(', ')
}

/** The base the blobs sit on. Matches the desktop overlay's background-color. */
export const BLOB_BASE_COLOR = '#0d0d0f'

/** The base for the light theme. Matches index.html's --bg under
 *  html[data-theme="light"], which is what the light overlay falls back to
 *  when art theming is off - kept the same colour so turning it on and off
 *  is not itself a visible flash. */
export const BLOB_BASE_COLOR_LIGHT = '#f2f2f7'

const luminance = (r: number, g: number, b: number) => 0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b)
const contrastOnLight = (r: number, g: number, b: number) => (luminance(0xf2, 0xf2, 0xf7) + 0.05) / (luminance(r, g, b) + 0.05)

/** The accent as light mode shows it: darkened in Oklab lightness, hue and
 *  chroma kept, until it reads at 4.5:1 on the light background (#f2f2f7),
 *  since the accent is link and label text too. A dark enough one is
 *  unchanged. Pale accents like the default waterfall blue (1.7:1) need it. */
export function readableOnLight(hex: string): string {
  let c = { r: parseInt(hex.slice(1, 3), 16), g: parseInt(hex.slice(3, 5), 16), b: parseInt(hex.slice(5, 7), 16) }
  if ([c.r, c.g, c.b].some(Number.isNaN)) return hex
  const lab = srgbToOklab(c.r, c.g, c.b)
  while (contrastOnLight(c.r, c.g, c.b) < 4.5 && lab.L > 0) {
    lab.L -= 0.01
    c = oklabToSrgb(lab)
  }
  return '#' + [c.r, c.g, c.b].map(v => v.toString(16).padStart(2, '0')).join('')
}

/** How often to recompute blob positions, in ms, as shipped. The drift loop
 *  reads blobTuning.frameMs so the debug panel can turn it. */
export const BLOB_FRAME_MS = SHIPPED_BLOB_TUNING.frameMs
