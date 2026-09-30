import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const SCRIPT = fileURLToPath(new URL('../scripts/changelog-section.mjs', import.meta.url))

function run(args: string[], changelog?: string) {
  const dir = mkdtempSync(join(tmpdir(), 'cascade-changelog-'))
  try {
    const extra = changelog === undefined ? [] : [join(dir, 'CHANGELOG.md')]
    if (changelog !== undefined) writeFileSync(extra[0]!, changelog)
    const r = spawnSync(process.execPath, [SCRIPT, ...args, ...extra], { encoding: 'utf8' })
    return { status: r.status, stdout: r.stdout, stderr: r.stderr }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

const CHANGELOG = '# Changelog\n\n## 2.3.0 (2026-10-05)\n### Apple\n- iOS\n### Desktop\n- a\n\n## 2.2.0 (2026-09-27)\n### Desktop\n- b\n'

test('changelog-section prints one version as release notes, and nothing else', () => {
  const r = run(['2.3.0'], CHANGELOG)
  assert.equal(r.status, 0, r.stderr)
  assert.equal(r.stdout, '### Desktop\n\n- a\n\n### Apple\n\n- iOS\n')
  assert.equal(r.stderr, '')
  assert.equal(run(['v2.2.0'], CHANGELOG).stdout, '### Desktop\n\n- b\n')
})

test('changelog-section fails for a version with no section', () => {
  const r = run(['2.4.0'], CHANGELOG)
  assert.equal(r.status, 1)
  assert.equal(r.stdout, '')
  assert.match(r.stderr, /no section for 2\.4\.0/)
})

test('changelog-section fails on a malformed changelog, naming the line', () => {
  const r = run(['2.3.0'], CHANGELOG.replace('### Apple', '### iOS'))
  assert.equal(r.status, 1)
  assert.equal(r.stdout, '')
  assert.match(r.stderr, /line 4: expected "### Desktop"/)
})

test('changelog-section explains its usage when given no version', () => {
  const r = run([])
  assert.equal(r.status, 2)
  assert.match(r.stderr, /Usage/)
})

test('changelog-section reads the real CHANGELOG.md by default', () => {
  const r = run(['2.2.0'])
  assert.equal(r.status, 0, r.stderr)
  assert.match(r.stdout, /^### Desktop\n/)
})
