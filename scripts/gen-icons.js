const sharp = require('sharp')
const path = require('path')
const fs = require('fs')
const { execSync } = require('child_process')

const SRC = path.join(__dirname, '../assets/icon.svg')
const OUT = path.join(__dirname, '../assets')

function q(p) { return `"${p}"` }

async function run() {
  console.log('Generating icons from icon.svg...')

  const sizes = [16, 32, 48, 64, 128, 256, 512, 1024]
  for (const s of sizes) {
    await sharp(SRC).resize(s, s).png().toFile(path.join(OUT, `icon-${s}.png`))
  }

  // icon.png (Linux)
  fs.copyFileSync(path.join(OUT, 'icon-1024.png'), path.join(OUT, 'icon.png'))
  console.log('  icon.png')

  // icon.icns (macOS) via iconutil
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
      1024: 'icon_512x512@2x',
    }
    for (const [s, name] of Object.entries(icnsMap)) {
      fs.copyFileSync(path.join(OUT, `icon-${s}.png`), path.join(icnsDir, `${name}.png`))
    }
    execSync(`iconutil -c icns ${q(icnsDir)} -o ${q(path.join(OUT, 'icon.icns'))}`)
    fs.rmSync(icnsDir, { recursive: true })
    console.log('  icon.icns')
  } else {
    console.log('  icon.icns — skipped (run on macOS to generate)')
  }

  // icon.ico (Windows) — embed multiple sizes using sharp + manual ICO construction
  // Simple approach: use the 256px png as a single-image ICO
  // (electron-builder accepts a png renamed .ico for basic builds)
  const png256 = fs.readFileSync(path.join(OUT, 'icon-256.png'))
  const icoPath = path.join(OUT, 'icon.ico')

  // Build a minimal valid ICO with one 256x256 entry
  const header = Buffer.alloc(6)
  header.writeUInt16LE(0, 0)   // reserved
  header.writeUInt16LE(1, 2)   // type: ICO
  header.writeUInt16LE(1, 4)   // count: 1 image

  const entry = Buffer.alloc(16)
  entry.writeUInt8(0, 0)       // width  (0 = 256)
  entry.writeUInt8(0, 1)       // height (0 = 256)
  entry.writeUInt8(0, 2)       // color count
  entry.writeUInt8(0, 3)       // reserved
  entry.writeUInt16LE(1, 4)    // color planes
  entry.writeUInt16LE(32, 6)   // bits per pixel
  entry.writeUInt32LE(png256.length, 8)    // size of image data
  entry.writeUInt32LE(6 + 16, 12)          // offset of image data

  fs.writeFileSync(icoPath, Buffer.concat([header, entry, png256]))
  console.log('  icon.ico')

  // Clean up intermediate pngs
  for (const s of sizes) {
    const f = path.join(OUT, `icon-${s}.png`)
    if (s !== 1024) fs.unlinkSync(f)
  }
  // rename 1024 to icon.png already done above, remove the numbered one
  try { fs.unlinkSync(path.join(OUT, 'icon-1024.png')) } catch {}

  console.log('\nDone. Icons written to assets/')
}

run().catch(err => { console.error(err.message || err); process.exit(1) })
