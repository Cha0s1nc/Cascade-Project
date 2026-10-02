// Offline downloads, main process side: the files, the one index of them, the
// download queue and the protocol that plays them back. The rules (what a
// removal may delete, what counts as a finished download) are pure and tested
// in src/core/offline-index.ts; this file is the part that touches the disk and
// the network. No semicolons, like main.js.
//
// Layout under app.getPath('userData')/offline/<userId>, one folder per
// account so the next person to sign in never sees, plays or resumes the last
// one's downloads (Jellyfin user ids are GUIDs, unique across servers, and the
// same account reached at another address keeps its music):
//   index.json        the one index, relative paths only, validated when read
//   media/<id>.<ext>  a finished track; media/<id>.partial while it downloads
//   art/<id>.jpg      cover art, so the Downloads view works with no server
// ponytail: a user deleted on the server leaves its folder behind; add a
// cleanup when someone asks where the disk space went.

const fs = require('fs')
const path = require('path')
const { Readable } = require('stream')

const PARALLEL = 2
const PROGRESS_MS = 250
const SAVE_DEBOUNCE_MS = 500

/**
 * @param {object} deps
 * @param {Electron.App} deps.app
 * @param {Electron.IpcMain} deps.ipcMain
 * @param {Electron.Net} deps.net
 * @param {Electron.Protocol} deps.protocol
 * @param {() => Electron.BrowserWindow | null} deps.getWindow
 * @param {() => string | null} deps.getServerUrl
 * @param {(url: string) => {name: string, value: string}[]} deps.headersFor  custom reverse proxy headers for a URL
 * @param {typeof import('./src/core/offline-index')} deps.Offline  build/offline-index.js
 */
function createOffline({ app, ipcMain, net, protocol, getWindow, getServerUrl, headersFor, Offline }) {
  const base = path.join(app.getPath('userData'), 'offline')
  /** The signed-in account's folder, or null with nobody signed in: then every
   *  call answers empty and the protocol serves nothing. */
  let owner = null
  let root = null
  let mediaDir = null
  let artDir = null
  let indexFile = null

  /** Replaced (never mutated into another account's) on every owner change, so
   *  work that started for one account can tell it is stale after an await. */
  let index = Offline.emptyIndex()
  /** Art on disk, by item id. Derived from the folder, not stored. */
  let art = new Set()
  /** What the renderer last told us about who is signed in. Memory only. */
  let session = null
  /** id -> { received, total, controller } */
  const active = new Map()
  /** id -> message, for downloads that failed since the last attempt. */
  const failed = new Map()
  let running = false
  let networkDown = false
  let saveTimer = null

  // ── Index on disk ──────────────────────────────────────────────────────────

  /** Switches to `userId`'s downloads, or to none. The outgoing account's index
   *  is written first and its downloads stopped (they resume when it signs in
   *  again), and the token it was downloading with is dropped. */
  function setOwner(userId) {
    const next = Offline.isSafeUserId(userId) ? userId : null
    if (next === owner) return
    flush()
    for (const a of active.values()) a.controller.abort()
    failed.clear()
    session = null
    owner = next
    index = Offline.emptyIndex()
    art = new Set()
    if (!owner) { root = mediaDir = artDir = indexFile = null; return }
    root = path.join(base, owner)
    mediaDir = path.join(root, 'media')
    artDir = path.join(root, 'art')
    indexFile = path.join(root, 'index.json')
    load()
  }

  function load() {
    fs.mkdirSync(mediaDir, { recursive: true })
    fs.mkdirSync(artDir, { recursive: true })
    try { index = Offline.parseIndex(JSON.parse(fs.readFileSync(indexFile, 'utf8'))) } catch { index = Offline.emptyIndex() }

    // The disk is the truth about files. A ready track whose file is gone goes
    // back to pending; a file nobody lists (an unfinished download, one that
    // finished after its collection was removed) is deleted.
    const onDisk = fs.readdirSync(mediaDir).map(f => `media/${f}`)
    for (const stray of Offline.reconcile(index, onDisk)) {
      if (Offline.isSafeMediaPath(stray)) fs.rmSync(path.join(root, stray), { force: true })
    }
    art = new Set(fs.readdirSync(artDir).filter(f => Offline.isSafeArtPath(`art/${f}`)).map(f => f.slice(0, -4)))
    for (const f of fs.readdirSync(artDir)) if (f.endsWith('.partial')) fs.rmSync(path.join(artDir, f), { force: true })
    saveNow()
  }

  function saveNow() {
    clearTimeout(saveTimer); saveTimer = null
    if (!indexFile) return
    const tmp = `${indexFile}.tmp`
    fs.writeFileSync(tmp, JSON.stringify(index))
    fs.renameSync(tmp, indexFile)
  }

  function scheduleSave() {
    if (saveTimer) return
    saveTimer = setTimeout(() => { try { saveNow() } catch {} }, SAVE_DEBOUNCE_MS)
  }

  function emit(event) {
    const win = getWindow()
    if (win && !win.isDestroyed()) win.webContents.send('offline-event', event)
  }

  // ── What the renderer reads ────────────────────────────────────────────────

  const urlFor = (file) => `cascade-offline://local/${file}`

  /** Everything the app needs to know at a glance. Track lists are separate. */
  function summary() {
    const ready = {}
    for (const [id, t] of Object.entries(index.tracks)) if (t.file) ready[id] = urlFor(t.file)
    return {
      ready,
      art: [...art],
      collections: index.collections.map(c => ({
        item: c.item,
        trackIds: c.trackIds,
        ...Offline.collectionProgress(index, c.item.Id),
        bytes: Offline.collectionBytes(index, c.item.Id),
      })),
      totalBytes: Offline.totalBytes(index),
      active: [...active.entries()].map(([id, a]) => ({ id, received: a.received, total: a.total })),
      failed: Object.fromEntries(failed),
      plays: index.plays.length,
    }
  }

  function tracksOf(collectionId) {
    if (!owner) return []
    const c = Offline.collectionOf(index, collectionId)
    if (!c) return []
    return c.trackIds.map(id => ({ item: index.tracks[id].item, ready: !!index.tracks[id].file }))
  }

  // ── Downloading ────────────────────────────────────────────────────────────

  function requestHeaders(url) {
    const headers = { Authorization: session.authorization }
    for (const h of headersFor(url)) headers[h.name] = h.value
    return headers
  }

  async function downloadTrack(id) {
    const server = getServerUrl()
    const url = `${server.replace(/\/+$/, '')}/Items/${id}/Download`
    const mine = index
    const dir = root
    const partial = path.join(mediaDir, `${id}.partial`)
    const state = { received: 0, total: null, reachedServer: false, controller: new AbortController() }
    active.set(id, state)
    emit({ type: 'progress', id, received: 0, total: null })
    let out = null
    try {
      const res = await net.fetch(url, { headers: requestHeaders(url), signal: state.controller.signal })
      state.reachedServer = true
      const announced = Number(res.headers.get('content-length'))
      // A response the network layer decompressed no longer matches its
      // announced length, so there is nothing to compare it with.
      const encoded = (res.headers.get('content-encoding') || 'identity').toLowerCase() !== 'identity'
      state.total = !encoded && Number.isFinite(announced) && announced > 0 ? announced : null

      if (!res.ok) await res.body?.cancel().catch(() => {})
      if (res.ok && res.body) {
        out = fs.createWriteStream(partial)
        let lastEmit = 0
        for await (const chunk of res.body) {
          state.received += chunk.length
          if (!out.write(chunk)) await new Promise(r => out.once('drain', r))
          const now = Date.now()
          if (now - lastEmit >= PROGRESS_MS) { lastEmit = now; emit({ type: 'progress', id, received: state.received, total: state.total }) }
        }
        await new Promise((resolve, reject) => { out.once('error', reject); out.end(resolve) })
        out = null
      }

      const verdict = Offline.judgeDownload({
        status: res.status, expected: state.total, received: state.received,
        contentDisposition: res.headers.get('content-disposition'), contentType: res.headers.get('content-type'),
      })
      // Dropped by a removal, or the account signed out, while it ran: the
      // file is nobody's now.
      if (index !== mine || !index.tracks[id]) { fs.rmSync(partial, { force: true }); return }
      if (!verdict.ok) { fs.rmSync(partial, { force: true }); failed.set(id, verdict.message); return }

      const file = `media/${id}.${verdict.ext}`
      fs.renameSync(partial, path.join(dir, file))
      Offline.markReady(index, id, file, state.received)
      failed.delete(id)
      scheduleSave()
      emit({ type: 'track-done', id, url: urlFor(file) })
    } catch (e) {
      try { out?.destroy() } catch {}
      fs.rmSync(partial, { force: true })
      if (state.controller.signal.aborted || index !== mine) return
      if (state.reachedServer) {
        // Cut off partway: this track failed, the next may well be fine.
        failed.set(id, 'The download was interrupted.')
      } else {
        // The server could not be reached at all: the rest would fail the same
        // way, so stop here and let the next resume try again.
        networkDown = true
        failed.set(id, 'Could not reach the server.')
      }
    } finally {
      active.delete(id)
      emit({ type: 'changed' })
    }
  }

  /** Runs until nothing is pending, a few tracks at once. One loop at a time. */
  async function pump() {
    if (running || !owner || !session || !getServerUrl()) return
    running = true
    networkDown = false
    const mine = index
    try {
      const workers = Array.from({ length: PARALLEL }, async () => {
        while (true) {
          if (networkDown || index !== mine || !session) return
          const id = Offline.pendingTrackIds(index).find(t => !active.has(t) && !failed.has(t))
          if (!id) return
          await downloadTrack(id)
        }
      })
      // Covers alongside the tracks, so the Downloads view is not bare until the last one lands.
      await Promise.all([...workers, fetchMissingArt()])
    } finally {
      running = false
      emit({ type: 'changed' })
      // Another account signed in while this one's queue wound down.
      if (index !== mine) pump()
    }
  }

  /** Covers for every album and playlist asked for, and each track's album, so
   *  the Downloads view and the player bar need no server. */
  async function fetchMissingArt() {
    const server = getServerUrl()
    if (!server || !session) return
    const mine = index
    const dir = artDir
    const ids = new Set()
    for (const c of index.collections) {
      ids.add(c.item.Id)
      for (const id of c.trackIds) { const a = index.tracks[id]?.item.AlbumId; if (a) ids.add(a) }
    }
    for (const id of ids) {
      if (index !== mine || !session) return
      if (art.has(id) || !Offline.isSafeId(id)) continue
      const url = `${server.replace(/\/+$/, '')}/Items/${id}/Images/Primary?maxWidth=600&quality=90&format=Jpg`
      const partial = path.join(dir, `${id}.partial`)
      try {
        const res = await net.fetch(url, { headers: requestHeaders(url) })
        // 404 is the normal "this item has no art".
        if (!res.ok || !(res.headers.get('content-type') || '').startsWith('image/')) continue
        const body = Buffer.from(await res.arrayBuffer())
        if (index !== mine) return
        fs.writeFileSync(partial, body)
        fs.renameSync(partial, path.join(dir, `${id}.jpg`))
        art.add(id)
        emit({ type: 'art', id })
      } catch {
        // No server: the rest would fail the same way.
        fs.rmSync(partial, { force: true })
        return
      }
    }
  }

  // ── Playback: a custom protocol, never file:// ─────────────────────────────

  /**
   * Serves a downloaded file to a media element. Only files the index says are
   * whole (never a .partial) and only inside the offline folder: the path comes
   * off a URL the renderer made, so it is checked twice, by shape and by
   * serveWithin's escape guard. Range requests are passed through, so seeking
   * works. The CORS header is what lets the Web Audio graph read the element.
   */
  function registerProtocol() {
    protocol.handle('cascade-offline', async (req) => {
      const url = new URL(req.url)
      const rel = decodeURIComponent(url.pathname).replace(/^\/+/, '')
      const allowed = Offline.isSafeMediaPath(rel)
        ? Offline.indexedFiles(index).has(rel)
        : Offline.isSafeArtPath(rel) && art.has(rel.slice(4, -4))
      if (!root || url.host !== 'local' || !allowed) return new Response('Not found', { status: 404 })
      const abs = path.normalize(path.join(root, rel))
      if (!abs.startsWith(root + path.sep)) return new Response('Forbidden', { status: 403 })
      let size
      try { size = fs.statSync(abs).size } catch { return new Response('Not found', { status: 404 }) }

      // Ranges are answered here, from the file, rather than left to net.fetch:
      // a media element seeks with them and needs a real 206 with Content-Range.
      const headers = {
        'content-type': Offline.contentTypeForFile(rel),
        'accept-ranges': 'bytes',
        'access-control-allow-origin': '*',
      }
      const range = Offline.parseByteRange(req.headers.get('range'), size)
      if (range === 'unsatisfiable') return new Response(null, { status: 416, headers: { ...headers, 'content-range': `bytes */${size}` } })
      if (range === null) {
        return new Response(/** @type {any} */ (Readable.toWeb(fs.createReadStream(abs))), { status: 200, headers: { ...headers, 'content-length': String(size) } })
      }
      return new Response(/** @type {any} */ (Readable.toWeb(fs.createReadStream(abs, { start: range.start, end: range.end }))), {
        status: 206,
        headers: { ...headers, 'content-range': `bytes ${range.start}-${range.end}/${size}`, 'content-length': String(range.end - range.start + 1) },
      })
    })
  }

  // ── IPC ────────────────────────────────────────────────────────────────────

  // The renderer holds the token. It is passed with each call that needs it and
  // kept in memory only: nothing about who is signed in is stored here.
  function takeSession(s) {
    if (s && typeof s.authorization === 'string' && s.authorization.length < 2000 && !/[\r\n]/.test(s.authorization)) {
      session = { authorization: s.authorization }
    }
  }

  function register() {
    // The renderer says who is signed in: at launch (from the store, so offline
    // mode finds that account's music), on every sign-in, and null on sign-out.
    ipcMain.handle('offline-owner', (_e, userId) => { setOwner(userId) })
    ipcMain.handle('offline-summary', () => summary())
    ipcMain.handle('offline-tracks', (_e, collectionId) => Offline.isSafeId(collectionId) ? tracksOf(collectionId) : [])

    ipcMain.handle('offline-add', (_e, collection, tracks, s) => {
      if (!owner || !collection || !Offline.isSafeId(collection.Id) || !Array.isArray(tracks) || !tracks.length) return false
      takeSession(s)
      Offline.addCollection(index, collection, tracks)
      for (const id of index.collections[0].trackIds) failed.delete(id)
      saveNow()
      emit({ type: 'changed' })
      pump()
      return true
    })

    ipcMain.handle('offline-remove', (_e, collectionId) => {
      if (!owner || !Offline.isSafeId(collectionId)) return false
      const orphans = Offline.removeCollection(index, collectionId)
      // Stop what is downloading for tracks nobody wants now.
      for (const [id, a] of active) if (!index.tracks[id]) a.controller.abort()
      for (const id of [...failed.keys()]) if (!index.tracks[id]) failed.delete(id)
      for (const file of orphans) if (Offline.isSafeMediaPath(file)) fs.rmSync(path.join(root, file), { force: true })
      // A cover only the removed collection used.
      const keep = new Set()
      for (const c of index.collections) { keep.add(c.item.Id); for (const id of c.trackIds) { const a = index.tracks[id]?.item.AlbumId; if (a) keep.add(a) } }
      for (const id of [...art]) if (!keep.has(id)) { fs.rmSync(path.join(artDir, `${id}.jpg`), { force: true }); art.delete(id) }
      saveNow()
      emit({ type: 'changed' })
      return true
    })

    // Start whatever is asked for and not on disk: after a relaunch, a failure,
    // or on reconnect. Clears failures so each gets another try.
    ipcMain.handle('offline-resume', (_e, s) => {
      if (!owner) return
      takeSession(s)
      failed.clear()
      pump()
    })

    ipcMain.handle('offline-play-add', (_e, play) => {
      const date = new Date(play?.date)
      // What the renderer sends is checked like anything read from disk.
      if (!owner || !Offline.isSafeId(play?.itemId) || !Offline.isSafeUserId(play.userId) || Number.isNaN(date.getTime())) return
      Offline.addPlay(index, { itemId: play.itemId, userId: play.userId, date: date.toISOString() })
      scheduleSave()
    })
    // Hands every queued play over and empties the queue; the renderer puts
    // back the ones the server did not accept yet.
    ipcMain.handle('offline-plays-take', () => { const plays = index.plays; index.plays = []; saveNow(); return plays })
  }

  function flush() { try { if (saveTimer) saveNow() } catch {} }

  return { register, registerProtocol, flush }
}

module.exports = { createOffline }
