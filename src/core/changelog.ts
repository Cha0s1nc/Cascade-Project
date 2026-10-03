// CHANGELOG.md, read into data.
//
// One file lists every stable release of every platform, newest first:
//
//   ## 2.3.0 (2026-10-05)
//   ### Desktop
//   - ...
//   ### Mac
//   - ...
//   ### Apple
//   - ...
//   ### Android
//   - ...
//
// Platform sections are optional per version. Betas are not listed. Desktop
// is the Electron app on every OS; Mac is the native Mac app, which the Mac
// updater reads (docs/mac-native-plan.md); Apple is iOS and tvOS.
//
// The release workflow takes a version's notes from here, and the website and
// the in-app "what's new" read the JSON this produces. So the parser is strict
// and says which line is wrong: a typo in a heading must fail the release
// build, not quietly drop a version or merge two of them.
//
// Pure, no Node APIs, so it can also run in the renderer. The CLI wrapper is
// scripts/changelog-section.mjs.

import { isNewerVersion } from './update-release.ts'

export type ChangelogPlatform = 'desktop' | 'mac' | 'apple' | 'android'

/** Platform keys in the order sections are printed. */
export const CHANGELOG_PLATFORMS: readonly ChangelogPlatform[] = ['desktop', 'mac', 'apple', 'android']

const PLATFORM_TITLES: Record<ChangelogPlatform, string> = { desktop: 'Desktop', mac: 'Mac', apple: 'Apple', android: 'Android' }

// For error messages, built from the list so a new platform cannot be missed.
const HEADINGS_TEXT = CHANGELOG_PLATFORMS.map(p => `### ${PLATFORM_TITLES[p]}`)
const HEADINGS_OR = `${HEADINGS_TEXT.slice(0, -1).join(', ')} or ${HEADINGS_TEXT[HEADINGS_TEXT.length - 1]}`

export interface ChangelogEntry {
  version: string
  /** YYYY-MM-DD, the day the release was published. */
  date: string
  /** Markdown per platform, without its `###` heading. */
  platforms: Partial<Record<ChangelogPlatform, string>>
}

export class ChangelogError extends Error {
  readonly line: number
  constructor(line: number, message: string) {
    super(`CHANGELOG.md line ${line}: ${message}`)
    this.name = 'ChangelogError'
    this.line = line
  }
}

// A release version only: no leading zeros, no beta suffix.
const VERSION_HEADING_RE = /^## ((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)) \((\d{4}-\d{2}-\d{2})\)$/
const FENCE_RE = /^ {0,3}(```|~~~)/

function isRealDate(date: string): boolean {
  const [y, m, d] = date.split('-').map(Number)
  const t = new Date(Date.UTC(y!, m! - 1, d!))
  return t.getUTCFullYear() === y && t.getUTCMonth() === m! - 1 && t.getUTCDate() === d
}

/** Drops blank lines at both ends, keeping everything between as written. */
function trimBlankLines(lines: string[]): string {
  let start = 0
  let end = lines.length
  while (start < end && lines[start]!.trim() === '') start++
  while (end > start && lines[end - 1]!.trim() === '') end--
  return lines.slice(start, end).map(l => l.trimEnd()).join('\n')
}

/**
 * Parses CHANGELOG.md. Anything before the first version heading (a title, an
 * introduction) is ignored. Throws ChangelogError on anything that does not
 * follow the format.
 */
export function parseChangelog(markdown: string): ChangelogEntry[] {
  const lines = markdown.replace(/\r\n?/g, '\n').split('\n')
  const entries: ChangelogEntry[] = []
  let entry: ChangelogEntry | null = null
  let entryLine = 0
  let platform: ChangelogPlatform | null = null
  let platformLine = 0
  let body: string[] = []
  let fence: string | null = null
  let fenceLine = 0

  const closePlatform = () => {
    if (!entry || !platform) return
    const text = trimBlankLines(body)
    if (!text) throw new ChangelogError(platformLine, `the ${PLATFORM_TITLES[platform]} section of ${entry.version} is empty`)
    entry.platforms[platform] = text
    platform = null
    body = []
  }
  const closeEntry = () => {
    closePlatform()
    if (entry && Object.keys(entry.platforms).length === 0) {
      throw new ChangelogError(entryLine, `${entry.version} has no ${HEADINGS_OR} section`)
    }
  }

  lines.forEach((raw, i) => {
    const n = i + 1
    const line = raw.trimEnd()

    // Headings inside a code block are text.
    const fenceMatch = line.match(FENCE_RE)
    if (fence) {
      if (fenceMatch && fenceMatch[1] === fence) fence = null
      if (platform) body.push(raw)
      return
    }
    if (fenceMatch) { fence = fenceMatch[1]!; fenceLine = n }

    if (/^#{1,3}(\s|$)/.test(line)) {
      if (line.startsWith('## ') || line === '##') {
        const m = line.match(VERSION_HEADING_RE)
        if (!m) throw new ChangelogError(n, `expected a version heading like "## 2.3.0 (2026-10-05)", found "${line}"`)
        const [, version, date] = m as unknown as [string, string, string]
        if (!isRealDate(date)) throw new ChangelogError(n, `${date} is not a real date`)
        if (entries.some(e => e.version === version)) throw new ChangelogError(n, `${version} is listed twice`)
        const previous = entries[entries.length - 1]
        if (previous && !isNewerVersion(previous.version, version)) {
          throw new ChangelogError(n, `${version} is below ${previous.version}, but versions must be newest first`)
        }
        closeEntry()
        entry = { version, date, platforms: {} }
        entryLine = n
        entries.push(entry)
        return
      }
      if (line.startsWith('### ') || line === '###') {
        if (!entry) throw new ChangelogError(n, `"${line}" comes before any version heading`)
        const key = CHANGELOG_PLATFORMS.find(p => line === `### ${PLATFORM_TITLES[p]}`)
        if (!key) throw new ChangelogError(n, `expected ${HEADINGS_OR.replace(/### \w+/g, '"$&"')}, found "${line}"`)
        if (entry.platforms[key] !== undefined || platform === key) throw new ChangelogError(n, `${entry.version} has two ${PLATFORM_TITLES[key]} sections`)
        closePlatform()
        platform = key
        platformLine = n
        return
      }
      // A top-level "# " heading: the title, before any version, is fine.
      if (entry) throw new ChangelogError(n, `a "# " heading inside ${entry.version}; use #### for headings within a section`)
      return
    }

    if (platform) body.push(raw)
    else if (entry && line.trim() !== '') {
      throw new ChangelogError(n, `text in ${entry.version} before its first platform heading (${HEADINGS_OR})`)
    }
  })

  if (fence) throw new ChangelogError(fenceLine, 'this code block is never closed')
  closeEntry()
  return entries
}

/** The entry for a version (a leading "v" is ignored), or undefined. */
export function findChangelogEntry(entries: readonly ChangelogEntry[], version: string): ChangelogEntry | undefined {
  const want = version.replace(/^v/, '')
  return entries.find(e => e.version === want)
}

// Caps for changelog.json read from the website: well above any real file,
// low enough that a broken or hostile one cannot flood the updater window.
const JSON_MAX_ENTRIES = 500
const JSON_MAX_NOTES = 20_000

/**
 * changelog.json (the parsed CHANGELOG.md the website serves) checked back
 * into entries, or null if anything in it is not shaped like one. It comes
 * over the network, so every field is checked, not trusted.
 */
export function changelogFromJson(data: unknown): ChangelogEntry[] | null {
  if (!Array.isArray(data) || data.length > JSON_MAX_ENTRIES) return null
  const entries: ChangelogEntry[] = []
  for (const e of data) {
    if (!e || typeof e !== 'object') return null
    const { version, date, platforms } = e as Record<string, unknown>
    if (typeof version !== 'string' || typeof date !== 'string') return null
    if (!VERSION_HEADING_RE.test(`## ${version} (${date})`) || !isRealDate(date)) return null
    if (!platforms || typeof platforms !== 'object' || Array.isArray(platforms)) return null
    const out: ChangelogEntry['platforms'] = {}
    for (const p of CHANGELOG_PLATFORMS) {
      const text = (platforms as Record<string, unknown>)[p]
      if (text === undefined) continue
      if (typeof text !== 'string' || !text.trim() || text.length > JSON_MAX_NOTES) return null
      out[p] = text
    }
    entries.push({ version, date, platforms: out })
  }
  return entries
}

/**
 * What changed for one platform after `current`, up to and including
 * `target`, newest first, each version under its own `##` heading.
 *
 * null when the changelog does not list `target` at all: that copy is older
 * than the release (the website updates after it), so the caller tries
 * another copy rather than show notes missing the version on offer. Empty
 * when it lists `target` but has nothing for this platform in the range;
 * then the release's own notes say more.
 */
export function notesBetween(entries: readonly ChangelogEntry[], platform: ChangelogPlatform, current: string, target: string): string | null {
  if (!entries.some(e => e.version === target)) return null
  return entries
    .filter(e => e.platforms[platform] !== undefined && isNewerVersion(e.version, current) && !isNewerVersion(e.version, target))
    .sort((a, b) => (isNewerVersion(a.version, b.version) ? -1 : 1))
    .map(e => `## ${e.version} (${e.date})\n\n${e.platforms[platform]}`)
    .join('\n\n')
}

// A line that starts its own block: a list item, heading, quote, table row,
// raw HTML, or a link reference definition ("[x]: https://...").
const BLOCK_START_RE = /^\s*(?:[-*+]\s|\d+[.)]\s|#|>|\||<|\[[^\]]+\]:\s)/
const RULE_RE = /^\s*([-*_])(\s*\1){2,}\s*$/
const LIST_ITEM_RE = /^\s*(?:[-*+]|\d+[.)])\s/

/**
 * Joins hard-wrapped lines back into whole paragraphs and list items.
 * GitHub renders a release body, PR or issue like a comment, where every
 * newline is a line break, so wrapped text showed up broken mid-sentence;
 * Markdown files read the same either way, so they are kept unwrapped too.
 *
 * Anything that is its own line stays put: headings, list items, quotes,
 * tables, rules, raw HTML, link definitions, fenced and indented code, and
 * YAML front matter at the top.
 */
export function unwrapMarkdown(markdown: string): string {
  const lines = markdown.replace(/\r\n?/g, '\n').split('\n')
  const out: string[] = []
  let i = 0
  // Front matter: copied as is, down to its closing ---.
  if (lines[0] === '---') {
    const end = lines.indexOf('---', 1)
    if (end > 0) { out.push(...lines.slice(0, end + 1)); i = end + 1 }
  }
  let fence: string | null = null
  let indentedCode = false
  let lastText = ''   // the last non-blank line, to tell indented code from a list's
  for (; i < lines.length; i++) {
    const raw = lines[i]!
    const line = raw.trimEnd()
    const fenceMatch = line.match(FENCE_RE)
    if (fence || fenceMatch) {
      if (fence && fenceMatch && fenceMatch[1] === fence) fence = null
      else if (!fence && fenceMatch) fence = fenceMatch[1]!
      out.push(raw)
      if (line.trim()) lastText = line
      continue
    }
    const prev = out[out.length - 1]
    // Indented code: four spaces after a blank line, unless that blank line
    // sits inside a list, where the indent continues the item instead.
    const indented = /^( {4}|\t)/.test(raw)
    if (indentedCode && (indented || !line.trim())) { out.push(raw); continue }
    indentedCode = false
    if (indented && (prev === undefined || !prev.trim()) && !LIST_ITEM_RE.test(lastText) && !/^\s/.test(lastText)) {
      indentedCode = true
      out.push(raw)
      continue
    }
    const prevOpen = prev !== undefined && prev.trim() !== '' && !/^\s*#/.test(prev)
      && !RULE_RE.test(prev) && !/^\s*(?:\||<|\[[^\]]+\]:\s)/.test(prev) && !FENCE_RE.test(prev)
    if (line.trim() && prevOpen && !BLOCK_START_RE.test(line) && !RULE_RE.test(line)) {
      out[out.length - 1] = `${prev} ${line.trim()}`
    } else {
      out.push(line)
    }
    if (line.trim()) lastText = line
  }
  return out.join('\n')
}

/**
 * One version's notes as Markdown, for a GitHub release body: each platform
 * under its `###` heading, in a fixed order. No version heading, since the
 * release has its own title.
 */
export function changelogSectionMarkdown(entry: ChangelogEntry): string {
  return CHANGELOG_PLATFORMS
    .filter(p => entry.platforms[p] !== undefined)
    .map(p => `### ${PLATFORM_TITLES[p]}\n\n${unwrapMarkdown(entry.platforms[p]!)}`)
    .join('\n\n') + '\n'
}
