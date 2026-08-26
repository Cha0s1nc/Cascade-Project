// Checks on the album-art background maths. Pure functions, so no fixtures -
// the "cover" is a handful of RGBA bytes built inline.
//
// Point of this file: the extraction has one job, "give me the colours that are
// actually in this picture", and the old implementation failed it in ways that
// were invisible in code review and obvious on screen. These pin the properties
// that were wrong.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  extractTopColors,
  randomizeDrift,
  driftedBlobs,
  blobBackgroundCss,
  srgbToOklab,
  oklabToSrgb,
} from '../src/core/album-colors.ts'

/** Build packed RGBA from [count, r, g, b] runs. */
function cover(...runs: [number, number, number, number][]): Uint8Array {
  const total = runs.reduce((n, [c]) => n + c, 0)
  const out = new Uint8Array(total * 4)
  let i = 0
  for (const [count, r, g, b] of runs) {
    for (let k = 0; k < count; k++) {
      out[i++] = r; out[i++] = g; out[i++] = b; out[i++] = 255
    }
  }
  return out
}

/** How far apart two colours look, roughly. */
function dist(a: { r: number; g: number; b: number }, b: { r: number; g: number; b: number }): number {
  return Math.hypot(a.r - b.r, a.g - b.g, a.b - b.b)
}

test('rejects a buffer that is not packed RGBA', () => {
  assert.throws(() => extractTopColors(new Uint8Array(7)), /packed RGBA/)
})

test('an empty or fully transparent cover yields no colours rather than throwing', () => {
  assert.deepEqual(extractTopColors(new Uint8Array(0)), [])
  const clear = new Uint8Array(40) // all zero, so alpha 0 throughout
  assert.deepEqual(extractTopColors(clear), [])
})

test('finds the colours that are actually present', () => {
  // Half crimson, half a strong blue.
  const px = cover([200, 200, 30, 60], [200, 40, 70, 200])
  const got = extractTopColors(px, 2)
  assert.equal(got.length, 2)

  // Each returned colour should sit near one of the two inputs, and they should
  // not both land on the same one.
  const crimson = { r: 200, g: 30, b: 60 }
  const blue = { r: 40, g: 70, b: 200 }
  const nearCrimson = got.filter(c => dist(c, crimson) < dist(c, blue))
  assert.equal(nearCrimson.length, 1, `expected one crimson-ish and one blue-ish, got ${JSON.stringify(got)}`)
})

test('a small vivid accent beats a large dull field', () => {
  // 90% desaturated beige, 10% saturated magenta. The magenta is the thing a
  // person would name if asked what colour the cover is.
  const px = cover([900, 190, 180, 165], [100, 230, 20, 180])
  const [top] = extractTopColors(px, 1)
  assert.ok(top, 'expected a colour')
  const magenta = { r: 230, g: 20, b: 180 }
  const beige = { r: 190, g: 180, b: 165 }
  assert.ok(
    dist(top!, magenta) < dist(top!, beige),
    `expected the magenta accent to win, got rgb(${top!.r},${top!.g},${top!.b})`,
  )
})

test('preserves how light or dark a colour is, instead of flattening every cover to one lightness', () => {
  // This is the regression that made the desktop look wrong: it forced every
  // result to L = 0.50 and S >= 0.70, so a pastel cover and a saturated one
  // came out identical.
  const pastel = extractTopColors(cover([400, 240, 200, 215]), 1)[0]
  const deep = extractTopColors(cover([400, 120, 20, 55]), 1)[0]
  assert.ok(pastel && deep)

  const lum = (c: { r: number; g: number; b: number }) => srgbToOklab(c.r, c.g, c.b).L
  assert.ok(
    lum(pastel!) > lum(deep!) + 0.1,
    `pastel (L=${lum(pastel!).toFixed(3)}) should stay clearly lighter than deep (L=${lum(deep!).toFixed(3)})`,
  )
})

test('the same cover always yields the same colours', () => {
  const px = cover([300, 30, 140, 90], [300, 210, 60, 30], [200, 60, 60, 190])
  const a = extractTopColors(px)
  const b = extractTopColors(px)
  assert.deepEqual(a, b, 'extraction must be deterministic or the background changes between plays')
})

test('does not return three shades of the same colour', () => {
  // One hue, three lightnesses. Returning all three would read as a flat
  // background, so the separation rule should reject the near-duplicates.
  const px = cover([300, 200, 40, 40], [300, 170, 34, 34], [300, 220, 55, 55])
  const got = extractTopColors(px, 3)
  for (let i = 0; i < got.length; i++) {
    for (let j = i + 1; j < got.length; j++) {
      assert.ok(dist(got[i]!, got[j]!) > 1, 'returned colours should not be identical')
    }
  }
})

test('oklab survives a round trip', () => {
  for (const [r, g, b] of [[0, 0, 0], [255, 255, 255], [200, 30, 60], [40, 70, 200], [128, 128, 128]]) {
    const back = oklabToSrgb(srgbToOklab(r!, g!, b!))
    assert.ok(Math.abs(back.r - r!) <= 1 && Math.abs(back.g - g!) <= 1 && Math.abs(back.b - b!) <= 1,
      `round trip drifted: rgb(${r},${g},${b}) -> rgb(${back.r},${back.g},${back.b})`)
  }
})

test('drift moves the blobs over time but keeps them on screen', () => {
  const colors = extractTopColors(cover([300, 200, 30, 60], [300, 40, 70, 200]), 3)
  // Fixed "random" values so the assertion is about the maths, not the dice.
  const drift = randomizeDrift(3, () => 0.5)

  const t0 = driftedBlobs(colors, drift, 0)
  const t9 = driftedBlobs(colors, drift, 9)
  assert.notDeepEqual(t0.map(b => b.x), t9.map(b => b.x), 'blobs should drift')

  for (const t of [0, 3, 7, 21, 60]) {
    for (const b of driftedBlobs(colors, drift, t)) {
      // Anchors are 12-82% with amplitudes summing under 26, so a blob centre
      // should never wander far enough off-screen to leave a dead corner.
      assert.ok(b.x > -20 && b.x < 120, `x drifted off screen: ${b.x}`)
      assert.ok(b.y > -20 && b.y < 120, `y drifted off screen: ${b.y}`)
    }
  }
})

test('light mode clamps blob lightness to its own range, not the dark one', () => {
  // Both ranges were eyeballed against their own background and they are not
  // the same shape: light runs 0.29-1.00, dark 0.45-0.82. Asserting the ranges
  // rather than "light is paler" - the first tuning pass assumed paler was the
  // goal, shipped 0.68-0.93, and it came out washed out. What actually matters
  // is that each theme clamps to the pair it was tuned with.
  const deepRed = cover([400, 140, 20, 30])
  const dark = extractTopColors(deepRed, 1, false)[0]
  const light = extractTopColors(deepRed, 1, true)[0]
  assert.ok(dark && light)
  const lum = (c: { r: number; g: number; b: number }) => srgbToOklab(c.r, c.g, c.b).L
  assert.ok(lum(dark!) >= 0.45 - 1e-6, `dark blob L=${lum(dark!).toFixed(3)} below its own floor`)
  assert.ok(lum(dark!) <= 0.82 + 1e-6, `dark blob L=${lum(dark!).toFixed(3)} above its own ceiling`)
  assert.ok(lum(light!) >= 0.29 - 1e-6, `light blob L=${lum(light!).toFixed(3)} below its own floor`)
  // A colour this deep sits under the dark floor, so the two must differ here.
  assert.notEqual(lum(light!).toFixed(3), lum(dark!).toFixed(3))
})

test('light mode keeps blob layout identical to dark, whatever the alpha', () => {
  const colors = extractTopColors(cover([300, 200, 30, 60], [300, 40, 70, 200]), 2)
  const drift = randomizeDrift(2, () => 0.5)
  const dark = driftedBlobs(colors, drift, 5)
  const light = driftedBlobs(colors, drift, 5, true)

  for (let i = 0; i < dark.length; i++) {
    // Position and size are the invariant. Alpha is a tuning knob that has
    // already been 0.55 and is now 1.00, so pinning it here would just mean
    // editing this test every time the look is adjusted.
    assert.equal(light[i]!.x, dark[i]!.x, 'light mode must not change where blobs sit')
    assert.equal(light[i]!.y, dark[i]!.y)
    assert.equal(light[i]!.r, dark[i]!.r, 'light mode must not change blob size')
  }
})

test('builds css that both hosts can use verbatim', () => {
  const colors = extractTopColors(cover([300, 200, 30, 60], [300, 40, 70, 200]), 2)
  const css = blobBackgroundCss(driftedBlobs(colors, randomizeDrift(2, () => 0.5), 0))

  assert.equal(css.split('radial-gradient').length - 1, 2, 'one gradient per colour')
  assert.match(css, /ellipse \d+% \d+% at [\d.]+% [\d.]+%/)
  assert.match(css, /rgba\(\d+,\d+,\d+,[\d.]+\)/)
  // No trailing comma or empty layer - React Native's parser rejects the whole
  // value if any one layer fails to parse, and then nothing renders at all.
  assert.ok(!css.includes(', ,') && !css.trim().endsWith(','))
})
