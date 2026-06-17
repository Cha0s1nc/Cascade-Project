const { app, BrowserWindow, ipcMain, clipboard, shell, Menu, globalShortcut, TouchBar } = require('electron')
const { TouchBarButton, TouchBarSpacer, TouchBarLabel } = TouchBar
const path = require('path')
const https = require('https')
const http  = require('http')
const fs    = require('fs')
const os    = require('os')
const Store = require('electron-store')

// ── Discord RPC ────────────────────────────────────────────────────────────────
let rpcClient   = null
let rpcReady    = false
let rpcUpdateTimer = null
let lastRpcActivity = null

async function connectDiscordRpc(clientId) {
  if (!clientId) return
  try {
    const { Client } = require('discord-rpc')
    rpcClient = new Client({ transport: 'ipc' })
    rpcClient.on('ready', () => {
      rpcReady = true
      // Patch request() to inject type:2 (Listening) into every SET_ACTIVITY call
      // setActivity() strips the type field, so we add it back at the protocol level
      const _origRequest = rpcClient.request.bind(rpcClient)
      rpcClient.request = function(cmd, args, ...rest) {
        if (cmd === 'SET_ACTIVITY' && args?.activity) {
          args.activity.type = 2
          args.activity.status_display_type = 1  // show state (artist) in member list sidebar
        }
        return _origRequest(cmd, args, ...rest).catch(() => { /* Discord rate limit or transient error — suppress */ })
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
  if (!rpcClient || !rpcReady) return
  try { rpcClient.clearActivity() } catch {}
})

// ── Cascade Control Server (for Cha0s Stream integration) ─────────────────────
// Listens on 127.0.0.1:47847 — Cha0s Stream POSTs here instead of using OS media keys
const controlServer = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*')
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end() }
  if (req.method === 'POST' && req.url === '/cascade/control') {
    let body = ''
    req.on('data', chunk => { body += chunk })
    req.on('end', () => {
      try {
        const { action } = JSON.parse(body)
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
    res.writeHead(200, { 'Content-Type': 'application/json' })
    if (win && !win.isDestroyed()) {
      try {
        const result = await win.webContents.executeJavaScript(`
          JSON.stringify({
            title:     queue[queueIndex]?.Name    || null,
            artist:    queue[queueIndex]?.AlbumArtist || (queue[queueIndex]?.Artists?.[0]) || null,
            isPlaying: typeof audio !== 'undefined' ? !audio.paused : false
          })
        `)
        res.end(result)
      } catch {
        res.end(JSON.stringify(cascadeNowPlaying))
      }
    } else {
      res.end(JSON.stringify(cascadeNowPlaying))
    }
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

// ── Remote Control WebSocket Server (Android app) ─────────────────────────────
// Listens on all interfaces, port 9876.
// Enable/disable via store key 'remoteControlEnabled' (default: false).
// Protocol: JSON messages — see remote_control_service.dart for the schema.

const WebSocket = require('ws')
let remoteWss    = null
let remoteEnabled = false

function startRemoteWss(port = 9876) {
  if (remoteWss) return
  remoteWss = new WebSocket.Server({ port }, () => {
    console.log(`[remote] WebSocket server listening on *:${port}`)
  })

  remoteWss.on('connection', (ws) => {
    console.log('[remote] Android client connected')

    // Send current state immediately on connect
    broadcastRemoteState()

    ws.on('message', (raw) => {
      try {
        const msg = JSON.parse(raw.toString())
        handleRemoteCmd(msg)
      } catch {}
    })

    ws.on('close', () => console.log('[remote] Android client disconnected'))
    ws.on('error', (e) => console.warn('[remote] WS error:', e.message))
  })

  remoteWss.on('error', (e) => {
    console.warn('[remote] WSS error:', e.message)
    remoteWss = null
  })
}

function stopRemoteWss() {
  if (!remoteWss) return
  remoteWss.close(() => console.log('[remote] WebSocket server stopped'))
  remoteWss = null
}

function broadcastRemoteState(state) {
  if (!remoteWss) return
  // If no state passed, ask the renderer for current state
  if (!state) {
    if (win && !win.isDestroyed()) {
      win.webContents.send('remote-get-state')
    }
    return
  }
  const msg = JSON.stringify({ event: 'stateUpdate', ...state })
  remoteWss.clients.forEach((client) => {
    if (client.readyState === WebSocket.OPEN) client.send(msg)
  })
}

function handleRemoteCmd({ cmd, position, volume: vol }) {
  if (!win || win.isDestroyed()) return
  switch (cmd) {
    case 'play':
    case 'pause':
    case 'next':
    case 'prev':
      win.webContents.send('media-key',
        cmd === 'play' || cmd === 'pause' ? 'playpause' : cmd)
      break
    case 'seek':
      win.webContents.send('remote-seek', position)
      break
    case 'setVolume':
      win.webContents.send('remote-volume', vol)
      break
    case 'getState':
      broadcastRemoteState()
      break
  }
}

// Renderer → main: state update to broadcast to WS clients
ipcMain.on('remote-state-update', (_e, state) => broadcastRemoteState(state))

// IPC: enable/disable remote control
ipcMain.handle('remote-control-enable', (_e, enable) => {
  remoteEnabled = enable
  store.set('remoteControlEnabled', enable)
  if (enable) startRemoteWss()
  else        stopRemoteWss()
  return { ok: true }
})

ipcMain.handle('remote-control-status', () => ({
  enabled: remoteEnabled,
  port:    9876,
  clients: remoteWss ? remoteWss.clients.size : 0,
}))

// Auto-start if previously enabled
;(async () => {
  try {
    const wasEnabled = store.get('remoteControlEnabled')
    if (wasEnabled) { remoteEnabled = true; startRemoteWss() }
  } catch {}
})()

const GITHUB_REPO = 'Cha0s1nc/Cascade-Project'

const store = new Store()

let win
let updaterWindow  = null
let pendingDownload = null

function createWindow() {
  win = new BrowserWindow({
    width: 1100,
    height: 700,
    minWidth: 800,
    minHeight: 500,
    backgroundColor: '#111113',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 12, y: 11 },
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    show: false,
  })
  Menu.setApplicationMenu(null)

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

    // Register OS media keys here — app is already ready, window exists
    const send = (key) => { if (win && !win.isDestroyed()) win.webContents.send('media-key', key) }
    globalShortcut.register('MediaPlayPause',     () => send('playpause'))
    globalShortcut.register('MediaNextTrack',     () => send('next'))
    globalShortcut.register('MediaPreviousTrack', () => send('prev'))
    globalShortcut.register('F12', () => { if (win && !win.isDestroyed()) win.webContents.toggleDevTools() })
  })
}

app.whenReady().then(createWindow)

app.on('window-all-closed', () => {
  globalShortcut.unregisterAll()
  destroyRpc()
  app.quit()
})

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow()
})

// Now-playing state — updated by the renderer, exposed via the control server
let cascadeNowPlaying = { title: null, artist: null, isPlaying: false }
ipcMain.on('now-playing-update', (_e, data) => { cascadeNowPlaying = { ...cascadeNowPlaying, ...data } })

// IPC: app version
ipcMain.handle('get-version', () => app.getVersion())

// IPC: store
ipcMain.handle('store-get', (_e, key) => store.get(key))
ipcMain.handle('store-set', (_e, key, value) => store.set(key, value))
ipcMain.handle('store-delete', (_e, key) => store.delete(key))

// IPC: clipboard
ipcMain.handle('clipboard-write', (_e, text) => clipboard.writeText(text))

// IPC: shell
ipcMain.handle('shell-open', (_e, url) => shell.openExternal(url))

// IPC: download — uses Electron's session download API
ipcMain.handle('download-file', (_e, url, filename) => {
  win.webContents.downloadURL(url)
})

// ── Version helpers ────────────────────────────────────────────────────────────

function parseVersion(v) {
  // Strip pre-release suffix (e.g. 1.0.1b, 1.0.1-beta) before comparing
  return String(v).replace(/^v/, '').replace(/[-+][a-zA-Z0-9._]*$/, '').split('.').map(n => parseInt(n, 10) || 0)
}
function isNewer(latest, current) {
  const [la, lb, lc] = parseVersion(latest)
  const [ca, cb, cc] = parseVersion(current)
  if (la !== ca) return la > ca
  if (lb !== cb) return lb > cb
  return lc > cc
}

// ── Updater window ─────────────────────────────────────────────────────────────

function openUpdaterWindow(updateInfo) {
  pendingDownload = {
    version:     updateInfo.version,
    downloadUrl: updateInfo.downloadUrl || null,
    assetName:   updateInfo.assetName   || null,
    releaseUrl:  updateInfo.releaseUrl  || '',
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

// ── GitHub release check ───────────────────────────────────────────────────────

async function checkForUpdates() {
  try {
    const betaUpdates = store.get('betaUpdates', false)
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
    if (!release) return
    const latestVersion = release.tag_name.replace(/^v/, '')
    if (!isNewer(latestVersion, app.getVersion())) return

    const platform = process.platform
    const arch = process.arch
    let asset
    if (platform === 'win32') {
      asset = release.assets.find(a => /\.exe$/i.test(a.name))
    } else if (platform === 'darwin') {
      asset = release.assets.find(a => /\.dmg$/i.test(a.name) && a.name.includes(arch))
           || release.assets.find(a => /\.dmg$/i.test(a.name))
    } else {
      asset = null
    }

    openUpdaterWindow({
      version:      latestVersion,
      releaseNotes: release.body         || '',
      releaseDate:  release.published_at || '',
      releaseUrl:   release.html_url     || '',
      downloadUrl:  asset?.browser_download_url || null,
      assetName:    asset?.name          || null,
    })
  } catch (err) {
    console.error('[updater] Check failed:', err.message)
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

// ── Updater IPC ────────────────────────────────────────────────────────────────

ipcMain.handle('check-for-updates', () => {
  if (app.isPackaged) {
    checkForUpdates()
  } else {
    openUpdaterWindow({
      version: '99.0.0',
      releaseNotes: '### Dev test\n- Updater UI preview.\n- No actual download.',
      releaseDate: new Date().toISOString(),
      releaseUrl: `https://github.com/${GITHUB_REPO}/releases`,
      downloadUrl: null, assetName: null,
    })
  }
  return { ok: true }
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
        logLine: `${percent}% — ${transferred} / ${total} MB  (${mbps} MB/s)`
      })
    })
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

// IPC: native context menu for now-playing
ipcMain.handle('show-np-menu', (_e, actions) => {
  return new Promise((resolve) => {
    const template = actions.map(a => {
      if (a.type === 'separator') return { type: 'separator' }
      return {
        label: a.label,
        enabled: a.enabled !== false,
        ...(a.role ? { role: a.role } : {}),
        click: () => resolve(a.id)
      }
    })
    const menu = Menu.buildFromTemplate(template)
    menu.popup({ window: win, callback: () => resolve(null) })
  })
})
