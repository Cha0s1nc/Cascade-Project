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
//   media/<id>.<ext>  a finished track, movie or episode; media/<id>.partial while it downloads
//   subs/<id>.<n>.vtt a video's text subtitle stream n, as WebVTT
//   art/<id>.jpg      cover art, posters and episode stills, so the Downloads view works with no server
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
 * @param {typeof import('./src/core/offline-video')} deps.Video  build/offline-video.js
 */
function createOffline({ app, ipcMain, net, protocol, getWindow, getServerUrl, headersFor, Offline, Video }) {
  const base = path.join(app.getPath('userData'), 'offline')
  /** The signed-in account's folder, or null with nobody signed in: then every
   *  call answers empty and the protocol serves nothing. */
  let owner = null
  let root = null
  let mediaDir = null
  let artDir = null
  let subsDir = null
  let indexFile = null

  /** Replaced (never mutated into another account's) on every owner change, so
   *  work that started for one account can tell it is stale after an await. */
  let index = Offline.emptyIndex()
  /** Art on disk, by item id. Derived from the folder, not stored. */
  let art = new Set()
  /** What the renderer last told us about who is signed in. Memory only. */
  let session = null
  /** id -> { received, total, controller, video, outcome, estimate, startedAt } */
  const active = new Map()
  /** The video download profile, built by the renderer from what this
   *  machine decodes and the quality setting (offline-video.ts). Null until
   *  it says: a video waits rather than guess. */
  let videoProfile = null
  /** id -> message, for downloads that failed since the last attempt. */
  const failed = new Map()
  let running = false
  /** The download workers alive now, PARALLEL at most. */
  const workers = new Set()
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
    if (!owner) { root = mediaDir = artDir = subsDir = indexFile = null; return }
    root = path.join(base, owner)
    mediaDir = path.join(root, 'media')
    artDir = path.join(root, 'art')
    subsDir = path.join(root, 'subs')
    indexFile = path.join(root, 'index.json')
    load()
  }

  function load() {
    fs.mkdirSync(mediaDir, { recursive: true })
    fs.mkdirSync(artDir, { recursive: true })
    fs.mkdirSync(subsDir, { recursive: true })
    try { index = Offline.parseIndex(JSON.parse(fs.readFileSync(indexFile, 'utf8'))) } catch { index = Offline.emptyIndex() }

    // The disk is the truth about files. A ready track whose file is gone goes
    // back to pending; a file nobody lists (an unfinished download, one that
    // finished after its collection was removed) is deleted.
    const onDisk = [...fs.readdirSync(mediaDir).map(f => `media/${f}`), ...fs.readdirSync(subsDir).map(f => `subs/${f}`)]
    for (const stray of Offline.reconcile(index, onDisk)) {
      if (Offline.isSafeMediaPath(stray) || Offline.isSafeSubtitlePath(stray)) fs.rmSync(path.join(root, stray), { force: true })
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
    /** A ready video's saved subtitles, as <track> sources. */
    const subs = {}
    for (const [id, t] of Object.entries(index.tracks)) {
      if (!t.file) continue
      ready[id] = urlFor(t.file)
      if (t.subs) subs[id] = t.subs.map(x => ({ ...x, url: urlFor(x.file) }))
    }
    return {
      ready,
      subs,
      art: [...art],
      collections: index.collections.map(c => ({
        item: c.item,
        trackIds: c.trackIds,
        follow: !!c.follow,
        ...Offline.collectionProgress(index, c.item.Id),
        bytes: Offline.collectionBytes(index, c.item.Id),
      })),
      totalBytes: Offline.totalBytes(index),
      active: [...active.entries()].map(([id, a]) => ({
        id, received: a.received, total: a.total, outcome: a.outcome, estimate: a.estimate, startedAt: a.startedAt,
      })),
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

  const isVideoId = (id) => { const type = index.tracks[id]?.item.Type; return type === 'Movie' || type === 'Episode' }

  /**
   * How to fetch a movie or episode: the original when it plays here, else
   * the server's progressive MP4 (offline-video.ts says which and why). Asked
   * afresh every time a download starts: a TranscodingUrl carries the token
   * and a session that ends, so it is never stored. Text subtitles and the
   * intro and credits segments are saved first; they are small.
   */
  async function planVideo(id, state) {
    const server = getServerUrl().replace(/\/+$/, '')
    const t = index.tracks[id]
    const url = `${server}/Items/${id}/PlaybackInfo?UserId=${encodeURIComponent(owner)}`
    const res = await net.fetch(url, {
      method: 'POST', signal: state.controller.signal,
      headers: { ...requestHeaders(url), 'Content-Type': 'application/json' },
      body: JSON.stringify(Video.downloadPlaybackInfoBody(owner, videoProfile, t.burnIn ?? null)),
    })
    state.reachedServer = true
    if (!res.ok) throw Object.assign(new Error(`The server answered HTTP ${res.status}.`), { judged: true })
    const info = await res.json()
    const source = info?.MediaSources?.[0]
    if (!source) throw Object.assign(new Error('The server offered no way to download this.'), { judged: true })
    const outcome = Video.downloadOutcome(source)
    // Only a path on this server: the auth header must never go anywhere else.
    if (outcome !== 'direct' && !/^\/[^/\\]/.test(String(source.TranscodingUrl))) {
      throw Object.assign(new Error('The server offered no way to download this.'), { judged: true })
    }
    state.outcome = outcome
    state.estimate = Video.estimatedBytes(outcome, source, t.item.RunTimeTicks)
    state.playSessionId = typeof info.PlaySessionId === 'string' ? info.PlaySessionId : null
    Offline.setOutcome(index, id, outcome)
    emit({ type: 'progress', id, received: 0, total: null, outcome: state.outcome, estimate: state.estimate, startedAt: state.startedAt })
    await saveVideoExtras(id, source, server, state)
    return outcome === 'direct' ? `${server}/Items/${id}/Download` : `${server}${source.TranscodingUrl}`
  }

  /** Text subtitles as WebVTT beside the file, and the media segments. A
   *  failure here costs those extras, never the film. */
  async function saveVideoExtras(id, source, server, state) {
    const mine = index
    const subs = []
    for (const s of source.MediaStreams || []) {
      if (s?.Type !== 'Subtitle' || !s.IsTextSubtitleStream || !Number.isInteger(s.Index) || !Offline.isSafeId(source.Id)) continue
      const file = `subs/${id}.${s.Index}.vtt`
      if (!Offline.isSafeSubtitlePath(file)) continue
      const url = `${server}/Videos/${id}/${source.Id}/Subtitles/${s.Index}/0/Stream.vtt`
      try {
        const res = await net.fetch(url, { headers: requestHeaders(url), signal: state.controller.signal })
        if (!res.ok) continue
        const body = Buffer.from(await res.arrayBuffer())
        if (index !== mine) return
        fs.writeFileSync(path.join(root, file), body)
        subs.push({ index: s.Index, file, language: s.Language, title: s.DisplayTitle, isDefault: !!s.IsDefault, isForced: !!s.IsForced })
      } catch { if (state.controller.signal.aborted) return }
    }
    Offline.setSubtitles(index, id, subs)
    try {
      const url = `${server}/MediaSegments/${id}`
      const res = await net.fetch(url, { headers: requestHeaders(url), signal: state.controller.signal })
      if (res.ok && index === mine) Offline.setSegments(index, id, (await res.json())?.Items || [])
    } catch {}
    scheduleSave()
  }

  /** Stops the server's encode for a transcode nobody will finish reading.
   *  Never without a session id: without one the server stops every encode
   *  this device has, a film being watched included. */
  function stopEncoding(state) {
    const server = getServerUrl()
    const deviceId = /DeviceId="([^"]+)"/.exec(session?.authorization || '')?.[1]
    if (!server || !state.playSessionId || !deviceId) return
    const url = `${server.replace(/\/+$/, '')}/Videos/ActiveEncodings?deviceId=${encodeURIComponent(deviceId)}&playSessionId=${encodeURIComponent(state.playSessionId)}`
    net.fetch(url, { method: 'DELETE', headers: requestHeaders(url) }).catch(() => {})
  }

  /** Where a downloaded fragmented MP4 ends, reading box headers only. */
  function fragmentEnd(file) {
    let fd = null
    try {
      fd = fs.openSync(file, 'r')
      const size = fs.fstatSync(fd).size
      return Video.fragmentedEndSeconds((offset, length) => {
        const buf = Buffer.alloc(length)
        return buf.subarray(0, fs.readSync(fd, buf, 0, length, offset))
      }, size)
    } catch { return null } finally { if (fd !== null) fs.closeSync(fd) }
  }

  async function downloadTrack(id) {
    const server = getServerUrl()
    const video = isVideoId(id)
    const mine = index
    const dir = root
    const partial = path.join(mediaDir, `${id}.partial`)
    const state = {
      received: 0, total: null, reachedServer: false, controller: new AbortController(),
      video, outcome: null, estimate: null, playSessionId: null, startedAt: Date.now(),
    }
    active.set(id, state)
    emit({ type: 'progress', id, received: 0, total: null })
    let out = null
    try {
      if (video && index.user?.Policy?.EnableContentDownloading === false) {
        throw Object.assign(new Error('The server does not allow this account to download. An admin can turn on media downloading for it.'), { judged: true })
      }
      const url = video ? await planVideo(id, state) : `${server.replace(/\/+$/, '')}/Items/${id}/Download`
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
          if (now - lastEmit >= PROGRESS_MS) { lastEmit = now; emit({ type: 'progress', id, received: state.received, total: state.total, outcome: state.outcome, estimate: state.estimate, startedAt: state.startedAt }) }
        }
        await new Promise((resolve, reject) => { out.once('error', reject); out.end(resolve) })
        out = null
      }

      const judged = Offline.judgeDownload({
        status: res.status, expected: state.total, received: state.received,
        contentDisposition: res.headers.get('content-disposition'), contentType: res.headers.get('content-type'), video,
      })
      // A transcode has no length to check: its last fragment must reach the end.
      const verdict = judged.ok && video && state.outcome !== 'direct'
        && !Video.isWholeTranscode(fragmentEnd(partial), mine.tracks[id]?.item.RunTimeTicks)
        ? { ok: /** @type {false} */ (false), message: 'The server stopped converting partway. Try again.' }
        : judged
      // Dropped by a removal, or the account signed out, while it ran: the
      // file is nobody's now.
      if (index !== mine || !index.tracks[id]) { fs.rmSync(partial, { force: true }); return }
      if (!verdict.ok) { fs.rmSync(partial, { force: true }); failed.set(id, verdict.message); return }

      const file = `media/${id}.${verdict.ext}`
      fs.renameSync(partial, path.join(dir, file))
      Offline.markReady(index, id, file, state.received, new Date())
      failed.delete(id)
      scheduleSave()
      emit({ type: 'track-done', id, url: urlFor(file) })
    } catch (e) {
      try { out?.destroy() } catch {}
      fs.rmSync(partial, { force: true })
      // Cancelled or cut off: the server would go on encoding for nobody.
      if (state.outcome && state.outcome !== 'direct') stopEncoding(state)
      if (state.controller.signal.aborted || index !== mine) return
      if (e?.judged) {
        failed.set(id, e.message)
      } else if (state.reachedServer) {
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

  /** Starts workers up to PARALLEL, each taking pending tracks until none it
   *  may take is left. */
  function startWorkers(mine) {
    while (workers.size < PARALLEL) {
      const w = (async () => {
        while (true) {
          if (networkDown || index !== mine || !session) return
          // One video at a time beside music (plan section 8): a film is
          // gigabytes, and a re-encode is the server's GPU for a while.
          const videoBusy = [...active.values()].some(a => a.video)
          const id = Offline.pendingTrackIds(index).find(t => !active.has(t) && !failed.has(t)
            && (!isVideoId(t) || (!videoBusy && videoProfile)))
          if (!id) return
          await downloadTrack(id)
        }
      })().finally(() => workers.delete(w))
      workers.add(w)
    }
  }

  /** Runs until nothing is pending, a few tracks at once. One loop at a time;
   *  work asked for while it runs tops its workers back up, since one that
   *  found only videos behind a running video has already gone. */
  async function pump() {
    if (!owner || !session || !getServerUrl()) return
    if (running) return startWorkers(index)
    running = true
    networkDown = false
    const mine = index
    try {
      startWorkers(mine)
      // Covers alongside the tracks, so the Downloads view is not bare until the last one lands.
      const art = fetchMissingArt()
      // Late workers join the set, so wait until it drains.
      while (workers.size) await Promise.all(workers)
      await art
      // And once more for anything asked for while this queue ran.
      if (index === mine) await fetchMissingArt()
    } finally {
      running = false
      emit({ type: 'changed' })
      // Another account signed in while this one's queue wound down.
      if (index !== mine) pump()
    }
  }

  /** Art worth keeping: every collection's, each track's album, and for
   *  video the poster or still of each item, its series and its season. */
  function artIds() {
    const ids = new Set()
    for (const c of index.collections) {
      ids.add(c.item.Id)
      for (const id of c.trackIds) {
        const item = index.tracks[id]?.item
        if (!item) continue
        if (item.AlbumId) ids.add(item.AlbumId)
        if (item.Type === 'Movie' || item.Type === 'Episode') {
          ids.add(id)
          if (item.SeriesId) ids.add(item.SeriesId)
          if (item.SeasonId) ids.add(item.SeasonId)
        }
      }
    }
    return ids
  }

  /** Covers for every album and playlist asked for, and each track's album, so
   *  the Downloads view and the player bar need no server. */
  async function fetchMissingArt() {
    const server = getServerUrl()
    if (!server || !session) return
    const mine = index
    const dir = artDir
    const ids = new Set()
    for (const id of artIds()) ids.add(id)
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
      const allowed = Offline.isSafeMediaPath(rel) || Offline.isSafeSubtitlePath(rel)
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

  /** Deletes files nothing in the index holds now, and art nothing uses. */
  function deleteOrphans(orphans) {
    for (const file of orphans) {
      if (Offline.isSafeMediaPath(file) || Offline.isSafeSubtitlePath(file)) fs.rmSync(path.join(root, file), { force: true })
    }
    const keep = artIds()
    for (const id of [...art]) if (!keep.has(id)) { fs.rmSync(path.join(artDir, `${id}.jpg`), { force: true }); art.delete(id) }
  }

  function register() {
    // The renderer says who is signed in: at launch (from the store, so offline
    // mode finds that account's music), on every sign-in, and null on sign-out.
    ipcMain.handle('offline-owner', (_e, userId) => { setOwner(userId) })
    ipcMain.handle('offline-summary', () => summary())
    ipcMain.handle('offline-tracks', (_e, collectionId) => Offline.isSafeId(collectionId) ? tracksOf(collectionId) : [])

    ipcMain.handle('offline-add', (_e, collection, tracks, s, opts) => {
      if (!owner || !collection || !Offline.isSafeId(collection.Id) || !Array.isArray(tracks) || !tracks.length) return false
      takeSession(s)
      Offline.addCollection(index, collection, tracks, Array.isArray(opts?.containers) ? opts.containers : [])
      // A picture subtitle burned in: asked for one movie or episode at a time.
      if (tracks.length === 1 && Number.isInteger(opts?.burnIn)) Offline.setBurnIn(index, tracks[0].Id, opts.burnIn)
      if (opts?.follow === true) Offline.setFollow(index, collection.Id, true, new Date())
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
      deleteOrphans(orphans)
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

    // ── Video ──
    ipcMain.handle('offline-video-profile', (_e, profile) => {
      // Only shape-checked: it goes to the server as the download's profile.
      if (!profile || typeof profile !== 'object' || !Array.isArray(profile.TranscodingProfiles) || JSON.stringify(profile).length > 20000) return
      videoProfile = profile
      if (owner && session) pump()
    })
    ipcMain.handle('offline-follow', (_e, seriesId, on) => {
      if (!owner || !Offline.isSafeId(seriesId)) return
      Offline.setFollow(index, seriesId, !!on, new Date())
      saveNow()
      emit({ type: 'changed' })
    })
    // New episodes of a followed series, found by the renderer while online.
    ipcMain.handle('offline-add-episodes', (_e, seriesId, items, s, containers) => {
      if (!owner || !Offline.isSafeId(seriesId) || !Array.isArray(items) || !items.length) return
      takeSession(s)
      Offline.addToCollection(index, seriesId, items)
      for (const c of Array.isArray(containers) ? containers : []) {
        if (c?.Type === 'Season' && Offline.isSafeId(c.Id) && !index.containers[c.Id]) index.containers[c.Id] = Offline.slimItem(c)
      }
      saveNow()
      emit({ type: 'changed' })
      pump()
    })
    ipcMain.handle('offline-watched', (_e, id) => {
      if (!owner || !Offline.isSafeId(id) || !index.tracks[id]) return
      Offline.markWatched(index, id, new Date())
      scheduleSave()
    })
    // "Remove watched episodes": the renderer asks when the setting is on.
    ipcMain.handle('offline-remove-watched', () => {
      if (!owner) return 0
      const ids = Offline.watchedToRemove(index, new Date())
      if (!ids.length) return 0
      deleteOrphans(Offline.removeTracks(index, ids))
      saveNow()
      emit({ type: 'changed' })
      return ids.length
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

    // ── Offline Mode ──
    // The catalog the renderer's query engine answers from, and what the
    // renderer learns online that the catalog keeps for later. Everything
    // arriving here is checked by the same rules as what is read from disk.
    ipcMain.handle('offline-catalog', () => owner ? index : null)
    ipcMain.handle('offline-set-libraries', (_e, views) => {
      if (!owner || !Array.isArray(views)) return
      Offline.setLibraries(index, views)
      scheduleSave()
    })
    ipcMain.handle('offline-set-user', (_e, user) => {
      if (!owner) return
      Offline.setUser(index, user)
      scheduleSave()
    })
    ipcMain.handle('offline-place', (_e, libraryId, items) => {
      if (!owner || typeof libraryId !== 'string' || !Array.isArray(items)) return
      const ids = items.map(i => i?.Id).filter(Offline.isSafeId)
      Offline.refreshItems(index, items.filter(i => Offline.isSafeId(i?.Id)))
      Offline.assignLibrary(index, ids, libraryId)
      scheduleSave()
      emit({ type: 'changed' })
    })
    ipcMain.handle('offline-set-lyrics', (_e, trackId, lyrics) => {
      if (!owner || !Offline.isSafeId(trackId) || !lyrics) return
      Offline.setLyrics(index, trackId, lyrics, new Date())
      scheduleSave()
    })
    ipcMain.handle('offline-disk', () => {
      try {
        const s = fs.statfsSync(root || app.getPath('userData'))
        return { free: s.bavail * s.bsize, total: s.blocks * s.bsize }
      } catch { return null }
    })
  }

  function flush() { try { if (saveTimer) saveNow() } catch {} }

  return { register, registerProtocol, flush }
}

module.exports = { createOffline }
