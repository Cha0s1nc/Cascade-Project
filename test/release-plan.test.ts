import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  bumpOf, isBeta, platformListOf, platformsFromFiles, bumpVersion, nextBetaNumber, planRelease, versionsFor,
  PLATFORM_FILES, platformOfFile, markerLines,
} from '../src/core/release-plan.ts'
import type { PlanInput } from '../src/core/release-plan.ts'

const base = (over: Partial<PlanInput>): PlanInput => ({
  event: 'push', branch: 'stable', messages: [], files: [], lastVersion: '2.2.0', tags: ['v2.2.0'],
  available: ['desktop', 'apple'], ...over,
})

test('bumpOf takes the biggest marker in the range, and only exact markers', () => {
  assert.equal(bumpOf(['fix', 'Release (x.x.X)']), 'patch')
  assert.equal(bumpOf(['Release (x.x.X)', 'Release (x.X.0)']), 'minor')
  assert.equal(bumpOf(['(X.0.0)', '(x.X.0)']), 'major')
  assert.equal(bumpOf(['(x.x.x) is not a marker', '(X.X.X)']), null)
  assert.equal(bumpOf([]), null)
})

test('isBeta reads [BETA] in any case', () => {
  assert.equal(isBeta(['Try the queue [beta]']), true)
  assert.equal(isBeta(['beta without brackets']), false)
})

test('platformListOf reads bracket lists and ignores brackets that are not platforms', () => {
  assert.deepEqual(platformListOf(['Release (x.x.X) [android, desktop]']), ['desktop', 'android'])
  assert.deepEqual(platformListOf(['[BETA] [apple]']), ['apple'])
  assert.deepEqual(platformListOf(['[all]']), ['desktop', 'apple', 'android'])
  assert.deepEqual(platformListOf(['[Desktop]', 'and [apple]']), ['desktop', 'apple'])
  assert.equal(platformListOf(['[BETA]', '[WIP] desktop', '[desktop, wip]']), null)
})

test('platformsFromFiles maps folders to apps, and docs or CI to nothing', () => {
  assert.deepEqual(platformsFromFiles(['apple/App/Sources/X.swift']), ['apple'])
  assert.deepEqual(platformsFromFiles(['renderer.js', 'android/app/build.gradle']), ['desktop', 'android'])
  assert.deepEqual(platformsFromFiles(['README.md', 'CHANGELOG.md', 'docs/plan.md', '.github/workflows/build.yml', 'LICENSE']), [])
  assert.deepEqual(platformsFromFiles(['src/core/queue.ts']), ['desktop'])
  assert.deepEqual(platformsFromFiles(['assets/icon.png']), ['desktop'])
})

test('bumpVersion bumps and refuses anything but x.y.z', () => {
  assert.equal(bumpVersion('2.2.0', 'patch'), '2.2.1')
  assert.equal(bumpVersion('2.2.7', 'minor'), '2.3.0')
  assert.equal(bumpVersion('2.9.9', 'major'), '3.0.0')
  assert.throws(() => bumpVersion('2.2.0-b1', 'patch'))
})

test('nextBetaNumber continues after the highest beta of that base, drafts included', () => {
  assert.equal(nextBetaNumber('2.2.1', ['v2.2.0', 'v2.2.0-b3']), 1)
  assert.equal(nextBetaNumber('2.2.1', ['v2.2.1-b1', 'v2.2.1-b4', 'v12.2.1-b9']), 5)
})

test('stable push with a marker releases the changed platforms, as a draft', () => {
  const p = planRelease(base({ messages: ['Release (x.X.0)'], files: ['renderer.js'] }))
  assert.equal(p.mode, 'release')
  assert.equal(p.version, '2.3.0')
  assert.equal(p.tag, 'v2.3.0')
  assert.deepEqual(p.platforms, ['desktop'])
  assert.equal(p.publish, false)
  assert.equal(p.prerelease, false)
})

test('a platform list overrides the changed folders, and missing apps are dropped', () => {
  const p = planRelease(base({ messages: ['Release (x.x.X) [android, apple]'], files: ['renderer.js'] }))
  assert.deepEqual(p.platforms, ['apple'])
  assert.equal(planRelease(base({ messages: ['Release (x.x.X) [android]'] })).mode, 'none')
})

test('a lone empty trigger commit releases every app in the repo', () => {
  assert.deepEqual(planRelease(base({ messages: ['Release (x.x.X)'], files: [] })).platforms, ['desktop', 'apple'])
})

test('stable push without a marker only builds, and docs alone do nothing', () => {
  const p = planRelease(base({ messages: ['Fix a thing'], files: ['apple/App/Sources/X.swift'] }))
  assert.equal(p.mode, 'build')
  assert.deepEqual(p.platforms, ['apple'])
  assert.equal(p.version, '')
  assert.equal(planRelease(base({ messages: ['Docs'], files: ['README.md'] })).mode, 'none')
})

test('[BETA] on dev publishes a numbered prerelease; dev without it does nothing', () => {
  const p = planRelease(base({ branch: 'dev', messages: ['Try it [BETA] [desktop]'], tags: ['v2.2.0', 'v2.2.1-b1'] }))
  assert.equal(p.mode, 'beta')
  assert.equal(p.version, '2.2.1-b2')
  assert.equal(p.prerelease, true)
  assert.equal(p.publish, true)
  assert.deepEqual(p.platforms, ['desktop'])
  assert.equal(planRelease(base({ branch: 'dev', messages: ['Normal work'], files: ['renderer.js'] })).mode, 'none')
  assert.equal(planRelease(base({ branch: 'dev', messages: ['[BETA] (x.X.0)'] })).version, '2.3.0-b1')
})

test('other branches never release', () => {
  assert.equal(planRelease(base({ branch: 'feature/x', messages: ['Release (X.0.0) [BETA]'] })).mode, 'none')
})

test('manual runs are always drafts: test build, release or beta', () => {
  const d = (dispatch: PlanInput['dispatch']) => planRelease(base({ event: 'workflow_dispatch', branch: 'dev', dispatch }))
  const build = d({})
  assert.equal(build.mode, 'build')
  assert.deepEqual(build.platforms, ['desktop', 'apple'])
  const rel = d({ bump: 'patch', platforms: 'apple' })
  assert.equal(rel.mode, 'release')
  assert.equal(rel.version, '2.2.1')
  assert.deepEqual(rel.platforms, ['apple'])
  assert.equal(rel.publish, false)
  const beta = d({ beta: true, platforms: 'desktop' })
  assert.equal(beta.mode, 'beta')
  assert.equal(beta.publish, false)
  assert.equal(beta.version, '2.2.1-b1')
  assert.equal(d({ platforms: 'nonsense' }).mode, 'none')
})

test('versionsFor takes the new version for rebuilt apps and the old one for carried ones', () => {
  assert.deepEqual(versionsFor({ version: '2.3.1', rebuilt: ['android'], carried: ['desktop', 'apple'],
    previous: { desktop: '2.3.0', apple: '2.3.0' }, previousVersion: '2.3.0' }),
  { desktop: '2.3.0', apple: '2.3.0', android: '2.3.1' })
  // Before versions.json existed, the desktop version was the release's own.
  assert.deepEqual(versionsFor({ version: '2.3.0', rebuilt: ['apple'], carried: ['desktop'], previous: null, previousVersion: '2.2.0' }),
    { desktop: '2.2.0', apple: '2.3.0' })
  // A garbage entry is dropped, not copied.
  assert.deepEqual(versionsFor({ version: '2.3.1', rebuilt: [], carried: ['apple'], previous: { apple: '../x' }, previousVersion: '2.3.0' }), {})
})

test('markers in a commit body do nothing: only the first line counts', () => {
  const explained = 'Rework the release workflow\n\ndev: a [BETA] commit publishes a prerelease; a Release (x.x.X) [desktop] marker releases.'
  assert.equal(planRelease(base({ branch: 'dev', messages: [explained], files: ['renderer.js'] })).mode, 'none')
  const stable = planRelease(base({ messages: [explained], files: ['renderer.js'] }))
  assert.equal(stable.mode, 'build')
  assert.equal(planRelease(base({ branch: 'dev', messages: ['Try the queue [BETA]\n\nbody'] })).mode, 'beta')
})

test('platformOfFile sorts release files by platform and ignores the rest', () => {
  assert.equal(platformOfFile('Cascade-2.3.1-arm64.dmg'), 'desktop')
  assert.equal(platformOfFile('Cascade-2.3.1-tvOS.ipa'), 'apple')
  assert.equal(platformOfFile('Cascade-2.3.1-iOS.xcarchive.zip'), 'apple')
  assert.equal(platformOfFile('versions.json'), null)
  assert.equal(platformOfFile('Cascade-2.3.1.dmg.blockmap'), null)
})

test("build.yml's carry-over patterns match PLATFORM_FILES", () => {
  const yml = readFileSync(new URL('../.github/workflows/build.yml', import.meta.url), 'utf8')
  for (const [p, patterns] of Object.entries(PLATFORM_FILES)) {
    const m = yml.match(new RegExp(`${p}\\)\\s+PATTERNS=\\(([^)]*)\\)`))
    assert.ok(m, `no PATTERNS line for ${p} in build.yml`)
    assert.deepEqual(m[1].split(/\s+/).filter(Boolean).map(s => s.replace(/'/g, '')), patterns)
  }
})

test('markerLines finds release and beta markers, and nothing else', () => {
  assert.deepEqual(markerLines(['Fix the queue', 'Try it [beta]', 'Bump to Release (X.0.0)', 'Mentions x.x.X loosely', '(x.X.0)']),
    ['Try it [beta]', 'Bump to Release (X.0.0)', '(x.X.0)'])
  assert.deepEqual(markerLines([]), [])
})
