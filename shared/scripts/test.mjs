// Every app's tests from the repo root, each with its own tool:
//
//   npm test                 every app checked out here
//   npm test desktop apple   just those
//
// With no names, an app whose folder is not checked out (a sparse clone) or
// whose tool is not installed (no Swift on Windows) is skipped with a note.
// Named, either one is a failure: you asked for it. Exits non-zero when any
// suite failed or could not run.

import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const WIN = process.platform === 'win32'

/** Each app: its folder, the tool it needs, the command, and anything that
 *  must be in place first. */
const SUITES = {
  desktop: { dir: 'desktop', tool: 'npm', run: ['npm', 'test'], needs: () => existsSync(join(ROOT, 'desktop/node_modules')) || 'run npm ci in desktop/ first' },
  apple: { dir: 'apple/CascadeKit', tool: 'swift', run: ['swift', 'test'] },
  server: { dir: 'server', tool: 'dotnet', run: ['dotnet', 'test'] },
}

const has = (tool) => spawnSync(tool, ['--version'], { stdio: 'ignore', shell: WIN }).status === 0

const asked = process.argv.slice(2)
const unknown = asked.filter(n => !SUITES[n])
if (unknown.length) {
  console.error(`Unknown: ${unknown.join(', ')}. Apps: ${Object.keys(SUITES).join(', ')}`)
  process.exit(2)
}

const results = []
for (const name of asked.length ? asked : Object.keys(SUITES)) {
  const s = SUITES[name]
  const named = asked.includes(name)
  const why = !existsSync(join(ROOT, s.dir)) ? `${s.dir}/ is not in this checkout`
    : !has(s.tool) ? `${s.tool} is not installed`
      : null
  if (why) {
    results.push({ name, ok: !named, skipped: !named, note: why })
    continue
  }
  const blocked = s.needs?.()
  if (typeof blocked === 'string') {
    results.push({ name, ok: false, note: blocked })
    continue
  }
  console.log(`\n── ${name}: ${s.run.join(' ')} (in ${s.dir}/)\n`)
  const r = spawnSync(s.run[0], s.run.slice(1), { cwd: join(ROOT, s.dir), stdio: 'inherit', shell: WIN })
  results.push({ name, ok: r.status === 0, note: r.status === 0 ? 'passed' : `failed (exit ${r.status ?? r.signal})` })
}

console.log('\n── Summary')
for (const r of results) console.log(`  ${r.skipped ? 'skip' : r.ok ? 'ok  ' : 'FAIL'} ${r.name}: ${r.note}`)
process.exit(results.every(r => r.ok) ? 0 : 1)
