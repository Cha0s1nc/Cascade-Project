// Announcements from the Cascade project to everyone who runs it: a feed at
// announcements.cascade.chaosinc.xyz that maintainers post to from the panel
// at cascade.chaosinc.xyz/admin/announcements (site/, which checks every save
// with validateFeed), fetched by main.js ('announcements-fetch'). The bell in the title bar shows while any are not
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
//
// A Cascade Server plugin adds its own admin's posts (GET
// /CascadeServer/Announcements, capability "announcements"), the same entries
// inside { server: { id, name }, items }. parseServerAnnouncements keeps their
// ids apart per server and labels them with the server's name.
//
// A message a Jellyfin admin sends this session from the dashboard
// (DisplayMessage, server-messages.ts) is kept in the inbox too:
// addServerMessage stores it, and parseAnnouncements reads the stored list
// back as 'server' entries.
//
// `kind` comes from where an entry was read, never from its contents, so a
// server cannot dress its posts up as the project's: the inbox draws an
// Official badge for 'official' and a Server badge for 'server'.

import { cleanText, type ServerMessage } from './server-messages.ts'
import { isNewerVersion } from './update-release.ts'

export type AnnouncementKind = 'official' | 'server'

export interface Announcement {
  id: string
  date: string
  title: string
  body: string
  link: string | null
  kind: AnnouncementKind
  /** Who it is from, for a server's entry: the server's name. */
  source?: string
}

const MAX_ID = 80
const MAX_TITLE = 120
const MAX_BODY = 4000
const MAX_ENTRIES = 50
const MAX_SOURCE = 120
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/

const isDate = (v: unknown): v is string => typeof v === 'string' && DATE_RE.test(v) && !Number.isNaN(Date.parse(v))

/** The entries for this app and version that have not expired, newest first. */
export function parseAnnouncements(raw: unknown, platform: string, version: string, nowMs: number = Date.now(), kind: AnnouncementKind = 'official'): Announcement[] {
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
    const source = cleanText(a.source, MAX_SOURCE)
    out.push({ id, date: a.date, title, body: cleanText(a.body, MAX_BODY), link, kind, ...(source ? { source } : {}) })
  }
  return out.sort((x, y) => y.date.localeCompare(x.date)).slice(0, MAX_ENTRIES)
}

/** A Cascade Server plugin's posts, or none when the answer is not shaped like one. */
export function parseServerAnnouncements(raw: unknown, platform: string, version: string, nowMs: number = Date.now()): Announcement[] {
  const r = raw && typeof raw === 'object' ? raw as Record<string, unknown> : {}
  const server = r.server && typeof r.server === 'object' ? r.server as Record<string, unknown> : {}
  const serverId = cleanText(server.id, 64)
  if (!serverId) return []
  const source = cleanText(server.name, MAX_SOURCE) || 'Your server'
  return parseAnnouncements(r.items, platform, version, nowMs, 'server').map(a => ({ ...a, id: `server:${serverId}:${a.id}`, source }))
}

/** The stored dashboard messages with this one first, as the store keeps them
 *  (read back with parseAnnouncements(..., 'server')). The oldest fall off. */
export function addServerMessage(stored: unknown, message: ServerMessage, serverName: string, nowMs: number = Date.now()): object[] {
  const d = new Date(nowMs)
  const date = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  const entry = { id: `message:${nowMs.toString(36)}`, date, title: message.header, body: message.text, source: cleanText(serverName, MAX_SOURCE) || 'Your server' }
  return [entry, ...(Array.isArray(stored) ? stored : [])].slice(0, MAX_ENTRIES)
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
