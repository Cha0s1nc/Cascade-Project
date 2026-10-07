const sharp = require('sharp')
const path = require('path')
const fs = require('fs')
const { execSync } = require('child_process')

const OUT = path.join(__dirname, '../assets')

// Largest icon produced. Nothing here scales past it, so a raster source at
// this size loses nothing to a vector one - see resolveSource().
const MAX_SIZE = 1024

// Source candidates, best first. Named source.* rather than icon.* on purpose:
// icon.png/.ico/.icns are what this script WRITES, so a source sharing one of
// those names would be overwritten by its own output halfway through the run.
const CANDIDATES = ['source.svg', 'source.png']
const GENERATED = path.join(OUT, 'icon.png')

// Where the artwork's subject sits, as a fraction of its width and height. The
// installer images are small crops, not the whole square, and they are centered
// here so they land on the waterfall rather than empty sky.
// ponytail: tuned by eye for the current source.png; move it if the art changes.
const INSTALLER_FOCUS = { x: 0.66, y: 0.26 }

// Corner radius of the app icon, as a fraction of its width. The artwork is a
// full-bleed square, and every platform draws app icons with rounded corners.
// The installer images below are deliberately not rounded: they are crops of
// the artwork filling a rectangle, not an icon.
const ICON_RADIUS = 0.15

// Apple's icon grid: inside a 1024 canvas the rounded square is 824 wide with a
// 185.4 corner radius, and the rest is transparent margin. A full-bleed icon
// ignores that and sits visibly larger than every other app in the Dock.
const MAC_BODY = 824 / 1024
const MAC_RADIUS = 185.4 / 824

// Sizes written into icon.ico. Windows picks the nearest and scales it, so
// shipping the small ones keeps the taskbar and Explorer crisp.
const ICO_SIZES = [16, 32, 48, 64, 128, 256]

// Linux icon theme sizes, one file each in assets/linux-icons named
// <size>x<size>.png, which electron-builder installs into
// /usr/share/icons/hicolor/<size>x<size>/apps. Given the single 1024px
// icon.png instead, it installed it into hicolor/0x0, a folder no icon theme
// looks in, and the menu entry had no icon. 1024 is left out on purpose:
// hicolor has no 1024x1024 folder either.
// The 128 also doubles as the logo on the sign-in and first-run screens
// (index.html), which is why package.json ships it inside the app.
const LINUX_SIZES = [16, 24, 32, 48, 64, 128, 256, 512]

function q(p) { return `"${p}"` }

/** The artwork as a rounded square PNG of `size` px. `radius` is a fraction of
 *  the width. Rounding is done at full size and scaled down, rather than
 *  re-cutting a tiny mask per size, so the curve stays cleanly antialiased. */
async function roundedPng(src, size, radius, canvas = size, pad = 0) {
  const mask = Buffer.from(
    `<svg width="${MAX_SIZE}" height="${MAX_SIZE}">` +
    `<rect width="${MAX_SIZE}" height="${MAX_SIZE}" rx="${MAX_SIZE * radius}" ry="${MAX_SIZE * radius}" fill="#fff"/></svg>`)
  // Two passes: sharp honours only one resize per pipeline, so masking at full
  // size and scaling down have to be separate.
  const full = await sharp(src).resize(MAX_SIZE, MAX_SIZE)
    .composite([{ input: mask, blend: 'dest-in' }]).png().toBuffer()
  const body = await sharp(full).resize(size, size).png().toBuffer()
  if (!pad) return body
  // Centered on a transparent canvas, for the margin macOS icons are drawn with.
  return sharp({ create: { width: canvas, height: canvas, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: body, left: pad, top: pad }]).png().toBuffer()
}

/** A multi-size .ico. Each entry is a PNG, which every Windows since Vista
 *  reads, so there is no BMP-with-AND-mask branch to get wrong. */
function writeIco(file, images) {
  const header = Buffer.alloc(6)
  header.writeUInt16LE(1, 2)                // type: ICO
  header.writeUInt16LE(images.length, 4)
  let offset = 6 + images.length * 16
  const entries = images.map(({ size, png }) => {
    const e = Buffer.alloc(16)
    e.writeUInt8(size >= 256 ? 0 : size, 0)  // 0 means 256
    e.writeUInt8(size >= 256 ? 0 : size, 1)
    e.writeUInt16LE(1, 4)                    // colour planes
    e.writeUInt16LE(32, 6)                   // bits per pixel
    e.writeUInt32LE(png.length, 8)
    e.writeUInt32LE(offset, 12)
    offset += png.length
    return e
  })
  fs.writeFileSync(file, Buffer.concat([header, ...entries, ...images.map(i => i.png)]))
}

/** NSIS only takes 24-bit BMP for its installer images, and sharp cannot write
 *  BMP, so this is the minimal encoder: a 54 byte header, then bottom-up BGR
 *  rows padded to 4 bytes. `raw` is sharp's output with 3 channels. */
function writeBmp(file, { data, info }) {
  const { width: w, height: h } = info
  const row = Math.ceil((w * 3) / 4) * 4
  const buf = Buffer.alloc(54 + row * h)
  buf.write('BM', 0)
  buf.writeUInt32LE(buf.length, 2)
  buf.writeUInt32LE(54, 10)       // pixel data offset
  buf.writeUInt32LE(40, 14)       // BITMAPINFOHEADER size
  buf.writeInt32LE(w, 18)
  buf.writeInt32LE(h, 22)         // positive = bottom-up
  buf.writeUInt16LE(1, 26)        // planes
  buf.writeUInt16LE(24, 28)       // bits per pixel
  buf.writeUInt32LE(row * h, 34)
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const s = (y * w + x) * 3
      const d = 54 + (h - 1 - y) * row + x * 3
      buf[d] = data[s + 2]; buf[d + 1] = data[s + 1]; buf[d + 2] = data[s]
    }
  }
  fs.writeFileSync(file, buf)
}

/** A width x height crop of the artwork scaled to `scale` px square, centered
 *  on INSTALLER_FOCUS and clamped so it never runs off the edge. */
async function installerImage(src, file, scale, width, height) {
  const left = Math.round(Math.min(scale - width,  Math.max(0, scale * INSTALLER_FOCUS.x - width / 2)))
  const top  = Math.round(Math.min(scale - height, Math.max(0, scale * INSTALLER_FOCUS.y - height / 2)))
  const raw = await sharp(src).resize(scale, scale).extract({ left, top, width, height })
    .flatten({ background: '#111113' }).raw().toBuffer({ resolveWithObject: true })
  writeBmp(path.join(OUT, file), raw)
  console.log(`  ${file}`)
}

/** Which file to generate from: an explicit CLI argument, else the first
 *  candidate that exists. Vector wins when both are present, since it is the
 *  better master, but it says so out loud - silently generating from a stale
 *  source.svg after someone dropped in new artwork as source.png is exactly
 *  the kind of thing that ships the wrong logo. */
function resolveSource() {
  const arg = process.argv[2]
  if (arg) {
    const p = path.resolve(arg)
    if (!fs.existsSync(p)) throw new Error(`No such file: ${arg}`)
    return p
  }
  const found = CANDIDATES.map(n => path.join(OUT, n)).filter(p => fs.existsSync(p))
  if (!found.length) {
    throw new Error(
      `No icon source found. Put one of these in assets/:\n` +
      CANDIDATES.map(n => `  ${n}`).join('\n') +
      `\nOr pass a path: npm run icons -- path/to/artwork.png`)
  }
  if (found.length > 1) {
    console.log(`Note: ${found.map(p => path.basename(p)).join(' and ')} both exist.`)
    console.log(`      Using ${path.basename(found[0])}. To use the other:`)
    console.log(`      npm run icons -- assets/${path.basename(found[1])}\n`)
  }
  return found[0]
}

/** A raster source below MAX_SIZE would be upscaled, which looks soft at
 *  exactly the sizes people notice (the dock and the installer). Vector is
 *  exempt: sharp renders it at whatever size is asked for. */
async function checkSize(src) {
  if (path.extname(src).toLowerCase() === '.svg') return
  const { width, height } = await sharp(src).metadata()
  if (width < MAX_SIZE || height < MAX_SIZE) {
    throw new Error(
      `${path.basename(src)} is ${width}x${height}, and icons are generated up ` +
      `to ${MAX_SIZE}x${MAX_SIZE}.\nUpscaling would look soft. Ask for a ` +
      `${MAX_SIZE}x${MAX_SIZE} export or an SVG.`)
  }
  if (width !== height) {
    console.log(`Warning: ${path.basename(src)} is ${width}x${height}, not square.`)
    console.log(`         It will be squashed to fit. Crop it first if that matters.\n`)
  }
}

// ── Apple (apple/App) ────────────────────────────────────────────────────────
//
// Asset catalogs for the iOS and tvOS targets, written whole each run (both
// folders are generated: edit source.png, not them). iOS takes one opaque
// full-bleed 1024 square and rounds it itself. tvOS wants a layered icon (the
// tilt-and-shine on the home screen) and a top shelf banner. The art is flat,
// so the back layer carries it and the front layer is empty.
// ponytail: give the artist's layered export (waterfall on its own layer) to
// the front layer for real parallax.

const APPLE = path.join(__dirname, '../apple/App')
// Where the landscape crops sit, as a fraction of the height: the waterfall.
// ponytail: tuned by eye for the current source.png, like INSTALLER_FOCUS.
const TV_FOCUS_Y = 0.55
// The artwork's own night blue, behind anything that has to be opaque.
const BACKDROP = '#06104a'
const XCODE_INFO = { version: 1, author: 'xcode' }

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n')
}

/** The artwork filling w x h: scaled to width w and cropped to h rows around
 *  TV_FOCUS_Y. Opaque, as every app icon layer but the front has to be. */
async function landscape(src, w, h) {
  const top = Math.round(Math.min(w - h, Math.max(0, w * TV_FOCUS_Y - h / 2)))
  return sharp(src).resize(w, w).extract({ left: 0, top, width: w, height: h })
    .flatten({ background: BACKDROP }).png().toBuffer()
}

/** The top shelf: far wider than the square art, and stretching a 1024 source
 *  to 1920 or 3840 across reads as blur. So the art sits sharp in the middle at
 *  full height, feathered into a blurred copy of itself that fills the width. */
async function topShelf(src, w, h) {
  // Blurred hard and dimmed, so it reads as the art's ambient color rather
  // than a second, soft copy of the waterfall beside the sharp one.
  const back = await sharp(await landscape(src, w, h)).blur(Math.round(h / 9))
    .modulate({ brightness: 0.55 }).png().toBuffer()
  const feather = Buffer.from(
    `<svg width="${h}" height="${h}"><defs><linearGradient id="f">` +
    `<stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".15" stop-color="#fff"/>` +
    `<stop offset=".85" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>` +
    `</linearGradient></defs><rect width="${h}" height="${h}" fill="url(#f)"/></svg>`)
  const art = await sharp(src).resize(h, h).flatten({ background: BACKDROP })
    .composite([{ input: feather, blend: 'dest-in' }]).png().toBuffer()
  return sharp(back).composite([{ input: art, left: Math.round((w - h) / 2), top: 0 }]).png().toBuffer()
}

/** An imageset of tv images, one per scale: [{ scale: 1, png }, ...]. */
function writeImageset(dir, name, images) {
  for (const { scale, png } of images) fs.writeFileSync(path.join(dir, `${name}@${scale}x.png`), png)
  writeJson(path.join(dir, 'Contents.json'), {
    images: images.map(({ scale }) => ({ idiom: 'tv', filename: `${name}@${scale}x.png`, scale: `${scale}x` })),
    info: XCODE_INFO,
  })
}

/** A layered tvOS icon at width x height (1x), with the art on the back
 *  layer and a transparent front. */
async function writeImagestack(dir, src, width, height, scales) {
  const layers = { Front: [], Back: [] }
  for (const scale of scales) {
    const [w, h] = [width * scale, height * scale]
    layers.Back.push({ scale, png: await landscape(src, w, h) })
    layers.Front.push({ scale, png: await sharp({ create: { width: w, height: h, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).png().toBuffer() })
  }
  for (const [layer, images] of Object.entries(layers)) {
    const layerDir = path.join(dir, `${layer}.imagestacklayer`)
    fs.mkdirSync(path.join(layerDir, 'Content.imageset'), { recursive: true })
    writeJson(path.join(layerDir, 'Contents.json'), { info: XCODE_INFO })
    writeImageset(path.join(layerDir, 'Content.imageset'), layer.toLowerCase(), images)
  }
  writeJson(path.join(dir, 'Contents.json'), {
    layers: [{ filename: 'Front.imagestacklayer' }, { filename: 'Back.imagestacklayer' }],
    info: XCODE_INFO,
  })
}

async function appleIcons(src) {
  // iOS: one 1024 square, opaque (the App Store refuses an icon with alpha).
  const ios = path.join(APPLE, 'Assets-iOS.xcassets')
  fs.rmSync(ios, { recursive: true, force: true })
  writeJson(path.join(ios, 'Contents.json'), { info: XCODE_INFO })
  const iconSet = path.join(ios, 'AppIcon.appiconset')
  fs.mkdirSync(iconSet, { recursive: true })
  await sharp(src).resize(MAX_SIZE, MAX_SIZE).flatten({ background: BACKDROP }).png().toFile(path.join(iconSet, 'AppIcon.png'))
  writeJson(path.join(iconSet, 'Contents.json'), {
    images: [{ filename: 'AppIcon.png', idiom: 'universal', platform: 'ios', size: '1024x1024' }],
    info: XCODE_INFO,
  })
  console.log('  apple/App/Assets-iOS.xcassets')

  // tvOS: the home screen icon, the App Store icon, and both top shelf sizes.
  const tv = path.join(APPLE, 'Assets-tvOS.xcassets')
  fs.rmSync(tv, { recursive: true, force: true })
  writeJson(path.join(tv, 'Contents.json'), { info: XCODE_INFO })
  const brand = path.join(tv, 'App Icon & Top Shelf Image.brandassets')
  await writeImagestack(path.join(brand, 'App Icon.imagestack'), src, 400, 240, [1, 2])
  await writeImagestack(path.join(brand, 'App Icon - App Store.imagestack'), src, 1280, 768, [1])
  for (const [name, w] of [['Top Shelf Image', 1920], ['Top Shelf Image Wide', 2320]]) {
    const dir = path.join(brand, `${name}.imageset`)
    fs.mkdirSync(dir, { recursive: true })
    writeImageset(dir, name.toLowerCase().replace(/ /g, '-'), [
      { scale: 1, png: await topShelf(src, w, 720) },
      { scale: 2, png: await topShelf(src, w * 2, 1440) },
    ])
  }
  writeJson(path.join(brand, 'Contents.json'), {
    assets: [
      { filename: 'App Icon - App Store.imagestack', idiom: 'tv', role: 'primary-app-icon', size: '1280x768' },
      { filename: 'App Icon.imagestack', idiom: 'tv', role: 'primary-app-icon', size: '400x240' },
      { filename: 'Top Shelf Image Wide.imageset', idiom: 'tv', role: 'top-shelf-image-wide', size: '2320x720' },
      { filename: 'Top Shelf Image.imageset', idiom: 'tv', role: 'top-shelf-image', size: '1920x720' },
    ],
    info: XCODE_INFO,
  })
  console.log('  apple/App/Assets-tvOS.xcassets')
}

async function run() {
  const SRC = resolveSource()
  if (path.resolve(SRC) === GENERATED) {
    throw new Error(`assets/icon.png is generated by this script, so it cannot also be the source.\nRename it to assets/source.png.`)
  }
  await checkSize(SRC)
  console.log(`Generating icons from ${path.basename(SRC)}...`)

  // icon.png (Linux)
  await sharp(await roundedPng(SRC, MAX_SIZE, ICON_RADIUS)).toFile(path.join(OUT, 'icon.png'))
  console.log('  icon.png')

  // Linux icon theme sizes (see LINUX_SIZES)
  const linuxDir = path.join(OUT, 'linux-icons')
  fs.mkdirSync(linuxDir, { recursive: true })
  for (const size of LINUX_SIZES) {
    fs.writeFileSync(path.join(linuxDir, `${size}x${size}.png`), await roundedPng(SRC, size, ICON_RADIUS))
  }
  console.log(`  linux-icons/ (${LINUX_SIZES.join(', ')})`)

  // icon.icns (macOS) via iconutil, on Apple's grid rather than full bleed
  if (process.platform === 'darwin') {
    const icnsDir = path.join(OUT, 'icon.iconset')
    fs.mkdirSync(icnsDir, { recursive: true })
    const icnsMap = {
      16:   'icon_16x16',
      32:   'icon_16x16@2x',
      64:   'icon_32x32@2x',
      128:  'icon_128x128',
      256:  'icon_128x128@2x',
      512:  'icon_256x256@2x',
      [MAX_SIZE]: 'icon_512x512@2x',
    }
    for (const [size, name] of Object.entries(icnsMap)) {
      const canvas = Number(size)
      const body = Math.round(canvas * MAC_BODY)
      const png = await roundedPng(SRC, body, MAC_RADIUS, canvas, Math.round((canvas - body) / 2))
      fs.writeFileSync(path.join(icnsDir, `${name}.png`), png)
    }
    execSync(`iconutil -c icns ${q(icnsDir)} -o ${q(path.join(OUT, 'icon.icns'))}`)
    fs.rmSync(icnsDir, { recursive: true })
    console.log('  icon.icns')
  } else {
    console.log('  icon.icns - skipped (run on macOS to generate)')
  }

  // icon.ico (Windows)
  const icoImages = []
  for (const size of ICO_SIZES) icoImages.push({ size, png: await roundedPng(SRC, size, ICON_RADIUS) })
  writeIco(path.join(OUT, 'icon.ico'), icoImages)
  console.log(`  icon.ico (${ICO_SIZES.join(', ')})`)

  // Windows installer art. Sizes are fixed by NSIS: the welcome and finish page
  // sidebar is 164x314, the header on every other page is 150x57.
  await installerImage(SRC, 'installer-sidebar.bmp', 314, 164, 314)
  await installerImage(SRC, 'installer-header.bmp', 300, 150, 57)

  await appleIcons(SRC)

  console.log('\nDone. Icons written to assets/ and apple/App/')
}

run().catch(err => { console.error(err.message || err); process.exit(1) })
