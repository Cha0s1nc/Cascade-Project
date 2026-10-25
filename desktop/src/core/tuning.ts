// tuning-defaults.json at the repo root: the shipped defaults for every app,
// each one either shared or split per platform. This is the reading side
// (what a platform's defaults are) and the editing side scripts/tuning.mjs
// uses (set, bake, combine, the revision list), kept pure so both are tested
// here. The Apple apps read the same file through a generated copy
// (TuningDefaults.swift in CascadeKit), resolved by the same rules.

export type Platform = 'desktop' | 'mac' | 'ios' | 'tvos'
export type Target = Platform | 'apple' | 'all'
export type Section = 'style' | 'albumColors' | 'motion'

export const PLATFORMS: readonly Platform[] = ['desktop', 'mac', 'ios', 'tvos']
export const TARGETS: readonly Target[] = ['all', 'apple', ...PLATFORMS]
export const SECTIONS: readonly Section[] = ['style', 'albumColors', 'motion']

/** Most specific first: what a platform reads, in the order it looks. */
export const CHAIN: Readonly<Record<Platform, readonly Target[]>> = {
  desktop: ['desktop', 'all'],
  mac: ['mac', 'apple', 'all'],
  ios: ['ios', 'apple', 'all'],
  tvos: ['tvos', 'apple', 'all'],
}

/** The platforms a target reaches. */
export function platformsOf(target: Target): Platform[] {
  return PLATFORMS.filter(p => CHAIN[p].includes(target))
}

/** A value as stored: shared, or split per platform with an optional note. */
export type Entry = unknown

export interface Revision {
  date?: string
  note?: string
  [target: string]: unknown
}

export interface TuningFile {
  about?: string[]
  style: Record<string, Entry>
  albumColors: Record<string, Entry>
  motion: Record<string, Entry>
  revisions: Record<string, Revision>
}

/** A split entry is a plain object (not an array) whose keys are all targets
 *  or `note`. Anything else, an array of slots included, is one shared value. */
export function isSplit(entry: Entry): entry is Record<string, unknown> {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return false
  const keys = Object.keys(entry)
  return keys.length > 0 && keys.every(k => k === 'note' || (TARGETS as readonly string[]).includes(k))
}

/** What one platform reads from an entry, or undefined when it has none. */
export function resolve(entry: Entry, platform: Platform): unknown {
  if (!isSplit(entry)) return entry
  for (const t of CHAIN[platform]) if (t in entry) return entry[t]
  return undefined
}

/** Every key of a section this platform has, resolved. */
export function resolveSection(file: TuningFile, section: Section, platform: Platform): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [key, entry] of Object.entries(file[section] ?? {})) {
    const v = resolve(entry, platform)
    if (v !== undefined) out[key] = v
  }
  return out
}

/** The numbers of a section only, for the knob tables. */
export function resolveNumbers(file: TuningFile, section: Section, platform: Platform): Record<string, number> {
  const out: Record<string, number> = {}
  for (const [key, v] of Object.entries(resolveSection(file, section, platform))) {
    if (typeof v === 'number' && Number.isFinite(v)) out[key] = v
  }
  return out
}

// ── Revisions ───────────────────────────────────────────────────────────────
// Only the knobs a person changed are stored, so a new default reaches
// everyone who left that knob alone by itself. Someone who did change it is
// asked once whether to take the new one: each revision lists, per target,
// the style keys whose default moved.

export function latestRevision(file: TuningFile): number {
  return Math.max(1, ...Object.keys(file.revisions ?? {}).map(Number).filter(Number.isInteger))
}

/** The style keys whose default moved on this platform in revision `r`. */
export function revisionKeys(file: TuningFile, platform: Platform, r: number): string[] {
  const rev = file.revisions?.[String(r)]
  if (!rev) return []
  const keys = new Set<string>()
  for (const t of CHAIN[platform]) {
    const list = rev[t]
    if (Array.isArray(list)) for (const k of list) if (typeof k === 'string') keys.add(k)
  }
  return [...keys]
}

// ── Editing ─────────────────────────────────────────────────────────────────

function equal(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b)
}

/** What `target`'s platforms would read with `target`'s own value removed. */
function parentValue(split: Record<string, unknown>, target: Target): unknown {
  if (target === 'all') return undefined
  if (target === 'apple') return split.all
  const chain = CHAIN[target]
  for (const t of chain.slice(1)) if (t in split) return split[t]
  return undefined
}

/** Drops overrides that say the same as what they override, and folds an
 *  entry with only `all` (and no note) back to a plain value. */
export function simplify(entry: Entry): Entry {
  if (!isSplit(entry)) return entry
  const split = { ...entry }
  for (let changed = true; changed;) {
    changed = false
    for (const t of TARGETS) {
      if (t === 'all' || !(t in split)) continue
      if (equal(split[t], parentValue(split, t))) { delete split[t]; changed = true }
    }
  }
  const targets = Object.keys(split).filter(k => k !== 'note')
  if (targets.length === 1 && targets[0] === 'all' && !('note' in split)) return split.all
  return split
}

function asSplit(entry: Entry): Record<string, unknown> {
  if (entry === undefined) return {}
  return isSplit(entry) ? { ...entry } : { all: entry }
}

export interface SetResult {
  entry: Entry
  /** More specific overrides that still win over the value just set. */
  shadowedBy: Target[]
}

/**
 * Sets `target`'s value. With `from` (a bake: the value was tuned on that
 * platform), the overrides between `target` and `from` go, so `from` reads
 * the new value; the other platforms' overrides stay, since those diverged
 * on purpose. Without it, every override under `target` stays and is
 * reported as still winning.
 */
export function setEntry(entry: Entry, target: Target, value: unknown, from?: Platform): SetResult {
  const split = asSplit(entry)
  split[target] = value
  if (from) {
    const chain = CHAIN[from]
    const at = chain.indexOf(target)
    if (at < 0) throw new Error(`${from} does not read ${target}`)
    for (const t of chain.slice(0, at)) delete split[t]
  }
  const out = simplify(split)
  const kept = asSplit(out)
  const reached = new Set(platformsOf(target))
  const shadowedBy = TARGETS.filter(t => t !== target && t in kept && platformsOf(t).some(p => reached.has(p))
    && platformsOf(t).length < reached.size)
  return { entry: out, shadowedBy }
}

/** One value for every platform again: theirs if they already agree, else
 *  `from`'s. Throws when they differ and no `from` was named. */
export function combineEntry(entry: Entry, from?: Platform): Entry {
  const values = PLATFORMS.map(p => resolve(entry, p)).filter(v => v !== undefined)
  let value: unknown
  if (from) value = resolve(entry, from)
  else if (values.every(v => equal(v, values[0]))) value = values[0]
  else throw new Error('the platforms differ; name the one to keep with --from')
  if (value === undefined) throw new Error(`${from} has no value to keep`)
  const note = isSplit(entry) ? entry.note : undefined
  return note === undefined ? value : { all: value, note }
}

/** Which platforms read something different from `after` than from `before`. */
export function movedOn(before: Entry, after: Entry): Platform[] {
  return PLATFORMS.filter(p => !equal(resolve(before, p), resolve(after, p)))
}

/**
 * Records that `key`'s default moved on `platforms`, in the open revision:
 * the latest one if it has not shipped yet (`released` is the latest one a
 * release carried), else a new one dated `today`. Returns the revision used.
 */
export function recordRevision(file: TuningFile, key: string, platforms: Platform[], released: number, today: string): number {
  if (!platforms.length) return latestRevision(file)
  file.revisions ??= {}
  let r = latestRevision(file)
  if (r <= released) {
    r = Math.max(r, released) + 1
    file.revisions[String(r)] = { date: today }
  }
  const rev = file.revisions[String(r)] as Revision
  for (const p of platforms) rev[p] = [...((rev[p] as string[] | undefined) ?? []), key]
  file.revisions[String(r)] = tidyRevision(rev)
  return r
}

/** A revision's lists rewritten under the broadest targets that cover exactly
 *  the platforms each key moved on (all, then apple, then each platform), so
 *  several bakes in one release still read as one list. */
export function tidyRevision(rev: Revision): Revision {
  const order: string[] = []
  const on = new Map<string, Set<Platform>>()
  for (const t of TARGETS) {
    const list = rev[t]
    if (!Array.isArray(list)) continue
    for (const k of list) {
      if (typeof k !== 'string') continue
      if (!on.has(k)) { on.set(k, new Set()); order.push(k) }
      for (const p of platformsOf(t)) on.get(k)!.add(p)
    }
  }
  const out: Revision = {}
  for (const [k, v] of Object.entries(rev)) if (!(TARGETS as readonly string[]).includes(k)) out[k] = v
  const lists: Partial<Record<Target, string[]>> = {}
  for (const k of order) {
    const left = new Set(on.get(k))
    for (const t of TARGETS) {
      const reach = platformsOf(t)
      if (!reach.every(p => left.has(p))) continue
      for (const p of reach) left.delete(p)
      ;(lists[t] ??= []).push(k)
    }
  }
  for (const t of TARGETS) if (lists[t]) out[t] = lists[t]
  return out
}

// ── Writing ─────────────────────────────────────────────────────────────────
// One line per value, so a diff shows exactly the knob that moved. Arrays of
// objects (the blob slots) get a line per element.

function inline(v: unknown): string {
  if (Array.isArray(v)) return v.length ? `[${v.map(inline).join(', ')}]` : '[]'
  if (v && typeof v === 'object') {
    const parts = Object.entries(v).map(([k, x]) => `${JSON.stringify(k)}: ${inline(x)}`)
    return parts.length ? `{ ${parts.join(', ')} }` : '{}'
  }
  return JSON.stringify(v)
}

const listOfObjects = (v: unknown): v is unknown[] => Array.isArray(v) && v.some(x => x && typeof x === 'object')

function block(entries: [string, unknown][], indent: string): string {
  const lines = entries.map(([k, v]) => {
    const head = `${indent}${JSON.stringify(k)}: `
    if (listOfObjects(v)) {
      return `${head}[\n${v.map(x => `${indent}  ${inline(x)}`).join(',\n')}\n${indent}]`
    }
    // A split list (per-platform slots) gets a line per target, then per element.
    if (isSplit(v) && Object.values(v).some(listOfObjects)) {
      return `${head}{\n${block(Object.entries(v), `${indent}  `)}\n${indent}}`
    }
    return head + inline(v)
  })
  return lines.join(',\n')
}

export function formatTuning(file: TuningFile): string {
  const parts: string[] = []
  if (file.about) parts.push(`  "about": [\n${file.about.map(l => `    ${JSON.stringify(l)}`).join(',\n')}\n  ]`)
  for (const s of SECTIONS) parts.push(`  "${s}": {\n${block(Object.entries(file[s] ?? {}), '    ')}\n  }`)
  const revs = Object.entries(file.revisions ?? {}).sort((a, b) => Number(a[0]) - Number(b[0]))
  parts.push(`  "revisions": {\n${block(revs, '    ')}\n  }`)
  return `{\n${parts.join(',\n')}\n}\n`
}

/** The Swift copy the Apple apps compile in: the file, verbatim. */
export function swiftCopy(json: string): string {
  if (json.includes('"""#')) throw new Error('tuning-defaults.json cannot contain """#')
  return [
    '// Generated by shared/scripts/tuning.mjs from shared/tuning-defaults.json.',
    '// Do not edit: change the JSON (npm run tuning) and this is rewritten. npm test',
    '// fails while it is stale. TuningDefaults.swift reads it.',
    '',
    'enum TuningDefaultsData {',
    '    static let json = #"""',
    json.replace(/\n$/, ''),
    '"""#',
    '}',
    '',
  ].join('\n')
}
