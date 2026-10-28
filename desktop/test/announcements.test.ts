import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { addServerMessage, announcementInbox, idList, parseAnnouncements, parseServerAnnouncements } from '../src/core/announcements.ts'

// The site Worker is its own folder at the repo root, absent from a checkout
// of the desktop alone.
const SITE = new URL('../../site/src/announcements.js', import.meta.url)
const siteSkip = existsSync(SITE) ? false : 'site/ is not in this checkout'

const NOW = Date.parse('2026-11-10T12:00:00Z')
const base = { id: 'a', date: '2026-11-01', title: 'Hello' }

test('a well formed entry comes through as text, with defaults', () => {
  assert.deepEqual(parseAnnouncements([{ ...base, body: ' Hi\u0007 ', link: 'https://example.com/x', extra: 1 }], 'desktop', '2.3.0', NOW),
    [{ id: 'a', date: '2026-11-01', title: 'Hello', body: 'Hi', link: 'https://example.com/x', kind: 'official' }])
  assert.equal(parseAnnouncements([base], 'desktop', '2.3.0', NOW)[0].body, '')
})

test('broken entries are dropped one at a time, not the whole file', () => {
  const list = parseAnnouncements([null, 7, { ...base, id: '' }, { ...base, title: 3 }, { ...base, date: 'soon' }, { ...base, id: 'ok' }, { ...base, id: 'ok', title: 'dupe' }], 'desktop', '2.3.0', NOW)
  assert.deepEqual(list.map(a => a.id), ['ok'])
  assert.equal(list[0].title, 'Hello')
  assert.deepEqual(parseAnnouncements({ not: 'a list' }, 'desktop', '2.3.0', NOW), [])
})

test('only https links are kept', () => {
  for (const link of ['http://example.com', 'javascript:alert(1)', 'file:///etc/passwd', 'https://a b', 42])
    assert.equal(parseAnnouncements([{ ...base, link }], 'desktop', '2.3.0', NOW)[0].link, null, String(link))
})

test('platforms, the version window and expiry filter', () => {
  const p = (e: object, v = '2.3.0') => parseAnnouncements([{ ...base, ...e }], 'desktop', v, NOW).length
  assert.equal(p({ platforms: ['ios', 'tvos'] }), 0)
  assert.equal(p({ platforms: ['desktop'] }), 1)
  assert.equal(p({ minVersion: '2.3.0', maxVersion: '2.3.0' }), 1)
  assert.equal(p({ minVersion: '2.3.1' }), 0)
  assert.equal(p({ maxVersion: '2.2.9' }), 0)
  assert.equal(p({ maxVersion: '2.3.0' }, '2.3.0-b2'), 1)
  assert.equal(p({ expires: '2026-11-10' }), 1)
  assert.equal(p({ expires: '2026-11-09' }), 0)
})

test('newest first', () => {
  const list = parseAnnouncements([{ ...base, id: 'old', date: '2026-01-01' }, { ...base, id: 'new', date: '2026-10-01' }], 'desktop', '2.3.0', NOW)
  assert.deepEqual(list.map(a => a.id), ['new', 'old'])
})

test('the inbox leaves out dismissed entries and counts the unseen rest', () => {
  const list = parseAnnouncements([{ ...base, id: 'a' }, { ...base, id: 'b' }, { ...base, id: 'c' }], 'desktop', '2.3.0', NOW)
  const inbox = announcementInbox(list, ['b'], ['a'])
  assert.deepEqual(inbox.items.map(a => a.id), ['a', 'c'])
  assert.equal(inbox.unseen, 1)
  assert.deepEqual(announcementInbox(list, 'junk', { a: 1 }).items.length, 3)
  assert.deepEqual(idList(['x', 2, null, 'y']), ['x', 'y'])
})

test("a server's posts keep their ids apart per server and carry its name", () => {
  const raw = { server: { id: 'abc', name: 'Chaos' }, items: [{ ...base, body: '', link: '', source: 'Cascade', kind: 'official' }] }
  assert.deepEqual(parseServerAnnouncements(raw, 'desktop', '2.3.0', NOW),
    [{ id: 'server:abc:a', date: '2026-11-01', title: 'Hello', body: '', link: null, kind: 'server', source: 'Chaos' }])
  assert.equal(parseServerAnnouncements({ ...raw, server: { id: 'abc' } }, 'desktop', '2.3.0', NOW)[0].source, 'Your server')
  assert.deepEqual(parseServerAnnouncements({ items: raw.items }, 'desktop', '2.3.0', NOW), [])
  assert.deepEqual(parseServerAnnouncements(null, 'desktop', '2.3.0', NOW), [])
})

test('a dashboard message is kept as a server entry, newest first, capped', () => {
  const msg = { header: 'Maintenance', text: 'Restarting at 2', timeoutMs: null }
  let stored = addServerMessage(undefined, msg, 'Chaos', NOW)
  stored = addServerMessage(stored, { ...msg, header: 'Back' }, '', NOW + 1000)
  const list = parseAnnouncements(stored, 'desktop', '2.3.0', NOW, 'server')
  assert.deepEqual(list.map(a => [a.title, a.kind, a.source]), [['Back', 'server', 'Your server'], ['Maintenance', 'server', 'Chaos']])
  assert.match(list[0].id, /^message:/)
  assert.notEqual(list[0].id, list[1].id)
  for (let i = 0; i < 60; i++) stored = addServerMessage(stored, msg, 'Chaos', NOW + i * 2000)
  assert.equal(stored.length, 50)
  assert.equal(addServerMessage('junk', msg, 'Chaos', NOW).length, 1)
})

// What the workflow uploads reaches every install: an entry that does not
// parse would silently never show.
test('whatever the panel saves parses in every app', { skip: siteSkip }, async () => {
  // @ts-ignore: plain JS Worker source, no types
  const { validateFeed, stampAuthors, PLATFORMS } = await import(SITE.href)
  const { items } = validateFeed([
    { ...base, body: ' Hi\u0007 ', link: 'https://example.com', platforms: ['tvos', 'desktop'], minVersion: '2.3.0', expires: '2026-12-01' },
    { ...base, id: 'b', author: 'someone' },
  ])
  const saved = stampAuthors(items, [], 'Cha0s1nc')
  assert.deepEqual(saved[0], { id: 'a', title: 'Hello', body: 'Hi', date: '2026-11-01', link: 'https://example.com', platforms: ['desktop', 'tvos'], minVersion: '2.3.0', expires: '2026-12-01', author: 'Cha0s1nc' })
  for (const e of saved) {
    const ok = PLATFORMS.some((p: string) => parseAnnouncements([{ ...e, minVersion: undefined, maxVersion: undefined, expires: undefined }], p, '0.0.0', NOW).length === 1)
    assert.ok(ok, `does not parse: ${JSON.stringify(e)}`)
  }
})

test('the panel rejects a bad save whole, saying why', { skip: siteSkip }, async () => {
  // @ts-ignore: plain JS Worker source, no types
  const { validateFeed } = await import(SITE.href)
  const bad = (e: object) => validateFeed([{ ...base, ...e }]).error
  assert.match(validateFeed({}).error, /list/)
  assert.match(validateFeed([base, base]).error, /used twice/)
  assert.match(bad({ title: '  ' }), /title is required/)
  assert.match(bad({ id: 'x'.repeat(81) }), /over 80/)
  assert.match(bad({ date: '2026-13-40' }), /date/)
  assert.match(bad({ link: 'http://example.com' }), /https/)
  assert.match(bad({ platforms: [] }), /platforms/)
  assert.match(bad({ platforms: ['android'] }), /platforms/)
  assert.match(bad({ minVersion: 'soon' }), /minVersion/)
  assert.match(bad({ kind: 'official' }), /unknown field "kind"/)
  assert.equal(validateFeed(Array(51).fill(0).map((_, i) => ({ ...base, id: `n${i}` }))).error, 'At most 50 announcements')
  assert.deepEqual(validateFeed([{ ...base, body: '', link: '', platforms: null }]).items, [{ id: 'a', title: 'Hello', date: '2026-11-01' }])
})

test('an author sticks until someone changes the entry', { skip: siteSkip }, async () => {
  // @ts-ignore: plain JS Worker source, no types
  const { stampAuthors } = await import(SITE.href)
  const prev = [{ ...base, author: 'alice' }, { ...base, id: 'b', author: 'alice' }]
  const next = stampAuthors([{ ...base }, { ...base, id: 'b', title: 'Edited' }, { ...base, id: 'c' }], prev, 'bob')
  assert.deepEqual(next.map((e: { author: string }) => e.author), ['alice', 'bob', 'bob'])
  assert.deepEqual(stampAuthors([base], 'junk', 'bob')[0].author, 'bob')
})
