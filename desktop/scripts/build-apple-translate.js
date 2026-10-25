// Builds the Apple Translation helper (native/apple-translate/main.swift) into
// build/apple-translate/apple-translate.
//
// macOS only. Anywhere else this does nothing, so it can sit in build:ts for
// every platform without breaking the Windows and Linux builds.
//
// It needs the macOS 26 SDK or newer: TranslationSession(installedSource:
// target:) is new in 26 and is the only way to translate without a SwiftUI
// view. The helper is built with a macOS 26 deployment target, and main.js only
// offers Apple Translation on macOS 26+, so older Macs never launch it.
//
// Without that SDK: in CI this fails the build, so a release can never quietly
// ship without the feature. Locally it warns and skips, so a Mac without Xcode
// can still run Cascade, with the Apple Translation setting simply not shown.

const { execFileSync } = require('child_process')
const fs = require('fs')
const path = require('path')

const ROOT = path.join(__dirname, '..')
const SRC = path.join(ROOT, 'native', 'apple-translate', 'main.swift')
const OUT_DIR = path.join(ROOT, 'build', 'apple-translate')
const OUT = path.join(OUT_DIR, 'apple-translate')

if (process.platform !== 'darwin') {
  console.log('apple-translate: not macOS, skipped')
  process.exit(0)
}

function unavailable(reason) {
  if (process.env.CI) throw new Error(`apple-translate: ${reason}`)
  console.warn(`apple-translate: ${reason}. Skipped; Apple Translation will not be offered by this build.`)
  fs.rmSync(OUT, { force: true })
  process.exit(0)
}

let sdk
try {
  sdk = execFileSync('xcrun', ['--sdk', 'macosx', '--show-sdk-version'], { encoding: 'utf8' }).trim()
} catch {
  unavailable('no macOS SDK found (install Xcode 26 or newer)')
}
if (parseInt(sdk, 10) < 26) unavailable(`macOS SDK ${sdk} is too old, 26 or newer is required`)

fs.mkdirSync(OUT_DIR, { recursive: true })
execFileSync('xcrun', [
  '--sdk', 'macosx', 'swiftc',
  '-O',
  // Swift 5 mode: TranslationSession is not Sendable, and this single-threaded
  // request loop gains nothing from Swift 6's strict checking of that.
  '-swift-version', '5',
  '-parse-as-library',
  '-target', 'arm64-apple-macos26.0',
  SRC,
  '-o', OUT,
], { stdio: 'inherit' })

console.log(`apple-translate -> build/apple-translate/ (macOS SDK ${sdk})`)
