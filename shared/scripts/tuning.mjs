// Edits tuning-defaults.json, the shipped defaults for every app, and keeps
// the Apple apps' copy of it (TuningDefaultsData.swift) in step. The rules
// (what a platform reads, how a set or bake splits or folds a value, the
// revision list) are desktop/src/core/tuning.ts.
//
//   npm run tuning -- show [key...] [--diverged]   every value per platform
//   npm run tuning -- set <key> <value> [--for T]   T: all (default), apple, desktop, mac, ios, tvos
//   npm run tuning -- bake [--to T] [--platform P] [--file F | --stdin]
//       a tuning copied from an app (Copy Changes, or the desktop's debug
//       tuning panel), read from the clipboard by default. It lands on the
//       platform it was tuned on unless --to names a broader target.
//   npm run tuning -- combine <key...> | --all [--from P]
//       one value for every platform again: theirs if they agree, else P's.
//       --all folds every key whose platforms already agree.
//   npm run tuning -- sync [--check]   rewrite the Swift copy (or only check it)
//
// A style key whose default moves is added to the open revision (see
// recordRevision), so the apps ask anyone who set that knob themselves.
// --no-revision skips that, for a fix nobody needs asking about.

import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// See scripts/release-plan.mjs: only Node's harmless module-type warning is dropped.
const printWarning = process.listeners('warning')
process.removeAllListeners('warning')
process.on('warning', w => {
  if (w.code !== 'MODULE_TYPELESS_PACKAGE_JSON') for (const print of printWarning) print(w)
})
const T = await import('../desktop/src/core/tuning.ts')

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const FILE = join(ROOT, 'tuning-defaults.json')
const SWIFT = join(ROOT, 'apple/CascadeKit/Sources/CascadeKit/TuningDefaultsData.swift')

/** The revision a release carried before tuning-defaults.json existed: the
 *  desktop's 2 (2026-10-06). Revision 3 was still on dev when the file came in. */
const LEGACY_RELEASED = 2

const args = process.argv.slice(2)
const command = args.shift()
const flag = name => { const i = args.indexOf(name); if (i < 0) return false; args.splice(i, 1); return true }
const option = name => {
  const i = args.indexOf(name)
  if (i < 0) return undefined
  const v = args[i + 1]
  if (v === undefined || v.startsWith('--')) fail(`${name} needs a value`)
  args.splice(i, 2)
  return v
}
function fail(message) {
  console.error(`tuning: ${message}`)
  process.exit(1)
}

const read = () => JSON.parse(readFileSync(FILE, 'utf8'))
function write(file) {
  const text = T.formatTuning(file)
  writeFileSync(FILE, text)
  writeFileSync(SWIFT, T.swiftCopy(text))
}

function sectionOf(file, key) {
  const found = T.SECTIONS.filter(s => key in (file[s] ?? {}))
  return found[0]
}

function target(name, fallback) {
  const t = name ?? fallback
  if (!T.TARGETS.includes(t)) fail(`unknown target ${t}; one of ${T.TARGETS.join(', ')}`)
  return t
}

/** The latest revision a release has shipped, from the newest v* tag's copy
 *  of the file. */
function releasedRevision() {
  try {
    const tag = execFileSync('git', ['tag', '--list', 'v*', '--sort=-creatordate'], { cwd: ROOT, encoding: 'utf8' }).split('\n')[0]
    if (!tag) return LEGACY_RELEASED
    const old = execFileSync('git', ['show', `${tag}:tuning-defaults.json`], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
    return T.latestRevision(JSON.parse(old))
  } catch {
    return LEGACY_RELEASED
  }
}

const today = () => new Date().toISOString().slice(0, 10)
const show = v => v === undefined ? '-' : Array.isArray(v) ? `[${v.length} items]` : typeof v === 'object' ? JSON.stringify(v) : String(v)

/** Applies one change, reports it, and records a revision for a style key. */
function change(file, section, key, next, noRevision, notes) {
  const before = file[section][key]
  file[section][key] = next
  const moved = T.movedOn(before, next)
  if (!moved.length) { notes.push(`${key}: no change`); return }
  const values = moved.map(p => `${p} ${show(T.resolve(before, p))} -> ${show(T.resolve(next, p))}`)
  notes.push(`${key}: ${values.join(', ')}`)
  // Only where the key was already a setting: nobody there can have set it.
  const asked = moved.filter(p => T.resolve(before, p) !== undefined)
  if (section === 'style' && !noRevision && asked.length) {
    const r = T.recordRevision(file, key, asked, releasedRevision(), today())
    notes.push(`  (revision ${r}: anyone who set ${key} themselves is asked once)`)
  }
}

function readBake() {
  if (flag('--stdin')) return readFileSync(0, 'utf8')
  const path = option('--file')
  if (path) return readFileSync(path, 'utf8')
  try {
    return execFileSync(process.platform === 'darwin' ? 'pbpaste' : 'xclip', process.platform === 'darwin' ? [] : ['-o', '-selection', 'clipboard'], { encoding: 'utf8' })
  } catch {
    fail('could not read the clipboard; pass --file or --stdin')
  }
}

/** A bake: {"bake": platform, "style": {...}, "albumColors": {...}, "motion": {...}},
 *  or the older "key = value" lines (which need --platform). */
function parseBake(text, platformFlag) {
  const trimmed = text.trim()
  if (trimmed.startsWith('{')) {
    const j = JSON.parse(trimmed)
    return { platform: platformFlag ?? j.bake, sections: { style: j.style ?? {}, albumColors: j.albumColors ?? {}, motion: j.motion ?? {} } }
  }
  if (trimmed === '(all defaults)') return { platform: platformFlag, sections: {} }
  const style = {}
  for (const line of trimmed.split('\n')) {
    const m = /^\s*(\w+)\s*=\s*(-?[\d.]+)\s*$/.exec(line)
    if (!m) fail(`not a tuning: ${line}`)
    style[m[1]] = Number(m[2])
  }
  return { platform: platformFlag, sections: { style } }
}

switch (command) {
  case 'show': {
    const file = read()
    const diverged = flag('--diverged')
    const width = 26
    console.log(['key'.padEnd(width), ...T.PLATFORMS.map(p => p.padEnd(9))].join(' '))
    for (const section of T.SECTIONS) {
      for (const [key, entry] of Object.entries(file[section] ?? {})) {
        if (args.length && !args.includes(key)) continue
        const values = T.PLATFORMS.map(p => T.resolve(entry, p))
        const present = values.filter(v => v !== undefined).map(show)
        const differs = new Set(present).size > 1
        if (diverged && !differs) continue
        const cells = values.map(v => show(v).padEnd(9))
        console.log([`${differs ? '*' : ' '}${key}`.padEnd(width), ...cells].join(' ').trimEnd())
      }
    }
    console.log(`\n* differs between platforms. Latest revision: ${T.latestRevision(file)}`)
    break
  }
  case 'set': {
    const file = read()
    const t = target(option('--for'), 'all')
    const noRevision = flag('--no-revision')
    const [key, raw] = args
    if (!key || raw === undefined) fail('usage: set <key> <value> [--for target]')
    const section = sectionOf(file, key)
    if (!section) fail(`no key ${key}; add it to a section of tuning-defaults.json by hand first`)
    let value
    try { value = JSON.parse(raw) } catch { fail(`${raw} is not a JSON value`) }
    const { entry, shadowedBy } = T.setEntry(file[section][key], t, value)
    const notes = []
    change(file, section, key, entry, noRevision, notes)
    if (shadowedBy.length) notes.push(`  still overridden for: ${shadowedBy.join(', ')} (combine ${key} to drop them)`)
    write(file)
    console.log(notes.join('\n'))
    break
  }
  case 'bake': {
    const file = read()
    const noRevision = flag('--no-revision')
    const to = option('--to')
    const platformFlag = option('--platform')
    const { platform, sections } = parseBake(readBake(), platformFlag)
    if (!T.PLATFORMS.includes(platform)) fail(`which platform was this tuned on? pass --platform (${T.PLATFORMS.join(', ')})`)
    const t = target(to, platform)
    if (!T.CHAIN[platform].includes(t)) fail(`${platform} does not read ${t}`)
    const notes = []
    for (const section of T.SECTIONS) {
      for (const [key, value] of Object.entries(sections[section] ?? {})) {
        if (!(key in (file[section] ?? {}))) { notes.push(`${key}: not in ${section}, skipped`); continue }
        change(file, section, key, T.setEntry(file[section][key], t, value, platform).entry, noRevision, notes)
      }
    }
    if (!notes.length) { console.log(`Nothing to bake: ${platform} is at its defaults.`); break }
    write(file)
    console.log(`Baked ${platform}'s tuning into ${t}:\n${notes.join('\n')}\nRebuild the apps to ship it.`)
    break
  }
  case 'combine': {
    const file = read()
    const all = flag('--all')
    const noRevision = flag('--no-revision')
    const from = option('--from')
    if (from && !T.PLATFORMS.includes(from)) fail(`unknown platform ${from}`)
    const notes = []
    const keys = all ? T.SECTIONS.flatMap(s => Object.keys(file[s] ?? {})) : args
    if (!keys.length) fail('usage: combine <key...> | --all [--from platform]')
    for (const key of keys) {
      const section = sectionOf(file, key)
      if (!section) fail(`no key ${key}`)
      const entry = file[section][key]
      if (!T.isSplit(entry)) { if (!all) notes.push(`${key}: already one value`); continue }
      // A platform without the key does not have that setting on purpose.
      if (all && T.PLATFORMS.some(p => T.resolve(entry, p) === undefined)) continue
      let next
      try { next = T.combineEntry(entry, all ? undefined : from) } catch (e) {
        notes.push(`${key}: ${all ? 'platforms differ, left split' : e.message}`)
        continue
      }
      change(file, section, key, next, noRevision, notes)
    }
    write(file)
    console.log(notes.join('\n') || 'Nothing to combine.')
    break
  }
  case 'sync': {
    const text = readFileSync(FILE, 'utf8')
    JSON.parse(text)
    const want = T.swiftCopy(text)
    let have = ''
    try { have = readFileSync(SWIFT, 'utf8') } catch {}
    if (flag('--check')) {
      if (have !== want) fail('TuningDefaultsData.swift is stale: run npm run tuning -- sync')
      console.log('Swift copy is current.')
    } else {
      writeFileSync(SWIFT, want)
      console.log(have === want ? 'Swift copy was already current.' : 'Rewrote TuningDefaultsData.swift.')
    }
    break
  }
  default:
    console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(5, 20).map(l => l.replace(/^\/\/ ?/, '')).join('\n'))
    process.exit(command ? 1 : 0)
}
