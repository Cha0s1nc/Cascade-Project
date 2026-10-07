import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

// electron-builder strips the "build" section from the package.json it packs
// into the app, so reading it at runtime works in a dev run and throws in every
// shipped copy. That is how every Mac update in 2.1.0 and 2.2.0 hung.
test('shipped code never reads build settings from package.json', () => {
  for (const file of ['main.js', 'mac-update.js']) {
    const src = readFileSync(new URL(`../${file}`, import.meta.url), 'utf8')
    assert.doesNotMatch(src, /package\.json['"]\)\s*\.build\b/, `${file} reads package.json's build section`)
  }
})

// A file main.js requires but build.files leaves out works in a dev run and
// crashes the packaged app at launch. build/update-release.js is the first
// generated one, and build/ is not in git, so nothing else would notice.
test('every local file main.js requires is shipped', () => {
  const src = readFileSync(new URL('../main.js', import.meta.url), 'utf8')
  const files: string[] = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).build.files
  const required = [...src.matchAll(/require\(\s*['"]\.\/([^'"]+)['"]\s*\)/g)].map(m => m[1])
  assert.ok(required.includes('build/update-release'), 'expected main.js to require the updater bundle')
  for (const name of required) {
    const shipped = [name, `${name}.js`].some(f => files.includes(f))
    assert.ok(shipped, `main.js requires ./${name} but package.json build.files does not ship it`)
  }
})

test('the bundles main.js requires are built by build:ts', () => {
  const scripts = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).scripts
  for (const entry of ['update-release', 'changelog', 'window-state', 'custom-headers', 'offline-index']) assert.match(scripts['build:main'], new RegExp(`src/core/${entry}\\.ts\\b`))
  assert.match(scripts['build:main'], /--outdir=build\b/)
  assert.match(scripts['build:ts'], /npm run build:main\b/)
})
