import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  ChangelogError, changelogFromJson, changelogSectionMarkdown, findChangelogEntry, notesBetween, parseChangelog,
} from '../src/core/changelog.ts'

const SAMPLE = `# Changelog

Intro text, ignored. It may mention ## 1.0.0 (2020-01-01) inline.

## 2.3.0 (2026-10-05)
### Desktop
- Reads versions.json
  - nested

#### Fixes
- A fix

### Apple
- First iOS build

## 2.2.0 (2026-09-27)

### Android

- Hello

### Desktop
- Jellyfin 12
`

const throwsAt = (md: string, line: number, pattern: RegExp) =>
  assert.throws(() => parseChangelog(md), (err: unknown) => {
    assert.ok(err instanceof ChangelogError, `expected a ChangelogError, got ${err}`)
    assert.equal(err.line, line, err.message)
    assert.match(err.message, pattern)
    return true
  })

test('parseChangelog turns versions and platform sections into data', () => {
  assert.deepEqual(parseChangelog(SAMPLE), [
    {
      version: '2.3.0',
      date: '2026-10-05',
      platforms: {
        desktop: '- Reads versions.json\n  - nested\n\n#### Fixes\n- A fix',
        apple: '- First iOS build',
      },
    },
    { version: '2.2.0', date: '2026-09-27', platforms: { android: '- Hello', desktop: '- Jellyfin 12' } },
  ])
})

test('parseChangelog accepts Windows line endings and an empty file', () => {
  assert.equal(parseChangelog(SAMPLE.replace(/\n/g, '\r\n'))[0]!.platforms.apple, '- First iOS build')
  assert.deepEqual(parseChangelog(''), [])
  assert.deepEqual(parseChangelog('# Changelog\n\nNothing yet.\n'), [])
})

test('parseChangelog treats headings inside a code block as text', () => {
  const md = '## 1.0.0 (2026-01-01)\n### Desktop\n```md\n## not a version\n### Nope\n```\n- after\n'
  assert.equal(parseChangelog(md)[0]!.platforms.desktop, '```md\n## not a version\n### Nope\n```\n- after')
  throwsAt('## 1.0.0 (2026-01-01)\n### Desktop\n```\nopen\n', 3, /never closed/)
})

test('parseChangelog refuses a malformed version heading', () => {
  const bad = [
    '## 2.3.0', '## v2.3.0 (2026-10-05)', '## 2.3 (2026-10-05)', '## 2.3.0 2026-10-05',
    '## 2.3.0 (2026-10-5)', '## 2.3.0-b1 (2026-10-05)', '## 02.3.0 (2026-10-05)', '## Unreleased', '##',
    '## 2.3.0  (2026-10-05)',
  ]
  for (const heading of bad) throwsAt(`# Changelog\n\n${heading}\n### Desktop\n- x\n`, 3, /version heading/)
})

test('parseChangelog refuses a date that does not exist', () => {
  throwsAt('## 2.3.0 (2026-02-30)\n### Desktop\n- x\n', 1, /not a real date/)
  throwsAt('## 2.3.0 (2026-13-01)\n### Desktop\n- x\n', 1, /not a real date/)
})

test('parseChangelog refuses an unknown or misplaced platform heading', () => {
  throwsAt('## 2.3.0 (2026-10-05)\n### Windows\n- x\n', 2, /Desktop/)
  throwsAt('## 2.3.0 (2026-10-05)\n### desktop\n- x\n', 2, /Desktop/)
  throwsAt('### Desktop\n- x\n## 2.3.0 (2026-10-05)\n', 1, /before any version/)
  throwsAt('## 2.3.0 (2026-10-05)\n### Desktop\n- x\n### Desktop\n- y\n', 4, /two Desktop sections/)
  throwsAt('## 2.3.0 (2026-10-05)\n### Desktop\n- x\n### Apple\n- a\n### Desktop\n- y\n', 6, /two Desktop sections/)
})

test('parseChangelog refuses text outside a platform section', () => {
  throwsAt('## 2.3.0 (2026-10-05)\nLoose text\n### Desktop\n- x\n', 2, /before its first/)
  throwsAt('## 2.3.0 (2026-10-05)\n### Desktop\n- x\n# Title\n', 4, /use ####/)
})

test('parseChangelog refuses an empty section or a version with none', () => {
  throwsAt('## 2.3.0 (2026-10-05)\n### Desktop\n\n### Apple\n- a\n', 2, /Desktop section of 2.3.0 is empty/)
  throwsAt('## 2.3.0 (2026-10-05)\n\n## 2.2.0 (2026-09-27)\n### Desktop\n- x\n', 1, /no ### Desktop/)
  throwsAt('## 2.3.0 (2026-10-05)\n', 1, /no ### Desktop/)
})

test('parseChangelog refuses duplicates and versions out of order', () => {
  const v = (s: string) => `## ${s}\n### Desktop\n- x\n`
  throwsAt(v('2.3.0 (2026-10-05)') + v('2.3.0 (2026-10-06)'), 4, /listed twice/)
  throwsAt(v('2.2.0 (2026-09-27)') + v('2.3.0 (2026-10-05)'), 4, /newest first/)
  throwsAt(v('2.9.0 (2026-09-27)') + v('2.10.0 (2026-10-05)'), 4, /newest first/)
})

test('findChangelogEntry finds a version with or without a leading v', () => {
  const entries = parseChangelog(SAMPLE)
  assert.equal(findChangelogEntry(entries, '2.2.0')?.date, '2026-09-27')
  assert.equal(findChangelogEntry(entries, 'v2.3.0')?.date, '2026-10-05')
  assert.equal(findChangelogEntry(entries, '2.1.0'), undefined)
})

test('changelogSectionMarkdown prints platforms in a fixed order', () => {
  const entry = findChangelogEntry(parseChangelog(SAMPLE), '2.2.0')!
  assert.equal(changelogSectionMarkdown(entry), '### Desktop\n\n- Jellyfin 12\n\n### Android\n\n- Hello\n')
})

test('the real CHANGELOG.md parses, newest first, with the backfilled releases', () => {
  const entries = parseChangelog(readFileSync(new URL('../CHANGELOG.md', import.meta.url), 'utf8'))
  const versions = entries.map(e => e.version)
  for (const v of ['2.2.0', '2.1.0', '2.0.1', '2.0.0']) {
    assert.ok(findChangelogEntry(entries, v)?.platforms.desktop, `${v} is missing or has no Desktop section`)
  }
  assert.ok(versions.length >= 4)
})

test('changelogFromJson round-trips parsed entries and refuses anything malformed', () => {
  const entries = parseChangelog(SAMPLE)
  assert.deepEqual(changelogFromJson(JSON.parse(JSON.stringify(entries))), entries)
  const ok = { version: '2.3.0', date: '2026-10-05', platforms: { desktop: '- x' } }
  assert.deepEqual(changelogFromJson([{ ...ok, platforms: { desktop: '- x', web: '- ignored' } }]), [ok])
  for (const bad of [
    null, {}, 'text', [null],
    [{ ...ok, version: 'v2.3.0' }], [{ ...ok, version: '2.3.0-b1' }], [{ ...ok, date: '2026-02-30' }],
    [{ ...ok, platforms: [] }], [{ ...ok, platforms: { desktop: 5 } }], [{ ...ok, platforms: { desktop: ' ' } }],
    [{ ...ok, platforms: { desktop: 'x'.repeat(20_001) } }], Array(501).fill(ok),
  ]) assert.equal(changelogFromJson(bad), null, JSON.stringify(bad)?.slice(0, 80))
})

test('notesBetween lists one platform after the current version up to the target, newest first', () => {
  const e = (version: string, platforms: Record<string, string>) => ({ version, date: '2026-10-01', platforms })
  const entries = [e('2.3.2', { apple: '- a' }), e('2.3.1', { desktop: '- d1' }), e('2.3.0', { desktop: '- d0' }), e('2.2.0', { desktop: '- old' }), e('2.4.0', { desktop: '- future' })]
  assert.equal(notesBetween(entries, 'desktop', '2.2.0', '2.3.2'), '## 2.3.1 (2026-10-01)\n\n- d1\n\n## 2.3.0 (2026-10-01)\n\n- d0')
  assert.equal(notesBetween(entries, 'desktop', '2.3.1', '2.3.2'), '')
  // A beta of the target's base counts as older than it.
  assert.match(notesBetween(entries, 'desktop', '2.3.0-b2', '2.3.0'), /^## 2\.3\.0 /)
})
