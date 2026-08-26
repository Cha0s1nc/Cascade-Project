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

/** A blob colour. `hue` is the bucket it came from, in degrees. */
export interface BlobColor {
  r: number
  g: number
  b: number
  hue: number
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

export function oklabToSrgb(c: Oklab): { r: number; g: number; b: number } {
  const l_ = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b
  const m_ = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b
  const s_ = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b
  const l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
  return {
    r: linearToSrgb(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    g: linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    b: linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
  }
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

/** How many clusters to find before ranking. More than we return, so a small
 *  vivid accent gets its own cluster instead of being absorbed by a big dull
 *  one. */
const K = 5

/** Iterations of Lloyd's algorithm. Converges well before this on 6400 px. */
const KMEANS_ITERATIONS = 12

/** Minimum perceptual gap between two returned colours. Without it the top
 *  three are routinely three shades of the same thing, which reads as a
 *  one-colour background. */
const MIN_SEPARATION = 0.12

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

  // Keep the pixels that could plausibly be "the colour of this cover".
  // Near-black and near-white are dropped because every cover has plenty of
  // both and neither says anything about its palette. The thresholds are loose
  // on purpose: a dark cover should still yield its dark colours rather than
  // fall through to nothing.
  const samples: Oklab[] = []
  for (let i = 0; i < rgba.length; i += 4) {
    if ((rgba[i + 3] as number) < 128) continue
    const c = srgbToOklab(rgba[i] as number, rgba[i + 1] as number, rgba[i + 2] as number)
    if (c.L < 0.08 || c.L > 0.97) continue
    samples.push(c)
  }
  if (samples.length === 0) return []

  const centroids = seedCentroids(samples, K)
  const assignment = new Array<number>(samples.length).fill(0)

  for (let iter = 0; iter < KMEANS_ITERATIONS; iter++) {
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
      return { c, share, score: share * Math.pow(chroma(c) + 0.02, 1.5) }
    })
    .filter(x => x.share > 0.01) // ignore clusters too small to be a real colour
    .sort((a, b) => b.score - a.score)

  const picked: Oklab[] = []
  for (const { c } of ranked) {
    if (picked.length >= n) break
    if (picked.some(p => distance(p, c) < MIN_SEPARATION)) continue
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

// Lightness clamp for a blob colour. Two pairs, picked by which base the blob
// sits on - a colour dark enough to glow on near-black reads as a heavy,
// muddy stain on near-white, so the light pair pushes the whole range paler
// rather than reusing the dark one. Eyeballed against #0d0d0f and #f2f2f7
// respectively; MIN_C (how far a colour must sit from grey to still read as a
// colour, not a shade) is unaffected by which base is in play.
const MIN_L = 0.45        // below this a blob is lost against #0d0d0f
const MAX_L = 0.82        // above this it washes out the content in front of it
// Tuned by eye on 2026-08-26 with the debug panel's live sliders, replacing a
// first guess of 0.68/0.93 that came out washed out. The range is far wider
// than the dark theme's because a light background needs the blob's own
// contrast to carry it: clamping the dark end up to 0.68 flattened every deep
// colour to pastel before the scrims had even been applied.
const MIN_L_LIGHT = 0.29
const MAX_L_LIGHT = 1.00
const MIN_C = 0.06        // below this it reads as grey rather than as a colour

// A blob at a dark-theme SLOTS alpha reads as a glow on the dark base, but the
// same opacity on the light base's near-white is a heavy, solid-looking patch
// - scaled down rather than given its own SLOTS table so the layout (position,
// size, drift) stays identical between themes and only the weight changes.
// 1.00, i.e. no scaling: with the lightness range above doing the work, the
// extra 45% cut was the single biggest cause of the wash-out. Kept as a named
// constant rather than deleted, so the knob is still there if it is ever wanted.
const LIGHT_ALPHA_SCALE = 1.00

/**
 * Runtime-mutable copy of the light-theme knobs above. The constants stay the
 * shipped defaults; this is what the debug panel's sliders actually turn, so
 * dragging one changes the next extraction with no rebuild. Nothing outside
 * the debug panel writes to this - the normal path never mutates it, so it
 * always equals the defaults it was seeded from.
 */
export const lightTuning = {
  minL: MIN_L_LIGHT,
  maxL: MAX_L_LIGHT,
  alphaScale: LIGHT_ALPHA_SCALE,
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
  const minL = light ? lightTuning.minL : MIN_L
  const maxL = light ? lightTuning.maxL : MAX_L

  let { L, a, b } = c
  L = Math.min(maxL, Math.max(minL, L))

  const ch = Math.hypot(a, b)
  if (ch > 0 && ch < MIN_C) {
    const scale = MIN_C / ch
    a *= scale
    b *= scale
  }

  const { r, g, b: bl } = oklabToSrgb({ L, a, b })
  return { r, g, b: bl, hue: hueOf(c) }
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

// Anchors, in percent. Deliberately near the edges so the middle of the screen
// stays dark enough to read text over - the background is a mood, not a
// competitor to the content sitting on top of it.
const SLOTS = [
  { x: 78, y: 16, w: 78, h: 78, alpha: 0.88 },
  { x: 18, y: 82, w: 78, h: 78, alpha: 0.80 },
  { x: 12, y: 18, w: 58, h: 58, alpha: 0.55 },
] as const

/**
 * Where the blobs are at time `t` (seconds). Pure given the current tuning -
 * same inputs and same lightTuning, same output - so a host can drive it from
 * a clock, a test can drive it from a constant.
 *
 * `light` scales blob opacity down for the light theme's base - see
 * lightTuning.alphaScale (defaults to LIGHT_ALPHA_SCALE).
 */
export function driftedBlobs(colors: BlobColor[], drift: DriftParams[], t: number, light = false): Blob[] {
  const alphaScale = light ? lightTuning.alphaScale : 1
  return colors.map((color, i) => {
    const s = SLOTS[i] ?? SLOTS[2]
    const alpha = s.alpha * alphaScale
    const p = drift[i] ?? drift[0]
    if (!p) return { x: s.x, y: s.y, w: s.w, h: s.h, alpha, color }
    return {
      x: s.x + Math.sin(t * p.xF1 + p.xP1) * p.xA1 + Math.sin(t * p.xF2 + p.xP2) * p.xA2,
      y: s.y + Math.cos(t * p.yF1 + p.yP1) * p.yA1 + Math.cos(t * p.yF2 + p.yP2) * p.yA2,
      w: s.w,
      h: s.h,
      alpha,
      color,
    }
  })
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

/**
 * How often to recompute blob positions, in ms.
 *
 * The drift has periods measured in tens of seconds, so rebuilding at 60fps is
 * wasted work for motion this gradual - the desktop throttles to ~15fps and it
 * is visually indistinguishable. On a TV it matters more than on a desktop:
 * this is a background, and it must not cost the frame budget of the content in
 * front of it.
 */
export const BLOB_FRAME_MS = 66
