// What a push or a manual run of the release workflow should do: release,
// beta, build only, or nothing; at which version; for which platforms. Pure,
// so the rules in docs/release-pipeline-plan.md are tested here rather than
// discovered in a failed CI run. scripts/release-plan.mjs feeds it from git
// and GitHub, and writes the answer out for the workflow.

export type Platform = 'desktop' | 'apple' | 'android'
export const PLATFORMS: readonly Platform[] = ['desktop', 'apple', 'android']

/**
 * Which release files belong to which platform, as `gh release download`
 * patterns. build.yml's carry-over step spells the same lists out in bash;
 * test/release-plan.test.ts fails if the two drift apart.
 */
export const PLATFORM_FILES: Record<Platform, readonly string[]> = {
  desktop: ['*.exe', '*.dmg', '*.AppImage', '*.deb', '*.rpm'],
  apple: ['*.ipa', '*.xcarchive.zip'],
  android: ['*.apk', '*.aab'],
}

/** The platform a release file belongs to, or null (versions.json, blockmaps, anything else). */
export function platformOfFile(name: string): Platform | null {
  return PLATFORMS.find(p => PLATFORM_FILES[p].some(pat => name.endsWith(pat.slice(1)))) ?? null
}

export type Bump = 'major' | 'minor' | 'patch'
export type Mode = 'release' | 'beta' | 'build' | 'none'

// (X.0.0) major, (x.X.0) minor, (x.x.X) patch: the capital marks the part to
// bump. Matched exactly, so a stray "(x.x.x)" is not a release.
const BUMP_MARKERS: [Bump, string][] = [['major', '(X.0.0)'], ['minor', '(x.X.0)'], ['patch', '(x.x.X)']]
const BUMP_RANK: Record<Bump, number> = { major: 3, minor: 2, patch: 1 }

/** The biggest bump marked in any of the messages, or null. */
export function bumpOf(messages: readonly string[]): Bump | null {
  let best: Bump | null = null
  for (const m of messages) {
    for (const [bump, marker] of BUMP_MARKERS) {
      if (m.includes(marker) && (!best || BUMP_RANK[bump] > BUMP_RANK[best])) best = bump
    }
  }
  return best
}

/** Whether any message asks for a beta: `[BETA]`, any case. */
export const isBeta = (messages: readonly string[]): boolean => messages.some(m => /\[beta\]/i.test(m))

/**
 * Platforms named in brackets, e.g. `[android, desktop]` or `[all]`, across all
 * the messages; null when none names any. A bracket is read only if every word
 * in it is a platform or `all`, so `[BETA]` or `[WIP]` is not a platform list.
 */
export function platformListOf(messages: readonly string[]): Platform[] | null {
  const found = new Set<Platform>()
  let any = false
  for (const m of messages) {
    for (const [, inner] of m.matchAll(/\[([^\]\n]*)\]/g)) {
      const words = inner.toLowerCase().split(/[\s,]+/).filter(Boolean)
      if (!words.length || !words.every(w => w === 'all' || (PLATFORMS as readonly string[]).includes(w))) continue
      any = true
      for (const w of words) {
        if (w === 'all') PLATFORMS.forEach(p => found.add(p))
        else found.add(w as Platform)
      }
    }
  }
  return any ? PLATFORMS.filter(p => found.has(p)) : null
}

/**
 * Which platforms a set of changed files touches. `apple/` and `android/` are
 * their apps; docs, the changelog, license files and CI configuration build
 * nothing by themselves; everything else is the desktop app at the root.
 */
export function platformsFromFiles(files: readonly string[]): Platform[] {
  const hit = new Set<Platform>()
  for (const f of files) {
    if (f.startsWith('apple/')) hit.add('apple')
    else if (f.startsWith('android/')) hit.add('android')
    else if (/^(docs\/|\.github\/|\.claude\/)/.test(f)) continue
    else if (/^[^/]+\.md$/i.test(f) || /^LICENSE/.test(f)) continue
    else hit.add('desktop')
  }
  return PLATFORMS.filter(p => hit.has(p))
}

const VERSION_RE = /^(\d+)\.(\d+)\.(\d+)$/

/** x.y.z bumped. Throws on anything that is not a plain x.y.z. */
export function bumpVersion(version: string, bump: Bump): string {
  const m = VERSION_RE.exec(version)
  if (!m) throw new Error(`Not a release version: ${version}`)
  const [ma, mi, pa] = [Number(m[1]), Number(m[2]), Number(m[3])]
  if (bump === 'major') return `${ma + 1}.0.0`
  if (bump === 'minor') return `${ma}.${mi + 1}.0`
  return `${ma}.${mi}.${pa + 1}`
}

/** The next beta number for a base version, from every tag in use (drafts included). */
export function nextBetaNumber(base: string, tags: readonly string[]): number {
  let max = 0
  for (const t of tags) {
    const m = /^v?(\d+\.\d+\.\d+)-b(\d+)$/.exec(t)
    if (m && m[1] === base) max = Math.max(max, Number(m[2]))
  }
  return max + 1
}

export interface PlanInput {
  event: 'push' | 'workflow_dispatch'
  /** The branch pushed or run on, without refs/heads/. */
  branch: string
  /** Whole commit messages in the pushed range (empty for a manual run); only first lines are read for markers. */
  messages: readonly string[]
  /** Files changed in the pushed range (empty for a manual run). */
  files: readonly string[]
  /** The last published stable release's version, x.y.z. */
  lastVersion: string
  /** Every release tag in use, drafts included, for beta numbering. */
  tags: readonly string[]
  /** Platforms whose app exists in the repo. */
  available: readonly Platform[]
  /** Manual run choices. */
  dispatch?: { bump?: string, platforms?: string, beta?: boolean }
}

export interface Plan {
  mode: Mode
  /** Empty when mode is build or none. */
  version: string
  tag: string
  platforms: Platform[]
  prerelease: boolean
  /** Published at once. Only a beta pushed to dev; every other release is a draft. */
  publish: boolean
  /** One line for the log saying why. */
  reason: string
}

const none = (reason: string): Plan =>
  ({ mode: 'none', version: '', tag: '', platforms: [], prerelease: false, publish: false, reason })

/**
 * Markers count only in a commit's first line. A body that explains the
 * rules ("a [BETA] commit publishes...") once published a prerelease by
 * accident; trigger commits are one-liners anyway.
 */
export const subjectsOf = (messages: readonly string[]): string[] => messages.map(m => m.trim().split('\n')[0])

export function planRelease(input: PlanInput): Plan {
  const available = (p: Platform[]) => p.filter(x => input.available.includes(x))
  const release = (mode: 'release' | 'beta', version: string, platforms: Platform[], publish: boolean, reason: string): Plan =>
    platforms.length
      ? { mode, version, tag: `v${version}`, platforms, prerelease: mode === 'beta', publish, reason }
      : none(`${reason}, but none of those platforms exist in the repo`)
  const betaVersion = (bump: Bump | null) => {
    const base = bumpVersion(input.lastVersion, bump ?? 'patch')
    return `${base}-b${nextBetaNumber(base, input.tags)}`
  }

  if (input.event === 'workflow_dispatch') {
    const d = input.dispatch ?? {}
    const words = (d.platforms ?? '').trim()
    const list = !words || words.toLowerCase() === 'all' ? [...PLATFORMS] : platformListOf([`[${words}]`])
    if (!list) return none(`manual run: "${words}" is not a platform list`)
    const bump = d.bump && d.bump in BUMP_RANK ? d.bump as Bump : null
    if (d.beta) return release('beta', betaVersion(bump), available(list), false, 'manual beta (draft)')
    if (bump) return release('release', bumpVersion(input.lastVersion, bump), available(list), false, `manual ${bump} release (draft)`)
    const platforms = available(list)
    return platforms.length
      ? { mode: 'build', version: '', tag: '', platforms, prerelease: false, publish: false, reason: 'manual test build, no release' }
      : none('manual run for platforms that do not exist in the repo')
  }

  const subjects = subjectsOf(input.messages)
  const bump = bumpOf(subjects)
  const list = platformListOf(subjects)
  // A marker with no platform list and no changed app files (an empty trigger
  // commit on its own) means everything.
  const chosen = list ?? (platformsFromFiles(input.files).length ? platformsFromFiles(input.files) : [...PLATFORMS])

  if (input.branch === 'stable') {
    if (bump) return release('release', bumpVersion(input.lastVersion, bump), available(chosen), false, `${bump} release marker`)
    const built = available(platformsFromFiles(input.files))
    return built.length
      ? { mode: 'build', version: '', tag: '', platforms: built, prerelease: false, publish: false, reason: 'no release marker: build only' }
      : none('no release marker and no app files changed')
  }

  if (input.branch === 'dev' && isBeta(subjects)) {
    return release('beta', betaVersion(bump), available(chosen), true, '[BETA] marker on dev')
  }

  return none(`push to ${input.branch} without a [BETA] marker`)
}

export interface VersionsInput {
  version: string
  /** Platforms built in this run, successfully. */
  rebuilt: readonly Platform[]
  /** Platforms whose files were copied over from the last published release. */
  carried: readonly Platform[]
  /** That release's versions.json, if it had a readable one. */
  previous: Partial<Record<Platform, unknown>> | null
  /** That release's version, x.y.z: the desktop version of any release before versions.json existed. */
  previousVersion: string
}

/**
 * The versions.json for a new release: the new version for what was rebuilt,
 * the old one for what was carried over. A platform with nothing in the
 * release is left out.
 */
export function versionsFor(input: VersionsInput): Partial<Record<Platform, string>> {
  const out: Partial<Record<Platform, string>> = {}
  for (const p of PLATFORMS) {
    if (input.rebuilt.includes(p)) { out[p] = input.version; continue }
    if (!input.carried.includes(p)) continue
    const prev = input.previous?.[p]
    if (typeof prev === 'string' && /^\d+\.\d+\.\d+$/.test(prev)) out[p] = prev
    else if (p === 'desktop' && VERSION_RE.test(input.previousVersion)) out[p] = input.previousVersion
  }
  return out
}
