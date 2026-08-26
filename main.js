const { app, BrowserWindow, ipcMain, clipboard, shell, Menu, globalShortcut, TouchBar } = require('electron')
const { TouchBarButton, TouchBarSpacer, TouchBarLabel } = TouchBar
const path = require('path')
const https = require('https')
const http  = require('http')
const fs    = require('fs')
const os    = require('os')
const crypto = require('crypto')
const Store = require('electron-store')

// ── Discord RPC ────────────────────────────────────────────────────────────────
let rpcClient   = null
let rpcReady    = false
let rpcUpdateTimer = null
let lastRpcActivity = null

// Discord activity type: 2 = Listening, 3 = Watching. Held here rather than on
// the activity object because setActivity() rebuilds that object from a fixed
// field list and drops anything it does not recognise - see the request() patch
// in connectDiscordRpc().
const RPC_TYPE_LISTENING = 2
const RPC_TYPE_WATCHING  = 3
let rpcActivityType = RPC_TYPE_LISTENING

async function connectDiscordRpc(clientId) {
  if (!clientId) return
  try {
    const { Client } = require('discord-rpc')
    rpcClient = new Client({ transport: 'ipc' })
    rpcClient.on('ready', () => {
      rpcReady = true
      // Patch request() to inject the activity type into every SET_ACTIVITY call.
      // setActivity() strips the type field, so we add it back at the protocol
      // level - which is also why the renderer's choice arrives via
      // rpcActivityType rather than on the activity object itself.
      const _origRequest = rpcClient.request.bind(rpcClient)
      rpcClient.request = function(cmd, args, ...rest) {
        if (cmd === 'SET_ACTIVITY' && args?.activity) {
          args.activity.type = rpcActivityType
          args.activity.status_display_type = 1  // show state (artist/series) in member list sidebar
        }
        return _origRequest(cmd, args, ...rest).catch(() => { /* Discord rate limit or transient error - suppress */ })
      }
      if (win && !win.isDestroyed()) win.webContents.send('discord-rpc-status', true)
    })
    rpcClient.on('disconnected', () => {
      rpcReady = false
      rpcClient = null
      if (win && !win.isDestroyed()) win.webContents.send('discord-rpc-status', false)
    })
    await rpcClient.login({ clientId })
  } catch (e) {
    console.warn('[discord-rpc] connect failed:', e.message)
    rpcClient = null
    rpcReady  = false
  }
}

function destroyRpc() {
  if (rpcClient) { try { rpcClient.destroy() } catch {} rpcClient = null; rpcReady = false }
}

ipcMain.on('discord-rpc-connect', async (_e, clientId) => {
  destroyRpc()
  if (clientId) await connectDiscordRpc(clientId)
})

ipcMain.on('discord-rpc-update', (_e, activity) => {
  if (!rpcClient || !rpcReady) return
  // `watching` rides along on the activity; setActivity() would drop it, so it
  // is lifted out here and applied by the request() patch instead.
  rpcActivityType = activity?.watching ? RPC_TYPE_WATCHING : RPC_TYPE_LISTENING
  lastRpcActivity = activity
  if (rpcUpdateTimer) return  // already scheduled
  rpcUpdateTimer = setTimeout(() => {
    rpcUpdateTimer = null
    if (!rpcClient || !rpcReady) return
    try {
      if (lastRpcActivity) rpcClient.setActivity(lastRpcActivity)
      else rpcClient.clearActivity()
    } catch {}
  }, 5000)  // max one update per 5 seconds
})

ipcMain.on('discord-rpc-clear', () => {
  // Drop the pending update as well as the live one. The throttle holds the
  // last activity to send when its timer fires, so clearing on its own left a
  // scheduled update to put the presence straight back up to five seconds
  // later, with nothing to clear it again. That is how a paused track stayed
  // on your profile indefinitely. Cleared before the connection check so the
  // state is right even when there is nothing connected to tell.
  lastRpcActivity = null
  if (rpcUpdateTimer) { clearTimeout(rpcUpdateTimer); rpcUpdateTimer = null }
  if (!rpcClient || !rpcReady) return
  try { rpcClient.clearActivity() } catch {}
})

// ── Cascade Control Server (for Cha0s Stream integration) ─────────────────────
// Listens on 127.0.0.1:47847 - Cha0s Stream POSTs here instead of using OS media keys.
// Loopback-only, but any webpage open in a browser on this machine can also reach a
// loopback port - so requests must carry the shared token below. The token lives in
// a dotfile in the home dir rather than app config, so any local app (Stream included)
// can find it without a manual pairing step; a browser page has no way to read it.
const CONTROL_TOKEN_PATH = path.join(os.homedir(), '.cascade-control-token')
function getOrCreateControlToken() {
  try {
    const existing = fs.readFileSync(CONTROL_TOKEN_PATH, 'utf8').trim()
    if (/^[0-9a-f]{64}$/.test(existing)) return existing
  } catch {}
  const token = crypto.randomBytes(32).toString('hex')
  try { fs.writeFileSync(CONTROL_TOKEN_PATH, token, { mode: 0o600 }) } catch {}
  return token
}
const controlToken = getOrCreateControlToken()
const CONTROL_ACTIONS = new Set(['playpause', 'next', 'prev'])

const controlServer = http.createServer((req, res) => {
  if (req.headers['x-cascade-token'] !== controlToken) {
    res.writeHead(401, { 'Content-Type': 'application/json' })
    return res.end(JSON.stringify({ ok: false, error: 'Unauthorized' }))
  }
  if (req.method === 'POST' && req.url === '/cascade/control') {
    let body = ''
    req.on('data', chunk => { body += chunk })
    req.on('end', () => {
      try {
        const { action } = JSON.parse(body)
        if (!CONTROL_ACTIONS.has(action)) throw new Error('bad action')
        if (win && !win.isDestroyed()) win.webContents.send('media-key', action)
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
      } catch {
        res.writeHead(400, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ ok: false, error: 'Bad request' }))
      }
    })
  } else if (req.method === 'GET' && req.url === '/cascade/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ ok: true, app: 'Cascade', version: app.getVersion() }))
  } else if (req.method === 'GET' && req.url === '/cascade/now-playing') {
    // cascadeNowPlaying is kept fresh by the renderer's 'now-playing-update' IPC
    // messages (sent on track change/play/pause), so just serve the cache instead
    // of running executeJavaScript in the renderer on every poll.
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(cascadeNowPlaying))
  } else {
    res.writeHead(404); res.end()
  }
})
controlServer.listen(47847, '127.0.0.1', () => {
  console.log('[cascade] Control server listening on 127.0.0.1:47847')
})
controlServer.on('error', (err) => {
  console.warn('[cascade] Control server error:', err.message)
})

const GITHUB_REPO = 'Cha0s1nc/Cascade-Project'

const store = new Store()

// The app's own .titlebar strip is 38px (index.html) - the Window Controls
// Overlay height below must match it or the OS-drawn buttons sit off-centre.
const TITLEBAR_HEIGHT = 38

// Windows/Linux caption buttons drawn by the OS via titleBarOverlay, coloured
// to match whichever theme is active so they stay readable in both. macOS
// ignores this entirely - its traffic lights are drawn by the OS itself and
// take their colour from nowhere we control.
// Matches --surface/--text from index.html's :root and light theme block.
function titleBarOverlayColors(mode) {
  return mode === 'light'
    ? { color: '#ffffff', symbolColor: '#1c1c1e' }
    : { color: '#1c1c1e', symbolColor: '#f5f5f7' }
}

function storedThemeMode() {
  try {
    const raw = store.get('theme')
    if (raw && JSON.parse(String(raw)).mode === 'light') return 'light'
  } catch {
    // Corrupt/missing store value - fall back to dark, same as the renderer does.
  }
  return 'dark'
}

let win
let updaterWindow     = null
let lyricsEditorWindow = null
let pendingDownload   = null

function createWindow() {
  const isDarwin = process.platform === 'darwin'
  win = new BrowserWindow({
    width: 1100,
    height: 700,
    minWidth: 800,
    // 560, not 500: the video overlay stacks a picture, a title, two button
    // rows, a scrubber and a volume slider into one column, and 500 was under
    // what that needs - the picture was the part that got squeezed out.
    minHeight: 560,
    backgroundColor: '#111113',
    // hiddenInset + trafficLightPosition is macOS-only and is silently ignored
    // elsewhere, which used to leave Windows/Linux with the OS title bar AND
    // the app's own 38px .titlebar stacked on top of each other. 'hidden' +
    // titleBarOverlay (Electron 29, win32/linux) draws real OS caption buttons
    // inside the app's own titlebar strip instead - index.html reserves space
    // for them with padding-right.
    titleBarStyle: isDarwin ? 'hiddenInset' : 'hidden',
    ...(isDarwin
      ? { trafficLightPosition: { x: 12, y: 11 } }
      : { titleBarOverlay: { ...titleBarOverlayColors(storedThemeMode()), height: TITLEBAR_HEIGHT } }),
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'build', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      // Chromium suspends requestAnimationFrame while minimized/occluded, so a track
      // that changes then never gets its marquee measured.
      // ponytail: costs a little idle CPU; drop it if battery drain shows up.
      backgroundThrottling: false,
    },
    show: false,
  })
  // macOS always renders an app menu, so passing null does not remove it, it
  // leaves a stub with nothing bound to it - which is why Reload, the zoom
  // items and Toggle Developer Tools all grey out. It costs the Edit menu too,
  // and on macOS that menu is what makes Cmd+C/V/X/A work inside a text field
  // at all, so without it you cannot paste a server URL or a password.
  // Elsewhere a null menu really does mean no menu bar, which is what we want.
  if (process.platform === 'darwin') {
    Menu.setApplicationMenu(Menu.buildFromTemplate([
      { role: 'appMenu' },
      { role: 'editMenu' },
      { role: 'viewMenu' },
      { role: 'windowMenu' },
    ]))
  } else {
    Menu.setApplicationMenu(null)
  }

  win.loadFile('index.html')

  // ── Touch Bar (macOS only) ────────────────────────────────────────────────
  if (process.platform === 'darwin') {
    const send = (key) => { if (win && !win.isDestroyed()) win.webContents.send('media-key', key) }

    const tbTrack = new TouchBarLabel({ label: 'Cascade', textColor: '#ffffff' })
    const tbPrev  = new TouchBarButton({ label: '⏮', click: () => send('prev') })
    const tbPlay  = new TouchBarButton({ label: '⏸', click: () => send('playpause') })
    const tbNext  = new TouchBarButton({ label: '⏭', click: () => send('next') })

    win.setTouchBar(new TouchBar({
      items: [
        tbTrack,
        new TouchBarSpacer({ size: 'flexible' }),
        tbPrev, tbPlay, tbNext,
        new TouchBarSpacer({ size: 'small' }),
      ]
    }))

    // Keep play/pause icon and track label in sync via IPC
    ipcMain.on('touchbar-update', (_e, { playing, title }) => {
      if (title != null) tbTrack.label = title
      if (playing != null) tbPlay.label = playing ? '⏸' : '▶'
    })
  } else {
    // No-op handler so the renderer's touchbarUpdate() call doesn't error on Windows/Linux
    ipcMain.on('touchbar-update', () => {})
  }

  win.once('ready-to-show', () => {
    win.show()
    if (app.isPackaged) setTimeout(checkForUpdates, 5000)

    // Register OS media keys here - app is already ready, window exists
    const send = (key) => { if (win && !win.isDestroyed()) win.webContents.send('media-key', key) }
    globalShortcut.register('MediaPlayPause',     () => send('playpause'))
    globalShortcut.register('MediaNextTrack',     () => send('next'))
    globalShortcut.register('MediaPreviousTrack', () => send('prev'))
    win.webContents.on('before-input-event', (_e, input) => {
      if (input.type === 'keyDown' && input.key === 'F12') win.webContents.toggleDevTools()
    })
  })
}

app.whenReady().then(() => {
  createWindow()
})

app.on('window-all-closed', () => {
  globalShortcut.unregisterAll()
  destroyRpc()
  app.quit()
})

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow()
})

// Now-playing state - updated by the renderer, exposed via the control server
let cascadeNowPlaying = { title: null, artist: null, isPlaying: false }
ipcMain.on('now-playing-update', (_e, data) => { cascadeNowPlaying = { ...cascadeNowPlaying, ...data } })

// ── Debug mode ──────────────────────────────────────────────────────────────
// A sentinel file's mere presence turns on the renderer's debug panel - no
// settings toggle to accidentally ship on, no keyboard shortcut to fire by
// accident. Checked once at startup, three candidate locations so it works
// both packaged (userData) and run from a source checkout (project root, next
// to the executable).
const DEBUG_SENTINEL = '.cascade-debug'
function debugSentinelPresent() {
  const candidates = [
    path.join(app.getPath('userData'), DEBUG_SENTINEL),
    path.join(__dirname, DEBUG_SENTINEL),
  ]
  try { candidates.push(path.join(path.dirname(app.getPath('exe')), DEBUG_SENTINEL)) } catch {}
  return candidates.some(p => { try { return fs.existsSync(p) } catch { return false } })
}
const debugMode = debugSentinelPresent()
ipcMain.handle('is-debug-mode', () => debugMode)

// IPC: app version
ipcMain.handle('get-version', () => app.getVersion())

// IPC: whether this is a packaged (production) build vs. run from the command line
ipcMain.handle('is-packaged', () => app.isPackaged)

// IPC: theme switched in the renderer - recolour the OS-drawn caption buttons
// to match. No-op on macOS: setTitleBarOverlay only applies to a window
// created with titleBarOverlay set, which createWindow() only does elsewhere.
ipcMain.on('set-titlebar-overlay', (_e, { mode } = {}) => {
  if (process.platform === 'darwin') return
  if (!win || win.isDestroyed()) return
  try { win.setTitleBarOverlay(titleBarOverlayColors(mode)) } catch {}
})

// IPC: store
ipcMain.handle('store-get', (_e, key) => store.get(key))
ipcMain.handle('store-set', (_e, key, value) => store.set(key, value))
ipcMain.handle('store-delete', (_e, key) => store.delete(key))

// IPC: clipboard
ipcMain.handle('clipboard-write', (_e, text) => clipboard.writeText(text))

// IPC: shell
ipcMain.handle('shell-open', (_e, url) => shell.openExternal(url))

// IPC: download - uses Electron's session download API
ipcMain.handle('download-file', (_e, url, filename) => {
  win.webContents.downloadURL(url)
})

// ── Version helpers ────────────────────────────────────────────────────────────

function parseVersion(v) {
  const s = String(v).replace(/^v/, '')
  const betaMatch = s.match(/-b(\d+)$/i)
  const betaNum = betaMatch ? parseInt(betaMatch[1], 10) : Infinity
  const [major, minor, patch] = s.replace(/[-+][a-zA-Z0-9._]*$/, '').split('.').map(n => parseInt(n, 10) || 0)
  return [major, minor, patch, betaNum]
}
function isNewer(latest, current) {
  const [la, lb, lc, ld] = parseVersion(latest)
  const [ca, cb, cc, cd] = parseVersion(current)
  if (la !== ca) return la > ca
  if (lb !== cb) return lb > cb
  if (lc !== cc) return lc > cc
  return ld > cd
}

// ── Updater window ─────────────────────────────────────────────────────────────

function openUpdaterWindow(updateInfo) {
  pendingDownload = {
    version:     updateInfo.version,
    downloadUrl: updateInfo.downloadUrl || null,
    assetName:   updateInfo.assetName   || null,
    releaseUrl:  updateInfo.releaseUrl  || '',
    digest:      updateInfo.digest      || null,
    destPath:    null,
  }
  if (updaterWindow && !updaterWindow.isDestroyed()) { updaterWindow.focus(); return }
  updaterWindow = new BrowserWindow({
    width: 560, height: 640, minWidth: 480, minHeight: 500,
    title: 'Update Available', backgroundColor: '#111113',
    autoHideMenuBar: true, resizable: true,
    parent: win || undefined,
    webPreferences: { nodeIntegration: false, contextIsolation: true, preload: path.join(__dirname, 'updater-preload.js') }
  })
  updaterWindow.loadFile('updater.html')
  updaterWindow.webContents.once('did-finish-load', () => {
    updaterWindow.webContents.send('updater:init', {
      currentVersion:    app.getVersion(),
      newVersion:        updateInfo.version,
      releaseNotes:      updateInfo.releaseNotes  || '',
      releaseDate:       updateInfo.releaseDate   || '',
      releaseUrl:        updateInfo.releaseUrl    || '',
      hasDirectDownload: !!updateInfo.downloadUrl,
    })
  })
  updaterWindow.on('closed', () => { updaterWindow = null })
}

// ── Lyrics editor window ───────────────────────────────────────────────────────

ipcMain.on('open-lyrics-editor', (_e, data) => {
  if (lyricsEditorWindow && !lyricsEditorWindow.isDestroyed()) {
    lyricsEditorWindow.focus()
    lyricsEditorWindow.webContents.send('lyrics-editor-init', data)
    return
  }
  lyricsEditorWindow = new BrowserWindow({
    width: 900, height: 680, minWidth: 720, minHeight: 520,
    title: 'Lyrics Editor', backgroundColor: '#111113',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 12, y: 12 },
    autoHideMenuBar: true, resizable: true,
    webPreferences: {
      preload: path.join(__dirname, 'lyrics-editor-preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    show: false,
  })
  lyricsEditorWindow.loadFile('lyrics-editor.html')
  lyricsEditorWindow.once('ready-to-show', () => {
    lyricsEditorWindow.show()
    lyricsEditorWindow.webContents.send('lyrics-editor-init', data)
  })
  lyricsEditorWindow.webContents.on('before-input-event', (_e, input) => {
    if (input.type === 'keyDown' && input.key === 'F12') lyricsEditorWindow.webContents.toggleDevTools()
  })
  lyricsEditorWindow.on('closed', () => { lyricsEditorWindow = null })
})

// Relay a successful save to the main window - the editor writes straight to the
// server, so the main window's lyrics cache would otherwise keep serving the old copy.
ipcMain.on('lyrics-editor-saved', (_e, itemId) => {
  if (win && !win.isDestroyed()) win.webContents.send('lyrics-saved', itemId)
})

ipcMain.on('lyrics-editor-close', () => {
  if (lyricsEditorWindow && !lyricsEditorWindow.isDestroyed()) lyricsEditorWindow.close()
})

// ── GitHub release check ───────────────────────────────────────────────────────

// Which Linux package this install came from, so we hand back an update in the
// same format. AppImage announces itself through the environment; past that the
// distro's release file is the best available signal for deb vs rpm.
function linuxPackageKind() {
  if (process.env.APPIMAGE) return 'AppImage'
  // ponytail: a deb installed on an rpm distro (or vice versa) guesses wrong.
  // Read /opt/Cascade's owning package manager if that ever actually happens.
  if (fs.existsSync('/etc/debian_version')) return 'deb'
  if (fs.existsSync('/etc/redhat-release') || fs.existsSync('/etc/fedora-release')) return 'rpm'
  return null
}

// Returns the asset matching this exact platform/arch/format, or undefined.
// Deliberately no "close enough" fallback: handing someone an installer that
// cannot run on their machine is worse than sending them to the releases page.
function pickAsset(assets = []) {
  const byExt = re => assets.filter(a => re.test(a.name))

  if (process.platform === 'win32') return byExt(/\.exe$/i)[0]

  if (process.platform === 'darwin') {
    // Only the arm64 build carries its arch in the filename; the unsuffixed
    // .dmg is the x64 one. Matching on process.arch alone silently handed
    // Intel Macs the arm64 build.
    const dmgs = byExt(/\.dmg$/i)
    return process.arch === 'arm64'
      ? dmgs.find(a => /arm64/i.test(a.name))
      : dmgs.find(a => !/arm64/i.test(a.name))
  }

  if (process.platform === 'linux') {
    const kind = linuxPackageKind()
    if (kind === 'AppImage') return byExt(/\.AppImage$/i)[0]
    if (kind === 'deb')      return byExt(/\.deb$/i)[0]
    if (kind === 'rpm')      return byExt(/\.rpm$/i)[0]
  }

  return undefined
}

async function checkForUpdates() {
  try {
    // Defaults on for a beta build itself (so it keeps finding newer betas), unless
    // the user has explicitly chosen otherwise, that choice always wins.
    const isBetaBuild = /-b\d*$/.test(app.getVersion())
    const betaUpdates = store.get('betaUpdates', isBetaBuild)
    let release
    if (betaUpdates) {
      const res = await fetch(`https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=10`, {
        headers: { 'User-Agent': 'cascade-updater' }
      })
      if (!res.ok) throw new Error(`GitHub API ${res.status}`)
      const releases = await res.json()
      release = releases.find(r => !r.draft)
    } else {
      const res = await fetch(`https://api.github.com/repos/${GITHUB_REPO}/releases/latest`, {
        headers: { 'User-Agent': 'cascade-updater' }
      })
      if (!res.ok) throw new Error(`GitHub API ${res.status}`)
      release = await res.json()
    }
    if (!release) return { hasUpdate: false }
    const latestVersion = release.tag_name.replace(/^v/, '')
    if (!isNewer(latestVersion, app.getVersion())) return { hasUpdate: false }

    const asset = pickAsset(release.assets)

    openUpdaterWindow({
      version:      latestVersion,
      releaseNotes: release.body         || '',
      releaseDate:  release.published_at || '',
      releaseUrl:   release.html_url     || '',
      downloadUrl:  asset?.browser_download_url || null,
      assetName:    asset?.name          || null,
      digest:       asset?.digest        || null,
    })
    return { hasUpdate: true }
  } catch (err) {
    console.error('[updater] Check failed:', err.message)
    return { hasUpdate: false, error: err.message }
  }
}

// ── File downloader ────────────────────────────────────────────────────────────

function downloadFile(url, destPath, onProgress) {
  return new Promise((resolve, reject) => {
    let lastBytes = 0, lastTime = Date.now()
    function request(url, redirects) {
      if (redirects > 10) { reject(new Error('Too many redirects')); return }
      const lib = url.startsWith('https') ? https : http
      lib.get(url, { headers: { 'User-Agent': 'cascade-updater' } }, (res) => {
        if ([301, 302, 307, 308].includes(res.statusCode)) { res.resume(); request(res.headers.location, redirects + 1); return }
        if (res.statusCode !== 200) { res.resume(); reject(new Error(`HTTP ${res.statusCode}`)); return }
        const total = parseInt(res.headers['content-length'] || '0', 10)
        let transferred = 0
        const file = fs.createWriteStream(destPath)
        res.on('data', chunk => {
          transferred += chunk.length
          const now = Date.now(), elapsed = (now - lastTime) / 1000
          let bps = 0
          if (elapsed >= 0.5) { bps = (transferred - lastBytes) / elapsed; lastBytes = transferred; lastTime = now }
          if (onProgress) onProgress({ transferred, total, bytesPerSecond: bps })
        })
        res.pipe(file)
        file.on('finish', () => file.close(resolve))
        file.on('error', err => { try { fs.unlinkSync(destPath) } catch {} reject(err) })
        res.on('error', err => { try { fs.unlinkSync(destPath) } catch {} reject(err) })
      }).on('error', reject)
    }
    request(url, 0)
  })
}

// GitHub populates a "sha256:<hex>" digest on release assets - verifying against
// it catches transit corruption/tampering. It does NOT prove the release itself
// wasn't malicious (the digest is computed from the same upload), so this is
// defense-in-depth, not a substitute for code signing.
function verifyDigest(filePath, digest) {
  return new Promise((resolve, reject) => {
    const [algo, expected] = digest.split(':')
    const hash = crypto.createHash(algo)
    fs.createReadStream(filePath)
      .on('data', chunk => hash.update(chunk))
      .on('end', () => resolve(hash.digest('hex') === expected))
      .on('error', reject)
  })
}

// ── Updater IPC ────────────────────────────────────────────────────────────────

ipcMain.handle('check-for-updates', async () => {
  if (app.isPackaged) {
    return await checkForUpdates()
  } else {
    openUpdaterWindow({
      version: '99.0.0',
      releaseNotes: '### Dev test\n- Updater UI preview.\n- No actual download.',
      releaseDate: new Date().toISOString(),
      releaseUrl: `https://github.com/${GITHUB_REPO}/releases`,
      downloadUrl: null, assetName: null,
    })
    return { hasUpdate: true }
  }
})

ipcMain.handle('updater:download', async () => {
  if (!pendingDownload) return { ok: false }
  if (!pendingDownload.downloadUrl) {
    if (pendingDownload.releaseUrl) shell.openExternal(pendingDownload.releaseUrl)
    return { ok: true }
  }
  const destPath = path.join(os.tmpdir(), pendingDownload.assetName)
  try {
    if (updaterWindow && !updaterWindow.isDestroyed())
      updaterWindow.webContents.send('updater:log', `Downloading to ${destPath}...`)
    await downloadFile(pendingDownload.downloadUrl, destPath, (progress) => {
      if (!updaterWindow || updaterWindow.isDestroyed()) return
      const percent = progress.total > 0 ? Math.round((progress.transferred / progress.total) * 100) : 0
      const mbps = (progress.bytesPerSecond / 1024 / 1024).toFixed(2)
      const transferred = (progress.transferred / 1024 / 1024).toFixed(1)
      const total = (progress.total / 1024 / 1024).toFixed(1)
      updaterWindow.webContents.send('updater:progress', {
        percent, bytesPerSecond: progress.bytesPerSecond,
        transferred: progress.transferred, total: progress.total,
        logLine: `${percent}% - ${transferred} / ${total} MB  (${mbps} MB/s)`
      })
    })
    if (pendingDownload.digest) {
      const verified = await verifyDigest(destPath, pendingDownload.digest)
      if (!verified) {
        try { fs.unlinkSync(destPath) } catch {}
        throw new Error('Downloaded file failed integrity verification - it may have been corrupted or tampered with in transit')
      }
    }
    pendingDownload.destPath = destPath
    if (updaterWindow && !updaterWindow.isDestroyed())
      updaterWindow.webContents.send('updater:done', { version: pendingDownload.version })
  } catch (err) {
    if (updaterWindow && !updaterWindow.isDestroyed())
      updaterWindow.webContents.send('updater:error', { message: `Download failed: ${err.message}` })
  }
  return { ok: true }
})

ipcMain.handle('updater:install', () => {
  if (pendingDownload?.destPath) {
    if (process.platform === 'darwin') {
      shell.openPath(pendingDownload.destPath)
    } else {
      shell.openPath(pendingDownload.destPath).then(() => setTimeout(() => app.quit(), 1500))
    }
  } else if (pendingDownload?.releaseUrl) {
    shell.openExternal(pendingDownload.releaseUrl)
  }
})

ipcMain.handle('updater:dismiss', () => {
  if (updaterWindow && !updaterWindow.isDestroyed()) updaterWindow.close()
})

// IPC: Kugou KRC lyrics - word-level, no auth required
// Search: http://lyrics.kugou.com/search   Download: http://lyrics.kugou.com/download
// KRC decryption: skip 4-byte 'krc1' header, XOR with fixed 16-byte key, zlib inflate.
;(function() {
  const zlib    = require('zlib')
  const KRC_KEY = Buffer.from([64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105])

  ipcMain.handle('kugou-lyrics', async (_e, { title, artist, durationMs }) => {
    try {
      const keyword   = `${artist} - ${title}`
      const searchUrl = `http://lyrics.kugou.com/search?ver=1&man=yes&client=pc` +
                        `&keyword=${encodeURIComponent(keyword)}&duration=${Math.round(durationMs)}`
      const sRes  = await fetch(searchUrl, { signal: AbortSignal.timeout(8000) })
      if (!sRes.ok) return null
      const sData = await sRes.json()
      const candidates = sData.candidates
      if (!candidates?.length) return null

      const { id, accesskey } = candidates[0]
      const dlUrl = `http://lyrics.kugou.com/download?ver=1&client=pc` +
                    `&id=${id}&accesskey=${accesskey}&fmt=krc&charset=utf8`
      const dRes  = await fetch(dlUrl, { signal: AbortSignal.timeout(8000) })
      if (!dRes.ok) return null
      const dData = await dRes.json()
      if (!dData.content) return null

      // Decrypt KRC
      const encrypted = Buffer.from(dData.content, 'base64')
      const raw       = encrypted.slice(4)       // skip 'krc1' magic
      const decrypted = Buffer.alloc(raw.length)
      for (let i = 0; i < raw.length; i++) decrypted[i] = raw[i] ^ KRC_KEY[i % 16]
      return zlib.inflateSync(decrypted).toString('utf8')
    } catch (err) {
      console.error('[Kugou] error:', err.message)
      return null
    }
  })
})()

