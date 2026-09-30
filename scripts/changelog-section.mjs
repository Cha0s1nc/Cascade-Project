// Prints one version's notes from CHANGELOG.md as Markdown, for use as the
// body of its GitHub release:
//
//   node scripts/changelog-section.mjs 2.3.0 [path/to/CHANGELOG.md] > notes.md
//
// Exits 1, with the reason on stderr, when the version has no section or the
// changelog does not follow its format, so a release job can refuse to go on.
// Exits 2 on bad usage.
//
// No dependencies: the parser is src/core/changelog.ts, loaded directly by
// Node's TypeScript type stripping (Node 22.18 or later, as npm test already
// needs).

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

// package.json has no "type" (main.js is CommonJS), so Node warns on stderr
// that it had to re-read the .ts file as an ES module. Harmless, but it reads
// like a failure in a CI log. Only that warning is dropped, which is why the
// parser is imported below rather than at the top.
const printWarning = process.listeners('warning')
process.removeAllListeners('warning')
process.on('warning', w => {
  if (w.code !== 'MODULE_TYPELESS_PACKAGE_JSON') for (const print of printWarning) print(w)
})
const { changelogSectionMarkdown, findChangelogEntry, parseChangelog } = await import('../src/core/changelog.ts')

const [version, file = fileURLToPath(new URL('../CHANGELOG.md', import.meta.url))] = process.argv.slice(2)

if (!version || version.startsWith('-')) {
  console.error('Usage: node scripts/changelog-section.mjs <version> [CHANGELOG.md]')
  process.exit(2)
}

try {
  const entry = findChangelogEntry(parseChangelog(readFileSync(file, 'utf8')), version)
  if (!entry) throw new Error(`${file} has no section for ${version}`)
  process.stdout.write(changelogSectionMarkdown(entry))
} catch (err) {
  console.error(err instanceof Error ? err.message : String(err))
  process.exit(1)
}
