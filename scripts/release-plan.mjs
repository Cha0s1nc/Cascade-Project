// The release workflow's decisions, made by src/core/release-plan.ts:
//
//   node scripts/release-plan.mjs plan       what this push or manual run does
//   node scripts/release-plan.mjs versions   the versions.json for a release
//   node scripts/release-plan.mjs files P    platform P's file patterns, one per line
//   node scripts/release-plan.mjs check-pr   fail if a pull request carries a release marker
//
// Everything comes in through environment variables, never through the
// workflow's ${{ }} expressions: commit messages are read from git here, so
// no text a contributor wrote is ever pasted into a shell script. Answers go
// to $GITHUB_OUTPUT as key=value lines (or stdout when it is unset).
//
// plan:     EVENT, BRANCH, BEFORE, AFTER, LAST_VERSION, TAGS (one per line),
//           INPUT_BUMP, INPUT_PLATFORMS, INPUT_BETA
// versions: VERSION, REBUILT, CARRIED (comma lists), PREVIOUS_FILE (optional
//           path to the last release's versions.json), PREVIOUS_VERSION
// check-pr: BASE, HEAD (commit shas), TITLE (the pull request's title)
import { execFileSync } from 'node:child_process'
import { appendFileSync, existsSync, readFileSync } from 'node:fs'

// See scripts/changelog-section.mjs: only Node's harmless module-type warning
// is dropped, so it does not read like a failure in the CI log.
const printWarning = process.listeners('warning')
process.removeAllListeners('warning')
process.on('warning', w => {
  if (w.code !== 'MODULE_TYPELESS_PACKAGE_JSON') for (const print of printWarning) print(w)
})
const { PLATFORMS, PLATFORM_FILES, markerLines, planRelease, versionsFor } = await import('../src/core/release-plan.ts')

const env = process.env
const git = (...args) => execFileSync('git', args, { encoding: 'utf8' })
const list = s => (s ?? '').split(',').map(x => x.trim()).filter(Boolean)
const output = pairs => {
  const text = Object.entries(pairs).map(([k, v]) => `${k}=${v}`).join('\n') + '\n'
  if (env.GITHUB_OUTPUT) appendFileSync(env.GITHUB_OUTPUT, text)
  else process.stdout.write(text)
}

/** Commit messages and changed files of the pushed range. */
function pushedRange(before, after) {
  const known = sha => { try { git('cat-file', '-e', `${sha}^{commit}`); return true } catch { return false } }
  // A new branch (all zeros) or a force push whose old head is gone: fall
  // back to the head commit alone.
  if (!before || /^0+$/.test(before) || !known(before)) {
    return {
      messages: [git('log', '-1', '--format=%B', after)],
      files: git('diff-tree', '--no-commit-id', '--name-only', '-r', '--root', after).split('\n').filter(Boolean),
    }
  }
  return {
    messages: git('log', '--format=%B%x00', `${before}..${after}`).split('\0').map(s => s.trim()).filter(Boolean),
    files: git('diff', '--name-only', before, after).split('\n').filter(Boolean),
  }
}

const command = process.argv[2]
if (command === 'plan') {
  const range = env.EVENT === 'push' ? pushedRange(env.BEFORE, env.AFTER) : { messages: [], files: [] }
  const plan = planRelease({
    event: env.EVENT === 'push' ? 'push' : 'workflow_dispatch',
    branch: env.BRANCH ?? '',
    messages: range.messages,
    files: range.files,
    lastVersion: (env.LAST_VERSION ?? '').replace(/^v/, ''),
    tags: (env.TAGS ?? '').split('\n').map(s => s.trim()).filter(Boolean),
    available: PLATFORMS.filter(p => p === 'desktop' || existsSync(p)),
    dispatch: { bump: env.INPUT_BUMP, platforms: env.INPUT_PLATFORMS, beta: env.INPUT_BETA === 'true' },
  })
  console.error(`Plan: ${plan.mode} ${plan.version || ''} [${plan.platforms.join(', ')}] (${plan.reason})`)
  output({
    mode: plan.mode, version: plan.version, tag: plan.tag, platforms: plan.platforms.join(','),
    ...Object.fromEntries(PLATFORMS.map(p => [p, String(plan.platforms.includes(p))])),
    prerelease: String(plan.prerelease), publish: String(plan.publish),
  })
} else if (command === 'versions') {
  let previous = null
  if (env.PREVIOUS_FILE && existsSync(env.PREVIOUS_FILE)) {
    try { previous = JSON.parse(readFileSync(env.PREVIOUS_FILE, 'utf8').slice(0, 4096)) } catch { previous = null }
  }
  const versions = versionsFor({
    version: env.VERSION ?? '', rebuilt: list(env.REBUILT), carried: list(env.CARRIED),
    previous: previous && typeof previous === 'object' && !Array.isArray(previous) ? previous : null,
    previousVersion: (env.PREVIOUS_VERSION ?? '').replace(/^v/, ''),
  })
  process.stdout.write(JSON.stringify(versions) + '\n')
} else if (command === 'check-pr') {
  // The title counts too: a squash merge makes it the commit's first line.
  const subjects = git('log', '--format=%s', `${env.BASE}..${env.HEAD}`).split('\n').filter(Boolean)
  const found = markerLines([env.TITLE ?? '', ...subjects])
  if (found.length) {
    console.error('Release markers are for the maintainer only. Remove them from the pull request title and commit first lines:')
    for (const line of found) console.error(`  ${line}`)
    process.exit(1)
  }
  console.error(`No release markers in the title or ${subjects.length} commit(s).`)
} else if (command === 'files' && PLATFORMS.includes(process.argv[3])) {
  process.stdout.write(PLATFORM_FILES[process.argv[3]].join('\n') + '\n')
} else {
  console.error('Usage: node scripts/release-plan.mjs plan|versions|files <platform>|check-pr')
  process.exit(2)
}
