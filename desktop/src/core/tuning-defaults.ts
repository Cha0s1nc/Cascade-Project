// The desktop's view of tuning-defaults.json (see tuning.ts for the format):
// every value this platform ships with, read once. esbuild inlines the file
// into build/core.js, so a changed default needs `npm run build:core`.

import raw from '../../../tuning-defaults.json' with { type: 'json' }
import { latestRevision, resolveNumbers, resolveSection, revisionKeys, type Section, type TuningFile } from './tuning.ts'

export const TUNING_FILE = raw as unknown as TuningFile

/** One section's values for the desktop. */
export function desktopTuning(section: Section): Record<string, unknown> {
  return resolveSection(TUNING_FILE, section, 'desktop')
}

const numbers: Partial<Record<Section, Record<string, number>>> = {}

/** A number the desktop must have. A missing or non-number one is a broken
 *  tuning-defaults.json, which npm test catches; failing loudly here beats
 *  shipping a knob whose default is quietly made up. */
export function shippedNumber(section: Section, key: string): number {
  const values = numbers[section] ??= resolveNumbers(TUNING_FILE, section, 'desktop')
  const v = values[key]
  if (v === undefined) throw new Error(`tuning-defaults.json: no desktop number for ${section}.${key}`)
  return v
}

/** The latest defaults revision, and the style keys each one moved here. */
export const TUNING_REVISION = latestRevision(TUNING_FILE)
export function desktopRevisionKeys(r: number): string[] {
  return revisionKeys(TUNING_FILE, 'desktop', r)
}
