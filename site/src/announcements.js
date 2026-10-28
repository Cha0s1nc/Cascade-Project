// The announcements feed as the admin panel saves it. Every Cascade app reads
// this file forever (desktop/src/core/announcements.ts has the shape and the
// client-side parse), so a save is checked here first and rejected whole,
// with the reason, rather than letting a typo reach anyone.

export const PLATFORMS = ['desktop', 'mac', 'ios', 'tvos']
// MAX_ID, MAX_TITLE, MAX_BODY and MAX_ENTRIES in announcements.ts.
const LIMITS = { id: 80, title: 120, body: 4000 }
const MAX_ENTRIES = 50
const DATE = /^\d{4}-\d{2}-\d{2}$/
const VERSION = /^\d+(\.\d+){0,2}(-[0-9A-Za-z.]{1,20})?$/
const LINK = /^https:\/\/[^\s]+$/i
// `author` is accepted so the panel can send back what it loaded, but the
// server sets it (stampAuthors), never the client.
const KEYS = new Set(['id', 'date', 'title', 'body', 'link', 'platforms', 'minVersion', 'maxVersion', 'expires', 'author'])

const isDate = v => typeof v === 'string' && DATE.test(v) && !Number.isNaN(Date.parse(v))
// cleanText in desktop/src/core/server-messages.ts, minus the cut: too long is an error here.
const clean = v => typeof v === 'string' ? v.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').trim() : ''
const blank = v => v === undefined || v === null || v === ''

/** { items } cleaned up for saving, or { error } naming the first problem. */
export function validateFeed(raw) {
  if (!Array.isArray(raw)) return { error: 'Expected a list of announcements' }
  if (raw.length > MAX_ENTRIES) return { error: `At most ${MAX_ENTRIES} announcements` }
  const ids = new Set()
  const items = []
  for (const [i, e] of raw.entries()) {
    const at = `Announcement ${i + 1}`
    if (!e || typeof e !== 'object' || Array.isArray(e)) return { error: `${at} is not an object` }
    const extra = Object.keys(e).find(k => !KEYS.has(k))
    if (extra) return { error: `${at}: unknown field "${extra}"` }

    const out = {}
    for (const k of ['id', 'title', 'body']) {
      const v = clean(e[k])
      if (!blank(e[k]) && typeof e[k] !== 'string') return { error: `${at}: ${k} must be text` }
      if (!v && k !== 'body') return { error: `${at}: ${k} is required` }
      if (v.length > LIMITS[k]) return { error: `${at}: ${k} is over ${LIMITS[k]} characters` }
      if (v) out[k] = v
    }
    if (ids.has(out.id)) return { error: `${at}: id "${out.id}" is used twice` }
    ids.add(out.id)
    if (!isDate(e.date)) return { error: `${at}: date must be YYYY-MM-DD` }
    out.date = e.date
    if (!blank(e.link)) {
      if (typeof e.link !== 'string' || !LINK.test(e.link.trim())) return { error: `${at}: link must start with https://` }
      out.link = e.link.trim()
    }
    if (!blank(e.platforms)) {
      // An empty list would hide it everywhere: leave platforms out for every app.
      if (!Array.isArray(e.platforms) || !e.platforms.length || !e.platforms.every(p => PLATFORMS.includes(p)))
        return { error: `${at}: platforms must be some of ${PLATFORMS.join(', ')}` }
      out.platforms = PLATFORMS.filter(p => e.platforms.includes(p))
    }
    for (const k of ['minVersion', 'maxVersion']) {
      if (blank(e[k])) continue
      if (typeof e[k] !== 'string' || !VERSION.test(e[k].trim())) return { error: `${at}: ${k} must look like 2.3.0` }
      out[k] = e[k].trim()
    }
    if (!blank(e.expires)) {
      if (!isDate(e.expires)) return { error: `${at}: expires must be YYYY-MM-DD` }
      out.expires = e.expires
    }
    items.push(out)
  }
  return { items }
}

/** Each entry with its author: whoever last changed it. An entry saved again
 *  untouched keeps the author it had. */
export function stampAuthors(items, previous, login) {
  const bare = e => JSON.stringify({ ...e, author: undefined })
  const before = new Map((Array.isArray(previous) ? previous : []).filter(e => e && typeof e === 'object').map(e => [e.id, e]))
  return items.map(e => {
    const old = before.get(e.id)
    return { ...e, author: old && typeof old.author === 'string' && bare(old) === bare(e) ? old.author : login }
  })
}
