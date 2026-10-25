// Recompress each DMG electron-builder made as ULMO (LZMA): 125 MB to about
// 96 MB. electron-builder 24's dmg.format stops at ULFO, so this converts its
// UDZO output afterwards. ULMO needs macOS 10.15, below Electron's own floor.
//
// The updater checks GitHub's digest of the uploaded file, so converting
// before upload is safe. The .blockmap describes the old bytes and nothing
// reads it, so it goes.

const { execFileSync } = require('child_process')
const fs = require('fs')

exports.default = async function dmgLzma({ artifactPaths }) {
  for (const dmg of artifactPaths.filter(p => p.endsWith('.dmg'))) {
    const tmp = dmg.replace(/\.dmg$/, '.ulmo.dmg')
    execFileSync('/usr/bin/hdiutil', ['convert', dmg, '-format', 'ULMO', '-ov', '-quiet', '-o', tmp])
    fs.renameSync(tmp, dmg)
    fs.rmSync(`${dmg}.blockmap`, { force: true })
  }
  return artifactPaths.filter(p => !p.endsWith('.dmg.blockmap'))
}
