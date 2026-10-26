// Announcements from the Cascade project to everyone who runs it: a static
// file, shared/announcements.json, uploaded to R2 by
// .github/workflows/announcements.yml and fetched by main.js
// ('announcements-fetch'). The bell in the title bar shows while any are not
// dismissed, with a dot while any are new since the inbox was last opened.
//
// Every shipped client reads this file forever, so the shape only grows:
//   { id, date: 'YYYY-MM-DD', title, body?, link?: 'https://...',
//     platforms?: ['desktop' | 'mac' | 'ios' | 'tvos'],
//     minVersion?, maxVersion?, expires?: 'YYYY-MM-DD' }
// Missing platforms means every app. The version window is inclusive. An
// entry is shown through the whole of its expires day (UTC). Unknown keys are
// ignored, and an entry that does not parse is dropped, not the whole file.
// Text only: never rendered as HTML or Markdown.

import { cleanText } from './server-messages.ts'
import { isNewerVersion } from './update-release.ts'

export interface Announcement {
  id: string
  date: string
  title: string
  body: string
  link: string | null
}

const MAX_ID = 80
const MAX_TITLE = 120
const MAX_BODY = 4000
const MAX_ENTRIES = 50
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/

const isDate = (v: unknown): v is string => typeof v === 'string' && DATE_RE.test(v) && !Number.isNaN(Date.parse(v))

/** The entries for this app and version that have not expired, newest first. */
export function parseAnnouncements(raw: unknown, platform: string, version: string, nowMs: number = Date.now()): Announcement[] {
  if (!Array.isArray(raw)) return []
  const today = new Date(nowMs).toISOString().slice(0, 10)
  const out: Announcement[] = []
  const ids = new Set<string>()
  for (const e of raw) {
    if (!e || typeof e !== 'object') continue
    const a = e as Record<string, unknown>
    const id = cleanText(a.id, MAX_ID)
    const title = cleanText(a.title, MAX_TITLE)
    if (!id || !title || !isDate(a.date) || ids.has(id)) continue
    if (Array.isArray(a.platforms) && !a.platforms.includes(platform)) continue
    if (typeof a.minVersion === 'string' && isNewerVersion(a.minVersion, version)) continue
    if (typeof a.maxVersion === 'string' && isNewerVersion(version, a.maxVersion)) continue
    if (isDate(a.expires) && a.expires < today) continue
    ids.add(id)
    const link = typeof a.link === 'string' && /^https:\/\/[^\s]+$/i.test(a.link) ? a.link : null
    out.push({ id, date: a.date, title, body: cleanText(a.body, MAX_BODY), link })
  }
  return out.sort((x, y) => y.date.localeCompare(x.date)).slice(0, MAX_ENTRIES)
}

/** Stored id lists are untrusted: anything that is not a string array is empty. */
export function idList(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string') : []
}

/** What the inbox shows, and how many of those are new since it was last opened. */
export function announcementInbox(list: readonly Announcement[], dismissed: unknown, seen: unknown): { items: Announcement[]; unseen: number } {
  const gone = new Set(idList(dismissed))
  const old = new Set(idList(seen))
  const items = list.filter(a => !gone.has(a.id))
  return { items, unseen: items.filter(a => !old.has(a.id)).length }
}
