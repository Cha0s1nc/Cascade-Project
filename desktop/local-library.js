// Local mode, main process side (docs/local-mode-plan.md): folders on this
// computer used as the library, with no server. Each folder is its own
// library, as each folder added to Jellyfin can be. This file walks them,
// reads tags, keeps the scan and the person's own favorites, plays and
// playlists, and serves the files to the media elements. What decides an id,
// what a file is and what can play is pure, in src/core/local-scan.ts. No
// semicolons, like main.js.
//
// Layout under app.getPath('userData')/local:
//   index.json   the last scan (per file: mtime, size, first seen, tags), the
//                sidecars and .m3u playlists found; paths are relative, each
//                starting with its folder's key (Local.rootKeys), validated
//                when read
//   user.json    favorites, plays and positions by item id, and playlists made
//                in Cascade: apart, so a play does not rewrite the whole scan
//   art/<id>.jpg covers, posters and stills, from a picture file or the art
//                embedded in a song, made once and redone when the source changes
//
// The folders themselves are only ever read. Their paths live in the store
// under localLibraryRoots and are set only from the folder picker here, never
// by the renderer: every path served is resolved under its folder and checked
// for escape.

const fs = require('fs')
const path = require('path')
const { Readable } = require('stream')

// 2: paths start with their folder's key, for several folders.
const INDEX_VERSION = 2
const SAVE_DEBOUNCE_MS = 500
const PROGRESS_MS = 250
/** Files read for tags at once. Disks prefer few; network shares like more. */
const PARALLEL_READS = 4
/** A file that takes longer than this to read tags from is listed as unreadable. */
const READ_TIMEOUT_MS = 30000
/** Folders never worth walking into. */
const SKIP_DIRS = new Set(['node_modules', '$RECYCLE.BIN', 'System Volume Information', '@eaDir', '#recycle', 'lost+found'])
/** Deeper than any real library; stops a loop of hard-linked folders. */
const MAX_DEPTH = 40
/** Art is drawn at most this wide, as the downloads' art is fetched. */
const ART_WIDTH = 600

/**
 * @param {object} deps
 * @param {Electron.App} deps.app
 * @param {Electron.IpcMain} deps.ipcMain
 * @param {Electron.Protocol} deps.protocol
 * @param {Electron.Dialog} deps.dialog
 * @param {Electron.NativeImage} deps.nativeImage
 * @param {{ get: (k: string) => any, set: (k: string, v: any) => void, delete: (k: string) => void }} deps.store
 * @param {() => Electron.BrowserWindow | null} deps.getWindow
 * @param {typeof import('./src/core/local-scan')} deps.Local  build/local-scan.js
 * @param {typeof import('./src/core/offline-index')} deps.Offline  build/offline-index.js
 */
function createLocalLibrary({ app, ipcMain, protocol, dialog, nativeImage, store, getWindow, Local, Offline }) {
  const base = path.join(app.getPath('userData'), 'local')
  const artDir = path.join(base, 'art')
  const indexFile = path.join(base, 'index.json')
  const userFile = path.join(base, 'user.json')

  /** The library folders, in the order they were added: each as the person
   *  picked it (`path`), resolved with symlinks followed (`real`, what every
   *  served path is checked against, null while it cannot be opened), its key
   *  and its name. */
  let roots = []
  let state = emptyState()
  let loaded = false
  /** The catalog built from `state`, or null before the first build. */
  let catalog = null
  /** Bumped when a build comes out different, so the renderer fetches the
   *  catalog (a whole library) only when there is something new in it. */
  let version = 0
  let signature = ''
  /** Art on disk, by item id. */
  let art = new Set()
  /** The renderer's device profile: what this machine decodes. */
  let profile = null
  /** Bumped when the folder changes, so a scan of the old one stops. */
  let generation = 0
  let scanning = null
  let scanningGen = -1
  let progress = { done: 0, total: 0 }
  let lastScan = null
  let userSaveTimer = null
  /** music-metadata, loaded on first use: null if it is missing, which leaves
   *  the names to the folders. */
  let tagReader

  function emptyState() {
    return { version: INDEX_VERSION, roots: [], files: {}, sidecars: [], m3u: [], art: {}, userData: {}, playlists: [] }
  }

  // ── Index on disk ──────────────────────────────────────────────────────────

  /** Reads the stored scan, checked: anything can be in a file. */
  function parseState(raw) {
    const out = emptyState()
    if (!raw || typeof raw !== 'object' || raw.version !== INDEX_VERSION) return out
    if (Array.isArray(raw.roots)) out.roots = raw.roots.filter(p => typeof p === 'string')
    if (raw.files && typeof raw.files === 'object') {
      for (const [rel, f] of Object.entries(raw.files)) {
        if (!isSafeRel(rel) || !f || typeof f !== 'object') continue
        if (!Number.isFinite(f.mtimeMs) || !Number.isFinite(f.size) || !Number.isFinite(Date.parse(f.added))) continue
        out.files[rel] = { mtimeMs: f.mtimeMs, size: f.size, added: new Date(Date.parse(f.added)).toISOString(), probe: Local.parseProbe(f.probe) }
      }
    }
    if (Array.isArray(raw.sidecars)) out.sidecars = raw.sidecars.filter(isSafeRel)
    if (Array.isArray(raw.m3u)) {
      out.m3u = raw.m3u.filter(p => p && isSafeRel(p.rel) && Array.isArray(p.entries))
        .map(p => ({ rel: p.rel, entries: p.entries.filter(isSafeRel) }))
    }
    if (raw.art && typeof raw.art === 'object') {
      for (const [id, key] of Object.entries(raw.art)) if (Offline.isSafeId(id) && typeof key === 'string') out.art[id] = key
    }
    return out
  }

  function load() {
    if (loaded) return
    loaded = true
    fs.mkdirSync(artDir, { recursive: true })
    try { state = parseState(JSON.parse(fs.readFileSync(indexFile, 'utf8'))) } catch { state = emptyState() }
    try {
      const user = JSON.parse(fs.readFileSync(userFile, 'utf8'))
      state.userData = Local.parseUserData(user?.userData)
      state.playlists = Local.parseLocalPlaylists(user?.playlists)
    } catch {}
    for (const f of fs.readdirSync(artDir)) {
      if (f.endsWith('.partial')) fs.rmSync(path.join(artDir, f), { force: true })
    }
    art = new Set(fs.readdirSync(artDir).filter(f => /^[A-Za-z0-9]{1,64}\.jpg$/.test(f)).map(f => f.slice(0, -4)))
    for (const id of Object.keys(state.art)) if (!art.has(id)) delete state.art[id]
  }

  function writeAtomic(file, value) {
    const tmp = `${file}.tmp`
    fs.writeFileSync(tmp, JSON.stringify(value))
    fs.renameSync(tmp, file)
  }

  function saveScan() {
    if (!loaded) return
    const { userData: _u, playlists: _p, ...scanned } = state
    writeAtomic(indexFile, scanned)
  }

  function saveUser() {
    clearTimeout(userSaveTimer); userSaveTimer = null
    if (!loaded) return
    writeAtomic(userFile, { version: INDEX_VERSION, userData: state.userData, playlists: state.playlists })
  }

  function scheduleUserSave() {
    if (userSaveTimer) return
    userSaveTimer = setTimeout(() => { try { saveUser() } catch {} }, SAVE_DEBOUNCE_MS)
  }

  function emit(event) {
    const win = getWindow()
    if (win && !win.isDestroyed()) win.webContents.send('local-event', event)
  }

  // ── Paths ──────────────────────────────────────────────────────────────────

  /** A relative path with forward slashes that cannot climb out. */
  function isSafeRel(rel) {
    return typeof rel === 'string' && rel.length > 0 && rel.length < 4096 && !rel.startsWith('/') && !/^[A-Za-z]:/.test(rel)
      && !rel.split('/').some(s => s === '' || s === '.' || s === '..') && !rel.includes('\\') && !rel.includes('\0')
  }

  const within = (dir, p) => p === dir || p.startsWith(dir + path.sep)

  /** The file a relative path names, resolved, or null if it is outside its
   *  folder by any route (a symlink swapped in since the scan included). */
  async function resolveRel(rel) {
    if (!isSafeRel(rel)) return null
    const i = rel.indexOf('/')
    const r = i > 0 ? roots.find(x => x.key === rel.slice(0, i)) : null
    if (!r || !r.real) return null
    const abs = path.normalize(path.join(r.path, ...rel.slice(i + 1).split('/')))
    if (!within(r.path, abs)) return null
    try {
      const real = await fs.promises.realpath(abs)
      return within(r.real, real) ? real : null
    } catch { return null }
  }

  async function setRoots(paths) {
    generation++
    const keys = Local.rootKeys(paths)
    roots = paths.map((p, i) => ({ path: p, real: null, key: keys[i], name: Local.folderName(p) }))
    for (const r of roots) {
      try { r.real = await fs.promises.realpath(r.path) } catch {}
    }
  }

  /** The folders as the store has them. One folder was a string before
   *  several were possible. */
  function storedRoots() {
    const list = store.get('localLibraryRoots')
    if (Array.isArray(list)) return list.filter(p => typeof p === 'string' && p)
    const one = store.get('localLibraryRoot')
    return typeof one === 'string' && one ? [one] : []
  }

  function storeRoots(paths) {
    store.set('localLibraryRoots', paths)
    store.delete('localLibraryRoot')
  }

  // ── Scanning ───────────────────────────────────────────────────────────────

  /** Every media file and sidecar under one folder, with stat for the media,
   *  each path starting with the folder's key. Dot-files, the skip list and
   *  links leading out of the folder are left alone; a folder reached twice
   *  (a link back inside) is walked once. */
  async function walk(gen, r) {
    const realRoot = r.real
    const media = []
    const sidecars = []
    const seen = new Set()
    const visit = async (dirAbs, relDir, depth) => {
      if (depth > MAX_DEPTH || gen !== generation) return
      let real
      try { real = await fs.promises.realpath(dirAbs) } catch { return }
      if (!within(realRoot, real) || seen.has(real)) return
      seen.add(real)
      let entries
      try { entries = await fs.promises.readdir(dirAbs, { withFileTypes: true }) } catch { return }
      entries.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
      const files = []
      for (const e of entries) {
        if (e.name.startsWith('.') || SKIP_DIRS.has(e.name)) continue
        const abs = path.join(dirAbs, e.name)
        const rel = `${relDir}/${e.name}`
        if (!isSafeRel(rel)) continue
        let isDir = e.isDirectory(), isFile = e.isFile()
        if (e.isSymbolicLink()) {
          // Followed only while it stays inside the folder.
          let target
          try { target = await fs.promises.realpath(abs) } catch { continue }
          if (!within(realRoot, target)) continue
          try { const st = await fs.promises.stat(abs); isDir = st.isDirectory(); isFile = st.isFile() } catch { continue }
        }
        if (isDir) await visit(abs, rel, depth + 1)
        else if (isFile && Local.kindByExtension(rel)) files.push({ rel, abs })
        else if (isFile && Local.isSidecar(rel)) sidecars.push(rel)
      }
      await Promise.all(files.map(async f => {
        try {
          const st = await fs.promises.stat(f.abs)
          media.push({ rel: f.rel, abs: f.abs, mtimeMs: st.mtimeMs, size: st.size, birthtimeMs: st.birthtimeMs })
        } catch {}
      }))
    }
    await visit(r.path, r.key, 0)
    return { media, sidecars }
  }

  async function loadTagReader() {
    if (tagReader !== undefined) return tagReader
    try { tagReader = await import('music-metadata') } catch (e) {
      console.warn('[cascade] music-metadata is not available, Local mode names files by their folders:', e?.message || e)
      tagReader = null
    }
    return tagReader
  }

  /** One file's tags and streams, or null when they cannot be read. */
  async function probe(abs) {
    const mm = await loadTagReader()
    if (!mm) return null
    let timer
    try {
      // Covers are read, not skipped: skipCovers drops every trace of them,
      // and whether one is there is what lets an album without a cover file
      // have art. The picture itself is let go here and read again once.
      const meta = await Promise.race([
        mm.parseFile(abs, { duration: true, skipCovers: false }),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('timed out')), READ_TIMEOUT_MS) }),
      ])
      return Local.probeFromMetadata(meta)
    } catch { return null } finally { clearTimeout(timer) }
  }

  /** Runs a scan, unless one of this folder is running: then that one is the
   *  answer. One of a folder since replaced finishes (it stops early) first. */
  function scan() {
    if (scanning && scanningGen === generation) return scanning
    const prev = scanning
    scanningGen = generation
    const run = (async () => {
      if (prev) await prev
      try { await runScan() } catch (e) { console.error('[cascade] local library scan failed:', e) }
    })()
    scanning = run
    run.finally(() => {
      if (scanning === run) scanning = null
      emit({ type: 'changed', version, reason: 'scan' })
    })
    return run
  }

  async function runScan() {
    const gen = generation
    if (!roots.length) return
    progress = { done: 0, total: 0 }
    emit({ type: 'progress', ...progress })
    const media = []
    const sidecars = []
    // A folder that cannot be opened (a drive not plugged in) keeps what the
    // last scan found in it, as one folder alone always did.
    const kept = new Set()
    for (const r of roots) {
      try { r.real = await fs.promises.realpath(r.path) } catch { r.real = null }
      if (!r.real) { kept.add(r.key); continue }
      const found = await walk(gen, r)
      if (gen !== generation) return
      media.push(...found.media)
      sidecars.push(...found.sidecars)
    }
    const keyOf = (rel) => rel.slice(0, rel.indexOf('/'))

    // Only what changed is read again: same mtime and size means same tags.
    const files = {}
    for (const [rel, f] of Object.entries(state.files)) if (kept.has(keyOf(rel))) files[rel] = f
    sidecars.push(...state.sidecars.filter(rel => kept.has(keyOf(rel))))
    const toRead = []
    for (const m of media) {
      const old = state.files[m.rel]
      if (old && old.mtimeMs === m.mtimeMs && old.size === m.size) files[m.rel] = old
      else {
        const first = old?.added ?? new Date(Math.min(Date.now(), m.birthtimeMs > 0 ? m.birthtimeMs : m.mtimeMs)).toISOString()
        files[m.rel] = { mtimeMs: m.mtimeMs, size: m.size, added: first, probe: null }
        toRead.push(m)
      }
    }
    progress = { done: 0, total: toRead.length }
    let lastEmit = 0
    const queue = [...toRead]
    await Promise.all(Array.from({ length: PARALLEL_READS }, async () => {
      while (queue.length && gen === generation) {
        const m = queue.shift()
        files[m.rel].probe = await probe(m.abs)
        progress.done++
        const now = Date.now()
        if (now - lastEmit >= PROGRESS_MS) { lastEmit = now; emit({ type: 'progress', ...progress }) }
      }
    }))
    if (gen !== generation) return

    const m3u = state.m3u.filter(p => kept.has(keyOf(p.rel)))
    for (const rel of sidecars.filter(r => /\.m3u8?$/i.test(r) && !kept.has(keyOf(r)))) {
      const abs = await resolveRel(rel)
      const r = roots.find(x => x.key === keyOf(rel))
      if (!abs || !r) continue
      try {
        const st = await fs.promises.stat(abs)
        if (st.size > 4 * 1024 * 1024) continue
        // Read inside its own folder, then given the folder's key.
        const entries = Local.parseM3u(readText(await fs.promises.readFile(abs)), rel.slice(r.key.length + 1), r.path)
        m3u.push({ rel, entries: entries.map(e => `${r.key}/${e}`) })
      } catch {}
    }
    if (gen !== generation) return
    state.roots = roots.map(r => r.path)
    state.files = files
    state.sidecars = sidecars
    state.m3u = m3u
    lastScan = new Date().toISOString()
    await rebuild(gen)
    saveScan()
  }

  /** Text from a file someone made by hand: UTF-8 (with or without BOM, or
   *  UTF-16 with one), else Windows-1252, which is what an old .srt or .m3u
   *  usually is. */
  function readText(buf) {
    if (buf[0] === 0xff && buf[1] === 0xfe) return new TextDecoder('utf-16le').decode(buf.subarray(2))
    if (buf[0] === 0xfe && buf[1] === 0xff) return new TextDecoder('utf-16be').decode(buf.subarray(2))
    try { return new TextDecoder('utf-8', { fatal: true }).decode(buf).replace(/^﻿/, '') } catch {}
    try { return new TextDecoder('windows-1252').decode(buf) } catch { return buf.toString('latin1') }
  }

  // ── The catalog ────────────────────────────────────────────────────────────

  function build() {
    return Local.buildCatalog({
      files: Object.entries(state.files).map(([rel, f]) => ({ rel, size: f.size, added: f.added, probe: f.probe })),
      sidecars: state.sidecars,
      m3u: state.m3u,
      playlists: state.playlists,
      userData: state.userData,
      art,
      profile,
      roots: roots.map(r => ({ key: r.key, name: r.name })),
    })
  }

  /** Builds the catalog, makes the art it is missing, and builds it again
   *  with that art if any was made. */
  async function rebuild(gen = generation) {
    setCatalog(build())
    if (await makeArt(gen) && gen === generation) setCatalog(build())
  }

  function setCatalog(next) {
    catalog = next
    const sig = require('crypto').createHash('sha1').update(JSON.stringify(next.index)).update(JSON.stringify(next.unplayable)).digest('hex')
    if (sig !== signature) { signature = sig; version++ }
  }

  /** The key that says whether stored art is still the source's. */
  function artKey(source) {
    const rel = source.file ?? source.embedded
    const f = state.files[rel]
    return `${source.file ? 'file' : 'embedded'}:${rel}:${f ? f.mtimeMs : ''}`
  }

  /** Art for every item that has a source and no up-to-date picture, and
   *  none for items that have lost theirs. True when anything changed. */
  async function makeArt(gen) {
    let changed = false
    const sources = catalog.artSources
    for (const id of [...art]) {
      if (sources[id]) continue
      fs.rmSync(path.join(artDir, `${id}.jpg`), { force: true })
      art.delete(id)
      delete state.art[id]
      changed = true
    }
    for (const [id, source] of Object.entries(sources)) {
      if (gen !== generation) return changed
      if (!Offline.isSafeId(id)) continue
      const key = source.file ? `${artKey(source)}:${await mtimeOf(source.file)}` : artKey(source)
      if (art.has(id) && state.art[id] === key) continue
      const bytes = source.file ? await readArtFile(source.file) : await readEmbeddedArt(source.embedded)
      if (gen !== generation) return changed
      if (!bytes) continue
      const partial = path.join(artDir, `${id}.partial`)
      try {
        fs.writeFileSync(partial, bytes)
        fs.renameSync(partial, path.join(artDir, `${id}.jpg`))
        art.add(id)
        state.art[id] = key
        changed = true
      } catch { fs.rmSync(partial, { force: true }) }
    }
    return changed
  }

  async function mtimeOf(rel) {
    const abs = await resolveRel(rel)
    if (!abs) return ''
    try { return String((await fs.promises.stat(abs)).mtimeMs) } catch { return '' }
  }

  /** A picture as a JPEG at most ART_WIDTH wide, or as it was when it cannot
   *  be decoded here (it is still served with its own type). */
  function toArt(buf) {
    try {
      const img = nativeImage.createFromBuffer(buf)
      if (img.isEmpty()) return buf
      const { width } = img.getSize()
      return (width > ART_WIDTH ? img.resize({ width: ART_WIDTH, quality: 'best' }) : img).toJPEG(90)
    } catch { return buf }
  }

  async function readArtFile(rel) {
    const abs = await resolveRel(rel)
    if (!abs) return null
    try {
      const st = await fs.promises.stat(abs)
      if (st.size > 30 * 1024 * 1024) return null
      return toArt(await fs.promises.readFile(abs))
    } catch { return null }
  }

  async function readEmbeddedArt(rel) {
    const abs = await resolveRel(rel)
    const mm = await loadTagReader()
    if (!abs || !mm) return null
    try {
      const meta = await mm.parseFile(abs, { duration: false, skipCovers: false })
      const pic = mm.selectCover ? mm.selectCover(meta.common.picture) : meta.common.picture?.[0]
      return pic?.data ? toArt(Buffer.from(pic.data)) : null
    } catch { return null }
  }

  // ── What the renderer reads ────────────────────────────────────────────────

  const urlFor = (file) => `cascade-local://local/${file}`

  /** The same shape as the downloads' summary (offline.js), so playback,
   *  art and subtitles read it unchanged, plus the folder's own state. */
  function summary() {
    const ready = {}
    const subs = {}
    if (catalog) {
      for (const [id, t] of Object.entries(catalog.index.tracks)) {
        if (!t.file) continue
        ready[id] = urlFor(t.file)
        if (t.subs) subs[id] = t.subs.map(x => ({ ...x, url: urlFor(x.file) }))
      }
    }
    const count = (type) => catalog ? Object.values(catalog.index.tracks).filter(t => t.item.Type === type).length : 0
    return {
      ready,
      subs,
      art: [...art],
      artBase: 'cascade-local://local/art/',
      collections: [],
      totalBytes: 0,
      active: [],
      failed: {},
      plays: 0,
      playsHeld: false,
      changes: 0,
      limitBytes: null,
      local: {
        version,
        root: roots[0]?.path ?? null,
        roots: roots.map(r => ({ path: r.path, name: r.name, missing: !r.real })),
        scanning: !!scanning,
        progress,
        lastScan,
        error: roots.some(r => !r.real) ? 'missing' : null,
        tagsReadable: tagReader !== null,
        counts: { songs: count('Audio'), movies: count('Movie'), episodes: count('Episode') },
        unplayable: catalog ? catalog.unplayable : [],
      },
    }
  }

  // ── Serving files: a custom protocol, never file:// ────────────────────────

  /**
   * Plays a library file, its subtitles and its art. Only what the catalog
   * lists, by id, resolved under the folder and checked for escape after
   * links are followed. Ranges are answered here, with a real 206: leaving
   * them to net.fetch made seeking silently fail in Offline Mode. The CORS
   * header is what lets the Web Audio graph read the element.
   */
  function registerProtocol() {
    protocol.handle('cascade-local', async (req) => {
      let url, rel
      try {
        url = new URL(req.url)
        rel = decodeURIComponent(url.pathname).replace(/^\/+/, '')
      } catch { return notFound() }
      if (url.host !== 'local' || !catalog) return notFound()
      const headers = { 'access-control-allow-origin': '*' }

      let m = /^art\/([A-Za-z0-9]{1,64})\.jpg$/.exec(rel)
      if (m) {
        if (!art.has(m[1])) return notFound()
        try {
          const body = await fs.promises.readFile(path.join(artDir, `${m[1]}.jpg`))
          return new Response(body, { status: 200, headers: { ...headers, 'content-type': sniffImage(body) } })
        } catch { return notFound() }
      }

      m = /^subs\/([A-Za-z0-9]{1,64})\.(\d{1,4})\.vtt$/.exec(rel)
      if (m) {
        const sub = (catalog.subs[m[1]] || []).find(s => s.index === Number(m[2]))
        const abs = sub && await resolveRel(sub.rel)
        if (!abs) return notFound()
        try {
          const text = readText(await fs.promises.readFile(abs))
          const vtt = /\.srt$/i.test(sub.rel) ? Local.srtToVtt(text) : text
          return new Response(vtt, { status: 200, headers: { ...headers, 'content-type': 'text/vtt; charset=utf-8' } })
        } catch { return notFound() }
      }

      m = /^media\/([A-Za-z0-9]{1,64})\.[A-Za-z0-9]{1,8}$/.exec(rel)
      const fileRel = m && catalog.paths[m[1]]
      const abs = fileRel && await resolveRel(fileRel)
      if (!abs) return notFound()
      let size
      try { size = (await fs.promises.stat(abs)).size } catch { return notFound() }
      Object.assign(headers, { 'content-type': Offline.contentTypeForFile(fileRel), 'accept-ranges': 'bytes' })
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

  const notFound = () => new Response('Not found', { status: 404 })

  function sniffImage(buf) {
    if (buf[0] === 0x89 && buf[1] === 0x50) return 'image/png'
    if (buf.subarray(0, 4).toString('latin1') === 'RIFF' && buf.subarray(8, 12).toString('latin1') === 'WEBP') return 'image/webp'
    return 'image/jpeg'
  }

  // ── Lyrics ─────────────────────────────────────────────────────────────────

  /** A song's own lyrics: the .lrc beside it, else the ones embedded in its
   *  tags (SYLT synced, USLT and friends plain). `{ text, synced }` or null. */
  async function lyricsFor(id) {
    if (!catalog || !Offline.isSafeId(id) || !catalog.paths[id]) return null
    const sidecar = catalog.lyrics[id]
    if (sidecar) {
      const abs = await resolveRel(sidecar)
      if (abs) {
        try {
          const text = readText(await fs.promises.readFile(abs)).replace(/\r\n?/g, '\n')
          if (text.trim()) return { text, synced: /^\[\d+:\d+(?:\.\d+)?\]/m.test(text) }
        } catch {}
      }
    }
    const abs = await resolveRel(catalog.paths[id])
    const mm = await loadTagReader()
    if (!abs || !mm) return null
    try {
      const meta = await mm.parseFile(abs, { duration: false, skipCovers: true })
      for (const l of meta.common.lyrics || []) {
        // SYLT in milliseconds (timeStampFormat 2) becomes LRC; MPEG frames cannot be placed.
        if (Array.isArray(l?.syncText) && l.syncText.length && l.timeStampFormat !== 1) {
          const lrc = l.syncText.filter(s => Number.isFinite(s.timestamp) && typeof s.text === 'string')
            .map(s => `[${lrcTime(s.timestamp)}]${s.text.replace(/[\r\n]+/g, ' ')}`).join('\n')
          if (lrc) return { text: lrc, synced: true }
        }
        const text = typeof l === 'string' ? l : l?.text
        if (typeof text === 'string' && text.trim()) {
          const plain = text.replace(/\r\n?/g, '\n')
          return { text: plain, synced: /^\[\d+:\d+(?:\.\d+)?\]/m.test(plain) }
        }
      }
    } catch {}
    return null
  }

  const lrcTime = (ms) => {
    const m = Math.floor(ms / 60000)
    const s = ((ms % 60000) / 1000).toFixed(2).padStart(5, '0')
    return `${String(m).padStart(2, '0')}:${s}`
  }

  // ── Playlists made in Cascade ──────────────────────────────────────────────

  const newPlaylistId = () => require('crypto').randomUUID().replace(/-/g, '')

  /** Every playlist operation the renderer can ask for (local-writes.ts
   *  playlistOpFor), checked again here: IPC input is not trusted. A playlist
   *  from an .m3u file is the file's: Cascade never writes into the folder. */
  function playlistOp(op) {
    if (!op || typeof op !== 'object') return { ok: false }
    const ids = (v) => Array.isArray(v) ? v.filter(Offline.isSafeId).slice(0, Local.MAX_PLAYLIST_ENTRIES) : []
    const name = typeof op.name === 'string' ? op.name.trim().slice(0, 200) : ''
    if (op.kind === 'create') {
      if (!name) return { ok: false }
      const p = { Id: newPlaylistId(), Name: name, trackIds: ids(op.ids), createdAt: new Date().toISOString() }
      state.playlists.push(p)
      return { ok: true, id: p.Id }
    }
    const p = state.playlists.find(x => x.Id === op.id)
    if (!p) return { ok: false, readOnly: !!catalog?.index.collections.some(c => c.item.Id === op.id) }
    switch (op.kind) {
      case 'add': case 'removeIds':
        p.trackIds = Local.applyPlaylistOp(p.trackIds, { kind: op.kind, id: p.Id, ids: ids(op.ids) }, Local.MAX_PLAYLIST_ENTRIES)
        break
      // A rename alone sends no ids, and must leave the entries as they are.
      case 'set':
        if (Array.isArray(op.ids)) p.trackIds = ids(op.ids)
        break
      case 'move':
        if (!Offline.isSafeId(op.entryId) || !Number.isInteger(op.to) || op.to < 0) return { ok: false }
        p.trackIds = Local.applyPlaylistOp(p.trackIds, { kind: 'move', id: p.Id, entryId: op.entryId, to: op.to }, Local.MAX_PLAYLIST_ENTRIES)
        break
      case 'delete': state.playlists = state.playlists.filter(x => x !== p); break
      default: return { ok: false }
    }
    if (op.kind === 'set' && name) p.Name = name
    return { ok: true, id: p.Id }
  }

  // ── IPC ────────────────────────────────────────────────────────────────────

  async function start(newProfile) {
    load()
    takeProfile(newProfile)
    const wanted = storedRoots()
    if (JSON.stringify(wanted) !== JSON.stringify(roots.map(r => r.path))) {
      await setRoots(wanted)
      // What the last scan found in a folder no longer listed goes; the rest
      // is kept, so adding a folder reads only the new one. Favorites and
      // playlists stay: an id is a folder's key and a path inside it.
      const keys = new Set(roots.map(r => r.key))
      const keep = (rel) => keys.has(rel.slice(0, rel.indexOf('/')))
      state.files = Object.fromEntries(Object.entries(state.files).filter(([rel]) => keep(rel)))
      state.sidecars = state.sidecars.filter(keep)
      state.m3u = state.m3u.filter(p => keep(p.rel))
      state.roots = roots.map(r => r.path)
      catalog = null
    }
    if (!catalog) setCatalog(build())
    if (roots.length) scan()
    return summary()
  }

  /** The folder picker. A folder, or why not. */
  async function pickFolder(sender, title) {
    const { BrowserWindow } = require('electron')
    const owner = BrowserWindow.fromWebContents(sender)
    const { canceled, filePaths } = await dialog.showOpenDialog(owner || undefined, {
      title, properties: ['openDirectory'], defaultPath: roots[0]?.path || app.getPath('music'),
    })
    if (canceled || !filePaths?.[0]) return { ok: false, canceled: true }
    try {
      if (!(await fs.promises.stat(filePaths[0])).isDirectory()) return { ok: false, error: 'That is not a folder.' }
    } catch { return { ok: false, error: 'Cascade cannot open that folder.' } }
    return { ok: true, path: filePaths[0] }
  }

  function takeProfile(p) {
    // Only shape-checked: it decides what is listed, and goes nowhere.
    if (p && typeof p === 'object' && Array.isArray(p.DirectPlayProfiles) && JSON.stringify(p).length < 20000) profile = p
  }

  function register() {
    ipcMain.handle('local-start', (_e, p) => start(p))
    ipcMain.handle('local-summary', () => summary())
    ipcMain.handle('local-catalog', () => catalog ? catalog.index : null)
    ipcMain.handle('local-rescan', () => { if (roots.length) scan(); return summary() })
    // The first folder, from setup or "Use a folder": the library becomes it alone.
    ipcMain.handle('local-choose-folder', async (e) => {
      const picked = await pickFolder(e.sender, 'Choose your library folder')
      if (!picked.ok) return picked
      storeRoots([picked.path])
      return { ok: true, root: picked.path }
    })
    // Another folder, as another library. A folder inside one already listed,
    // or holding one, would list the same files twice.
    ipcMain.handle('local-add-folder', async (e) => {
      const picked = await pickFolder(e.sender, 'Add a library folder')
      if (!picked.ok) return picked
      const next = path.resolve(picked.path)
      const current = storedRoots()
      for (const p of current.map(x => path.resolve(x))) {
        if (p === next) return { ok: false, error: 'That folder is already in your library.' }
        if (within(p, next)) return { ok: false, error: `That folder is inside one already in your library:\n\n${p}` }
        if (within(next, p)) return { ok: false, error: `That folder holds one already in your library:\n\n${p}\n\nRemove that one first to use this instead.` }
      }
      storeRoots([...current, picked.path])
      return { ok: true, root: picked.path }
    })
    ipcMain.handle('local-remove-folder', (_e, p) => {
      const current = storedRoots()
      if (typeof p !== 'string' || !current.includes(p) || current.length < 2) return { ok: false }
      storeRoots(current.filter(x => x !== p))
      return { ok: true }
    })
    ipcMain.handle('local-set-profile', async (_e, p) => {
      const before = JSON.stringify(profile)
      takeProfile(p)
      if (catalog && JSON.stringify(profile) !== before) { await rebuild(); emit({ type: 'changed', version, reason: 'profile' }) }
    })
    // A favorite, a play, a position or a played mark. Answers the item's
    // user data as kept, which the renderer writes into its own copy.
    ipcMain.handle('local-change', (_e, itemId, change) => {
      const c = Local.parseLocalChange(change)
      if (!catalog || !Offline.isSafeId(itemId) || !c) return null
      const ud = Local.applyLocalChange(state.userData[itemId], c, new Date())
      state.userData[itemId] = ud
      Local.setLocalUserData(catalog.index, itemId, ud)
      scheduleUserSave()
      return ud
    })
    ipcMain.handle('local-playlist', async (_e, op) => {
      if (!catalog) return { ok: false }
      const result = playlistOp(op)
      if (!result.ok) return result
      saveUser()
      setCatalog(build())
      // The renderer that asked fetches the new catalog itself.
      emit({ type: 'changed', version, reason: 'playlist' })
      return result
    })
    ipcMain.handle('local-lyrics', (_e, id) => lyricsFor(id))
  }

  function flush() { try { if (userSaveTimer) saveUser() } catch {} }

  return { register, registerProtocol, flush }
}

module.exports = { createLocalLibrary }
