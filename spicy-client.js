// SpicyLyrics asked from the app itself, for when the Cascade Server plugin
// cannot ask for it: Local mode always, and a Jellyfin server without the
// plugin (docs/local-mode-plan.md, section 6). The rules are pure and tested
// in src/core/spicy-lyrics.ts; this is the part that keeps the key, the cache
// and the requests. No semicolons, like main.js.
//
// The key is the person's own, from an app they made in the SpicyLyrics
// dashboard: a secret key (sl_sk_), or a public one (sl_pk_) with the
// no-origin option on. It never ships in Cascade's code. It is kept in the
// store like the server token, set only through spicy-set-key, and sent to
// api.spicylyrics.org and nowhere else. Requests leave from here, the main
// process, which sends no Origin header: that is what the no-origin option
// allows.
//
// What leaves the machine, per song played (never for a library crawl: the
// renderer asks only for the song playing): its title, artist and album to
// ListenBrainz Labs to find Spotify track ids, then one of those ids to
// SpicyLyrics. Both answers are kept, so a song played again asks nothing:
// the ids until the item changes, the lyrics for SPICY_CACHE_MS (the terms
// allow 30 days).
//
// Layout under app.getPath('userData')/spicy-cache:
//   <spotifyId>.json  { savedAt, raw }: SpicyLyrics' answer as it came
//   ids.json          item id -> { ids, checkedAt }: what ListenBrainz found

const fs = require('fs')
const path = require('path')

/** MetaBrainz asks not to be hammered: one lookup at a time, a second apart,
 *  as the plugin does. Its Labs rate limit is not documented. */
const LISTENBRAINZ_SPACING_MS = 1000
const REQUEST_TIMEOUT_MS = 8000
/** Most songs whose Spotify ids are remembered. */
const MAX_ID_ENTRIES = 20000

/**
 * @param {object} deps
 * @param {Electron.App} deps.app
 * @param {Electron.IpcMain} deps.ipcMain
 * @param {Electron.Net} deps.net
 * @param {{ get: (k: string) => any, set: (k: string, v: any) => void, delete: (k: string) => void }} deps.store
 * @param {typeof import('./src/core/spicy-lyrics')} deps.Spicy  build/spicy-lyrics.js
 */
function createSpicyClient({ app, ipcMain, net, store, Spicy }) {
  const dir = path.join(app.getPath('userData'), 'spicy-cache')
  const idsFile = path.join(dir, 'ids.json')
  const userAgent = `Cascade/${app.getVersion()} (https://github.com/Cha0s1nc/Cascade-Project)`
  /** spotify id -> when SpicyLyrics last had nothing for it. Memory only. */
  const misses = new Map()
  /** Until when each service is left alone after a rate limit. */
  const pausedUntil = { spicy: 0, listenbrainz: 0 }
  let ids = null
  let lbChain = /** @type {Promise<unknown>} */ (Promise.resolve())
  let lbLast = 0

  const key = () => {
    const k = store.get('spicyLyricsKey')
    return Spicy.isSpicyKey(k) ? k.trim() : null
  }

  const isItemId = (v) => typeof v === 'string' && /^[A-Za-z0-9-]{1,64}$/.test(v)

  function loadIds() {
    if (ids) return ids
    try {
      const raw = JSON.parse(fs.readFileSync(idsFile, 'utf8'))
      ids = {}
      for (const [item, e] of Object.entries(raw && typeof raw === 'object' ? raw : {})) {
        if (!isItemId(item) || !e || !Array.isArray(e.ids) || !Number.isFinite(e.checkedAt)) continue
        ids[item] = { ids: e.ids.filter(Spicy.isSpotifyTrackId).slice(0, 10), checkedAt: e.checkedAt }
      }
    } catch { ids = {} }
    return ids
  }

  function saveIds() {
    const entries = Object.entries(ids)
    if (entries.length > MAX_ID_ENTRIES) {
      entries.sort((a, b) => b[1].checkedAt - a[1].checkedAt)
      ids = Object.fromEntries(entries.slice(0, MAX_ID_ENTRIES))
    }
    try {
      fs.mkdirSync(dir, { recursive: true })
      fs.writeFileSync(`${idsFile}.tmp`, JSON.stringify(ids))
      fs.renameSync(`${idsFile}.tmp`, idsFile)
    } catch {}
  }

  async function get(url, headers, service) {
    const res = await net.fetch(url, { headers: { 'User-Agent': userAgent, ...headers }, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) })
    const wait = Spicy.backoffMs(res.status, { retryAfter: res.headers.get('retry-after'), resetIn: res.headers.get('x-ratelimit-reset-in') }, Date.now())
    if (wait) pausedUntil[service] = Math.max(pausedUntil[service], Date.now() + wait)
    return res
  }

  /** One ListenBrainz lookup, in turn and spaced. Null when it could not be
   *  asked, so a failure is not remembered as "no ids". */
  function listenBrainz(artist, album, title) {
    const run = lbChain.then(async () => {
      if (Date.now() < pausedUntil.listenbrainz) return null
      const wait = lbLast + LISTENBRAINZ_SPACING_MS - Date.now()
      if (wait > 0) await new Promise(r => setTimeout(r, wait))
      try {
        const res = await get(Spicy.listenBrainzUrl(artist, album, title), { Accept: 'application/json' }, 'listenbrainz')
        if (!res.ok) return null
        return Spicy.spotifyIdsFromListenBrainz(await res.json())
      } catch { return null } finally { lbLast = Date.now() }
    })
    lbChain = run.catch(() => {})
    return run
  }

  /** The song's Spotify ids, most likely first: remembered, or looked up. */
  async function candidates(itemId, artist, album, title) {
    const known = loadIds()[itemId]
    if (known?.ids.length) return known.ids
    if (known && Date.now() - known.checkedAt < Spicy.SPOTIFY_ID_RETRY_MS) return []
    if (!artist || !title) return []
    let found = await listenBrainz(artist, album, title)
    if (found && !found.length && album) found = await listenBrainz(artist, '', title)
    if (!found) return []
    loadIds()[itemId] = { ids: found, checkedAt: Date.now() }
    saveIds()
    return found
  }

  const cacheFile = (id) => path.join(dir, `${id}.json`)

  function cached(id) {
    try {
      const entry = JSON.parse(fs.readFileSync(cacheFile(id), 'utf8'))
      if (Spicy.spicyCacheFresh(entry?.savedAt, Date.now()) && entry.raw && typeof entry.raw === 'object') return entry.raw
      fs.rmSync(cacheFile(id), { force: true })
    } catch {}
    return null
  }

  /** SpicyLyrics' answer for one Spotify id: cached, or asked. */
  async function lyricsFor(id, k) {
    const hit = cached(id)
    if (hit) return hit
    if (Date.now() - (misses.get(id) ?? -Infinity) < Spicy.SPICY_MISS_MS || Date.now() < pausedUntil.spicy) return null
    try {
      const res = await get(Spicy.spicyLyricsUrl(id), { Authorization: `Bearer ${k}`, Accept: 'application/json' }, 'spicy')
      if (res.status !== 200) {
        // A rate limit is a pause (above), not a statement about the track.
        if (res.status !== 429) misses.set(id, Date.now())
        return null
      }
      const raw = await res.json()
      if (!raw || typeof raw !== 'object' || !raw.Body) { misses.set(id, Date.now()); return null }
      fs.mkdirSync(dir, { recursive: true })
      fs.writeFileSync(cacheFile(id), JSON.stringify({ savedAt: Date.now(), raw }))
      misses.delete(id)
      return raw
    } catch { return null }
  }

  /** Expired answers go, so nothing outlives what the terms allow. */
  function prune() {
    try {
      for (const f of fs.readdirSync(dir)) {
        if (!/^[A-Za-z0-9]{22}\.json$/.test(f)) continue
        try {
          const entry = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'))
          if (!Spicy.spicyCacheFresh(entry?.savedAt, Date.now())) fs.rmSync(path.join(dir, f), { force: true })
        } catch { fs.rmSync(path.join(dir, f), { force: true }) }
      }
    } catch {}
  }

  /**
   * The SpicyLyrics answer for a song, or null: no key, no Spotify id, no
   * lyrics, a pause after a rate limit, or a sync made for a longer version
   * (spicyFitsTrack), which drifts against this file. A Spotify id the
   * person linked by hand is used as it is, as the plugin does.
   */
  async function find(q) {
    const k = key()
    if (!k || !q || !isItemId(q.itemId)) return null
    const str = (v) => typeof v === 'string' ? v.trim().slice(0, 300) : ''
    const manual = Spicy.isSpotifyTrackId(q.spotifyId) ? q.spotifyId : null
    const list = manual ? [manual] : await candidates(q.itemId, str(q.artist), str(q.album), str(q.title))
    for (const id of list.slice(0, Spicy.MAX_SPICY_CANDIDATES)) {
      const raw = await lyricsFor(id, k)
      if (!raw) continue
      if (!manual && !Spicy.spicyFitsTrack(raw, Number(q.durationSec) || 0)) continue
      // The one that worked goes first next time.
      const known = loadIds()[q.itemId]
      if (!manual && known && known.ids[0] !== id) { known.ids = [id, ...known.ids.filter(x => x !== id)]; saveIds() }
      return { raw, spotifyId: id }
    }
    return null
  }

  function register() {
    ipcMain.handle('spicy-lyrics', (_e, q) => find(q))
    ipcMain.handle('spicy-status', () => ({ hasKey: !!key() }))
    // Checked here, not only in Settings: this is what goes out as the key.
    ipcMain.handle('spicy-set-key', (_e, k) => {
      if (k === null || k === '') { store.delete('spicyLyricsKey'); return { ok: true } }
      if (!Spicy.isSpicyKey(k)) return { ok: false, error: "That doesn't look like a Spicy Lyrics key (sl_sk_... or sl_pk_...)." }
      store.set('spicyLyricsKey', k.trim())
      return { ok: true }
    })
    setTimeout(prune, 30000)
  }

  return { register }
}

module.exports = { createSpicyClient }
