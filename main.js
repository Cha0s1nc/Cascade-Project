const { app, BrowserWindow, ipcMain, clipboard, shell, Menu, globalShortcut, TouchBar, protocol, net, screen } = require('electron')

// A main-process throw before the window is shown means no window and, for a
// rejection, not even a message: Electron shows a dialog for an uncaught
// exception but stays completely silent on an unhandled rejection. That is how
// you get "it just does not open, nothing in the terminal". Both are printed
// here so a startup failure always says something.
process.on('uncaughtException', err => {
  console.error('[cascade] uncaught exception in the main process:', err)
})
process.on('unhandledRejection', err => {
  console.error('[cascade] unhandled rejection in the main process:', err)
})
const { TouchBarButton, TouchBarSpacer, TouchBarLabel } = TouchBar
const path = require('path')
const https = require('https')
const http  = require('http')
const fs    = require('fs')
const os    = require('os')
const { spawn } = require('child_process')
const { installInPlace } = require('./mac-update')
const crypto = require('crypto')
const { pathToFileURL } = require('url')
const Store = require('electron-store')

// ── On-device translation assets ──────────────────────────────────────────────
//
// The lyrics translator is Mozilla's bergamot runtime running Firefox
// Translations models (see "On-device translation models" further down). The
// renderer is a file:// page and fetch() from file:// is blocked, so the
// runtime's wasm and the downloaded models are served over a private scheme.
//
// This has to be declared before app ready. `supportFetchAPI` is what lets the
// runtime fetch its wasm and the model files at all; `secure` keeps its worker
// from being treated as a mixed-content downgrade; `standard` gives the URLs
// normal host/path parsing.
//
// `corsEnabled` is required too, and its absence once broke translation
// outright: the page is file://, so every fetch to this scheme is cross-origin,
// and Chromium refuses cross-origin fetches to any scheme not flagged for CORS.
// The translation library of the day swallowed that as "file was not found
// locally", so it read as a missing model rather than a blocked request.
protocol.registerSchemesAsPrivileged([{
  scheme: 'cascade-model',
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true },
}])

// Serve `rel` from inside `root`, or refuse. Trust boundary: the path comes off
// a URL. Without this, a request for ../../.. walks straight out of the
// directory and hands any file on disk to renderer JavaScript. path.sep guards
// the "/models-evil" prefix trick that a bare startsWith() would let through.
function serveWithin(root, rel) {
  const abs = path.normalize(path.join(root, rel))
  if (abs !== root && !abs.startsWith(root + path.sep)) {
    return new Response('Forbidden', { status: 403 })
  }
  return net.fetch(pathToFileURL(abs).toString())
}

function registerModelProtocol() {
  protocol.handle('cascade-model', (req) => {
    const url = new URL(req.url)
    const rel = decodeURIComponent(url.pathname)
    // The translation runtime's wasm. Its worker cannot fetch it from file://.
    if (rel.startsWith('/runtime/')) return serveWithin(BERGAMOT_RUNTIME_DIR, rel.slice('/runtime/'.length))
    if (rel === '/models/registry.json') return translationRegistryResponse(url.searchParams.get('key'))
    if (rel.startsWith('/models/')) return serveWithin(translationModelsDir(), rel.slice('/models/'.length))
    return new Response('Not found', { status: 404 })
  })
}

// ── Discord RPC ────────────────────────────────────────────────────────────────
let rpcClient   = null
let rpcReady    = false
let rpcUpdateTimer = null
let lastRpcActivity = null

// Discord rate-limits presence updates, so they are throttled to one per
// RPC_MIN_INTERVAL_MS. Leading edge, not trailing: the first update after a
// quiet spell goes out at once and only a burst gets coalesced. Trailing edge
// made every update wait out the full interval, which was most obvious on
// unpause - the presence is cleared the moment you pause, so it stayed gone
// for five seconds after you started playing again.
const RPC_MIN_INTERVAL_MS = 5000
let rpcLastSentAt = 0

// Discord activity type: 2 = Listening, 3 = Watching. Held here rather than on
// the activity object because setActivity() rebuilds that object from a fixed
// field list and drops anything it does not recognise - see the request() patch
// in connectDiscordRpc().
const RPC_TYPE_LISTENING = 2
const RPC_TYPE_WATCHING  = 3
let rpcActivityType = RPC_TYPE_LISTENING

// Reconnect on login failure or on Discord restarting - discord-rpc has no
// retry of its own, so without this a Discord not running at startup, or
// quit and relaunched later, killed presence for the rest of the session.
// Backoff (not the fixed interval RemoteControl uses for its own reconnect
// in remote-control.ts) because "Discord is not running" is commonly a long
// wait, not a blip on a LAN link.
const RPC_RECONNECT_MIN_MS = 15000
const RPC_RECONNECT_MAX_MS = 60000
let rpcClientId = null       // desired client id; null means RPC should be off
let rpcReconnectTimer = null
let rpcReconnectDelay = RPC_RECONNECT_MIN_MS

function cancelRpcReconnect() {
  if (rpcReconnectTimer) { clearTimeout(rpcReconnectTimer); rpcReconnectTimer = null }
  rpcReconnectDelay = RPC_RECONNECT_MIN_MS
}

// destroy() rejects rather than throws when the socket never connected or
// already closed itself (discord-rpc's IPC transport reads this.socket,
// which is null or already ended), so a plain try/catch around the call
// misses it and leaves an unhandled rejection. Also the one place a
// superseded client (replaced before login finished, or a stale success
// arriving after a newer attempt took over) gets told to let go of its
// socket - without this it sits connected to Discord forever, unused.
function closeRpcClient(client) {
  try { Promise.resolve(client.destroy()).catch(() => {}) } catch {}
}

function scheduleRpcReconnect() {
  if (rpcReconnectTimer || !rpcClientId) return
  const delay = rpcReconnectDelay
  rpcReconnectDelay = Math.min(rpcReconnectDelay * 2, RPC_RECONNECT_MAX_MS)
  rpcReconnectTimer = setTimeout(() => {
    rpcReconnectTimer = null
    connectDiscordRpc(rpcClientId)
  }, delay)
}

async function connectDiscordRpc(clientId) {
  if (!clientId) return
  rpcClientId = clientId
  // A fresh Client every attempt - discord-rpc caches a connect promise
  // internally and cannot be reused after a failed or closed login.
  let client = null
  try {
    const { Client } = require('discord-rpc')
    client = new Client({ transport: 'ipc' })
    rpcClient = client
    client.on('ready', () => {
      // A late READY from a client a newer attempt already replaced - close
      // it rather than leave it connected and unused. This and the check
      // below are what keep a stale client's events from clobbering the
      // current one's state.
      if (client !== rpcClient) { closeRpcClient(client); return }
      rpcReady = true
      cancelRpcReconnect()  // connected, so the next outage starts backoff fresh
      // Patch request() to inject the activity type into every SET_ACTIVITY call.
      // setActivity() strips the type field, so we add it back at the protocol
      // level - which is also why the renderer's choice arrives via
      // rpcActivityType rather than on the activity object itself.
      const _origRequest = client.request.bind(client)
      client.request = function(cmd, args, ...rest) {
        if (cmd === 'SET_ACTIVITY' && args?.activity) {
          args.activity.type = rpcActivityType
          args.activity.status_display_type = 1  // show state (artist/series) in member list sidebar
        }
        return _origRequest(cmd, args, ...rest).catch(() => { /* Discord rate limit or transient error - suppress */ })
      }
      if (win && !win.isDestroyed()) win.webContents.send('discord-rpc-status', true)
    })
    client.on('disconnected', () => {
      if (client !== rpcClient) return
      rpcReady = false
      rpcClient = null
      if (win && !win.isDestroyed()) win.webContents.send('discord-rpc-status', false)
      // Discord quit, crashed, or is restarting for an update. There is no
      // event for "Discord came back", so retrying on a timer is the only way
      // to notice - the renderer already treats a true status as a fresh
      // reconnect and re-sends the current presence.
      scheduleRpcReconnect()
    })
    await client.login({ clientId })
  } catch (e) {
    console.warn('[discord-rpc] connect failed:', e.message)
    // A timed-out login (RPC_CONNECTION_TIMEOUT) can leave the socket itself
    // still open even though the promise rejected - close it regardless of
    // whether this attempt is still current.
    if (client) closeRpcClient(client)
    // Only touch shared state if this attempt is still the current one - a
    // disable or a client id change in the meantime already moved rpcClient
    // on, and clearing it here would null out a newer, live client.
    if (client && client === rpcClient) {
      rpcClient = null
      rpcReady  = false
      scheduleRpcReconnect()
    }
  }
}

function destroyRpc() {
  rpcClientId = null
  cancelRpcReconnect()
  if (rpcClient) {
    const client = rpcClient
    rpcClient = null
    rpcReady = false
    closeRpcClient(client)
  }
}

// Cover a programmatic app.quit() (the updater's silent-install paths) as
// well as window-all-closed, which already calls destroyRpc() itself.
// Separate listener, not folded into the existing will-quit handler above,
// so this stays inside the Discord section.
app.on('will-quit', destroyRpc)

ipcMain.on('discord-rpc-connect', async (_e, clientId) => {
  destroyRpc()
  if (clientId) await connectDiscordRpc(clientId)
})

function flushRpcActivity() {
  rpcUpdateTimer = null
  if (!rpcClient || !rpcReady) return
  rpcLastSentAt = Date.now()
  try {
    if (lastRpcActivity) rpcClient.setActivity(lastRpcActivity)
    else rpcClient.clearActivity()
  } catch {}
}

ipcMain.on('discord-rpc-update', (_e, activity) => {
  if (!rpcClient || !rpcReady) return
  // `watching` rides along on the activity; setActivity() would drop it, so it
  // is lifted out here and applied by the request() patch instead.
  rpcActivityType = activity?.watching ? RPC_TYPE_WATCHING : RPC_TYPE_LISTENING
  lastRpcActivity = activity
  if (rpcUpdateTimer) return  // a send is already queued, and it reads the latest
  const wait = RPC_MIN_INTERVAL_MS - (Date.now() - rpcLastSentAt)
  if (wait <= 0) flushRpcActivity()
  else rpcUpdateTimer = setTimeout(flushRpcActivity, wait)
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
  } else if (req.method === 'GET' && req.url === '/cascade/jellyfin') {
    // Cha0s Stream needs a Jellyfin session to resolve song requests. Rather
    // than proxy search through here - which would need request/response IPC
    // into the renderer, where `jf` actually lives - hand over the session and
    // let it use Jellyfin's own API directly. 404 until connect() has run.
    if (!cascadeJellyfin) {
      res.writeHead(404, { 'Content-Type': 'application/json' })
      return res.end(JSON.stringify({ ok: false, error: 'Not connected to Jellyfin' }))
    }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ ok: true, ...cascadeJellyfin }))
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
/** titleBarOverlay options for win32/linux, or nothing at all if building them
 *  fails. Degrading to no overlay costs the OS caption buttons; throwing here
 *  costs the entire window. */
function overlayOptions() {
  try {
    return { titleBarOverlay: { ...titleBarOverlayColors(storedThemeMode()), height: TITLEBAR_HEIGHT } }
  } catch (e) {
    console.error('[cascade] titleBarOverlay unavailable, falling back to a plain hidden titlebar:', e)
    return {}
  }
}

/**
 * Show a window created with `show: false`, once.
 *
 * ready-to-show alone is not enough. It fires on the renderer's first paint,
 * and on Windows a hidden window can fail to produce one at all: Chromium sees
 * no reason to paint something invisible, so the window waits to be shown
 * before painting and waits for a paint before being shown. Confirmed in
 * practice - the main window never appeared and the event never fired, while
 * the page itself was perfectly fine underneath.
 *
 * did-finish-load is the escape: it fires when the page has loaded, whether or
 * not anything has been painted. Whichever arrives first wins, with a timeout
 * as a last resort so a window can never be invisible forever. The backgroundColor
 * set on each window is what stops the early case flashing white.
 */
function showWhenReady(w, after) {
  let shown = false
  const showOnce = (why) => {
    if (shown || !w || w.isDestroyed()) return
    shown = true
    if (why) console.error(`[cascade] ${why}`)
    w.show()
    if (after) after()
  }
  w.once('ready-to-show', () => showOnce(null))
  w.webContents.once('did-finish-load', () => showOnce(null))
  setTimeout(() => showOnce('window never became ready, showing it anyway'), 10000)
}

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
let metadataEditorWindow = null
let miniPlayerWindow  = null
let pendingDownload   = null

function createWindow() {
  const isDarwin = process.platform === 'darwin'
  // `npm run demo` (or `electron . --fullscreen`): opens straight into
  // fullscreen, for demos and screen recordings, on an external monitor when
  // one is connected. Fullscreen fills whichever display the window starts on.
  const demo = process.argv.includes('--fullscreen')
  const demoDisplay = demo ? screen.getAllDisplays().find(d => !d.internal) : null
  win = new BrowserWindow({
    width: 1100,
    height: 700,
    ...(demoDisplay ? { x: demoDisplay.bounds.x + 40, y: demoDisplay.bounds.y + 40 } : {}),
    fullscreen: demo,
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
      // Built separately and defensively: this is the newest thing in here and
      // the only part that is macOS-untestable, so if the platform rejects the
      // overlay the app must still open with a plain hidden titlebar rather
      // than failing to produce a window at all.
      : overlayOptions()),
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

  showWhenReady(win)

  // Hung off did-finish-load rather than ready-to-show. Same reason as
  // showWhenReady: ready-to-show can simply never fire on Windows, which
  // silently cost the media keys, the F12 devtools binding and the update
  // check there. None of this needs a painted window, only a loaded one.
  win.webContents.once('did-finish-load', () => {
    if (app.isPackaged) setTimeout(checkForUpdates, 5000)

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
  registerModelProtocol()
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

// The live Jellyfin session, sent by the renderer's connect(). Held in memory
// only - it is the renderer's token, not a second credential to persist, and a
// stale one on disk would outlive the session it came from.
let cascadeJellyfin = null
ipcMain.on('jellyfin-credentials', (_e, data) => {
  cascadeJellyfin = data && data.url && data.token ? { ...data } : null
})

// ── Debug mode ──────────────────────────────────────────────────────────────
// A sentinel file's mere presence turns on the renderer's debug panel - no
// settings toggle to accidentally ship on, no keyboard shortcut to fire by
// accident. Checked once at startup, three candidate locations so it works
// both packaged (userData) and run from a source checkout (project root, next
// to the executable).
const DEBUG_SENTINEL = '.cascade-debug'
function debugSentinelPresent() {
  const candidates = [path.join(__dirname, DEBUG_SENTINEL)]
  try { candidates.push(path.join(app.getPath('userData'), DEBUG_SENTINEL)) } catch {}
  try { candidates.push(path.join(path.dirname(app.getPath('exe')), DEBUG_SENTINEL)) } catch {}
  return candidates.some(p => { try { return fs.existsSync(p) } catch { return false } })
}

// Resolved on first ask, not at module scope. It used to run during require(),
// which meant app.getPath('userData') was called before the app was ready and
// outside any try - and anything thrown there takes the whole main process down
// before a window exists, with nothing on screen to say why. A diagnostic must
// never be able to stop the app starting.
let _debugMode = null
ipcMain.handle('is-debug-mode', () => {
  if (_debugMode === null) {
    try { _debugMode = debugSentinelPresent() } catch (e) {
      console.error('[cascade] debug sentinel check failed, carrying on without it:', e)
      _debugMode = false
    }
  }
  return _debugMode
})

// IPC: per-process resource use, for the debug panel's resources section. It
// exists so a performance change is judged on a number rather than a feel.
// Every Electron process is listed: the renderer (where the translation
// worker's WASM heap is counted, since a dedicated Worker is a thread, not a
// process), the GPU process, which carries the compositing cost, and the rest.
// CPU is measured since the previous call, so the panel's 1s poll is what makes
// it a per-second figure; the first reading after launch is always 0.
ipcMain.handle('app-metrics', () => app.getAppMetrics().map(m => ({
  type: m.type,
  pid: m.pid,
  memMB: Math.round(m.memory.workingSetSize / 1024),
  cpu: m.cpu.percentCPUUsage,
  // Wake-ups are the clearest sign of a timer or rAF loop that should be
  // asleep. Always 0 on Windows.
  wakeups: m.cpu.idleWakeupsPerSecond,
})))

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
// Web links only. Some of what reaches this comes from third parties (a
// SpicyLyrics credit link), and openExternal will just as happily launch a
// file:// path or a custom app scheme.
ipcMain.handle('shell-open', (_e, url) => {
  if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) return
  return shell.openExternal(url)
})

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
  // Same show:false + ready-to-show pattern the main window was caught by, so
  // the lyrics editor would never have opened on Windows either.
  showWhenReady(lyricsEditorWindow, () => {
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

// ── Metadata editor window ─────────────────────────────────────────────────────
// Same shape as the lyrics editor above: its own small window, its own preload,
// its own save-then-tell-the-main-window-to-drop-its-cache handshake. Gating on
// jf.isAdmin happens in renderer.js before this ever fires - POST /Items/{id}
// is RequiresElevation on the server, so a non-admin call would just 403, but
// there is no reason to let it get that far.

ipcMain.on('open-metadata-editor', (_e, data) => {
  if (metadataEditorWindow && !metadataEditorWindow.isDestroyed()) {
    metadataEditorWindow.focus()
    metadataEditorWindow.webContents.send('metadata-editor-init', data)
    return
  }
  // Unlike the lyrics editor, this window keeps the OS's own title bar rather
  // than drawing a custom one: titleBarStyle:'hiddenInset' is macOS-only and
  // silently ignored elsewhere, which is how a hand-rolled titlebar strip ends
  // up stacked under the OS's own default one on Windows/Linux. A plain framed
  // window sidesteps that entirely - nothing to guard per platform.
  metadataEditorWindow = new BrowserWindow({
    width: 640, height: 620, minWidth: 520, minHeight: 480,
    title: 'Edit Metadata', backgroundColor: '#111113',
    autoHideMenuBar: true, resizable: true,
    webPreferences: {
      preload: path.join(__dirname, 'metadata-editor-preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    show: false,
  })
  metadataEditorWindow.loadFile('metadata-editor.html')
  // Same show:false + ready-to-show pattern as the lyrics editor, for the same
  // reason - ready-to-show alone can simply never fire on Windows.
  showWhenReady(metadataEditorWindow, () => {
    metadataEditorWindow.webContents.send('metadata-editor-init', data)
  })
  metadataEditorWindow.webContents.on('before-input-event', (_e, input) => {
    if (input.type === 'keyDown' && input.key === 'F12') metadataEditorWindow.webContents.toggleDevTools()
  })
  metadataEditorWindow.on('closed', () => { metadataEditorWindow = null })
})

ipcMain.on('metadata-editor-saved', (_e, itemId) => {
  if (win && !win.isDestroyed()) win.webContents.send('metadata-saved', itemId)
})

ipcMain.on('metadata-editor-close', () => {
  if (metadataEditorWindow && !metadataEditorWindow.isDestroyed()) metadataEditorWindow.close()
})

// ── Miniplayer window ──────────────────────────────────────────────────────────
// A remote control view, not a second player - see CODEMAP.md. Playback keeps
// running in the main window's two <video> decks; this window only mirrors a
// state snapshot and sends back play/pause/prev/next, which the main window
// applies through its own existing button handlers (see onControl in
// renderer.js) rather than any new playback code living here.

// Apple Music-style vertical-only resize: width stays fixed (miniplayer.html's
// compact-bar/stacked-art container query switches on height, not width), and
// height ranges from a bare compact bar up to a comfortably art-forward view.
// None of resizable/minWidth/maxWidth/minHeight/maxHeight below are macOS-only
// (unlike titleBarStyle/trafficLightPosition above) - all three platforms
// honour them, so no per-platform guard is needed here.
const MINI_WIDTH = 300
const MINI_MIN_HEIGHT = 100
const MINI_MAX_HEIGHT = 900   // Apple Music's own tall state is ~880px
const MINI_DEFAULT_HEIGHT = 120

ipcMain.on('open-miniplayer', () => {
  if (miniPlayerWindow && !miniPlayerWindow.isDestroyed()) {
    miniPlayerWindow.focus()
  } else {
    // Store values are untrusted (CODEMAP) - a stale height from a build with
    // a different min/max range must not hand the window an out-of-range size.
    const savedHeight = store.get('miniplayerHeight')
    const height = (typeof savedHeight === 'number' && savedHeight >= MINI_MIN_HEIGHT && savedHeight <= MINI_MAX_HEIGHT)
      ? savedHeight : MINI_DEFAULT_HEIGHT

    miniPlayerWindow = new BrowserWindow({
      // Real traffic lights on macOS rather than an in-page button. They give a
      // close that cannot be broken by page CSS, and they drag the window for
      // free - which matters here, because the in-page versions of both were
      // dead until the drag region was cut back to a strip. Windows and Linux
      // stay frameless and keep the in-page close button; a titleBarOverlay at
      // this window size would eat most of the top edge.
      ...(process.platform === 'darwin'
        ? {
            titleBarStyle: 'hidden',
            trafficLightPosition: { x: 10, y: 6 },
            // A blurred translucent panel rather than a black rectangle. macOS
            // only: Windows and Linux fall back to the page's own translucent
            // background over an opaque window, which still reads as a tint.
            vibrancy: 'under-window',
            transparent: true,
          }
        : {}),
      width: MINI_WIDTH, height,
      minWidth: MINI_WIDTH, maxWidth: MINI_WIDTH,
      minHeight: MINI_MIN_HEIGHT, maxHeight: MINI_MAX_HEIGHT,
      title: 'Cascade', backgroundColor: '#111113',
      frame: false, resizable: true, alwaysOnTop: true, skipTaskbar: true,
      autoHideMenuBar: true,
      webPreferences: {
        preload: path.join(__dirname, 'miniplayer-preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
      },
      show: false,
    })
    // Hidden until the pointer is over the window (miniplayer-hover below).
    if (process.platform === 'darwin') miniPlayerWindow.setWindowButtonVisibility(false)
    miniPlayerWindow.loadFile('miniplayer.html')
    // Same show:false + ready-to-show pattern as every other secondary window -
    // ready-to-show alone can simply never fire on Windows.
    showWhenReady(miniPlayerWindow)
    // Debounced so a live drag-resize doesn't write the store on every
    // intermediate frame.
    let resizeSaveTimer = null
    miniPlayerWindow.on('resize', () => {
      clearTimeout(resizeSaveTimer)
      resizeSaveTimer = setTimeout(() => {
        if (miniPlayerWindow && !miniPlayerWindow.isDestroyed()) {
          store.set('miniplayerHeight', miniPlayerWindow.getBounds().height)
        }
      }, 400)
    })
    miniPlayerWindow.on('closed', () => {
      clearTimeout(resizeSaveTimer)
      clearInterval(miniHoverTimer); miniHoverTimer = null
      miniPlayerWindow = null
      // Restoring the main window belongs HERE, not only in the
      // miniplayer-restore handler below - this fires no matter how the
      // window closed (the close button, the OS window-menu Close Window
      // shortcut, Alt+F4, anything). The miniplayer stands in for the main
      // window (win.minimize(), never hide()), so any path that loses this
      // window must bring the main one back or the user is left with no
      // window at all, which is exactly the failure this app already shipped
      // once.
      if (win && !win.isDestroyed()) { win.restore(); win.focus() }
    })
  }
  // Compact-mode convention (Spotify/Apple Music): the miniplayer stands in for
  // the main window rather than sitting alongside it. minimize(), not hide() -
  // this app has no tray icon, so hide() would leave no way back to it.
  if (win && !win.isDestroyed()) win.minimize()
})

ipcMain.on('miniplayer-state', (_e, state) => {
  if (miniPlayerWindow && !miniPlayerWindow.isDestroyed()) miniPlayerWindow.webContents.send('miniplayer-state', state)
})

// Traffic lights only while the pointer is over the miniplayer. The page's
// mouseleave is not trusted to hide them: the lights are native buttons drawn
// over the page, so pointing AT them can read as leaving the page, and hiding
// them then would pull the close button out from under the pointer. On a
// leave, the real cursor position decides, re-checked until it is outside.
let miniHoverTimer = null
ipcMain.on('miniplayer-hover', (_e, on) => {
  if (process.platform !== 'darwin') return
  clearInterval(miniHoverTimer); miniHoverTimer = null
  if (!miniPlayerWindow || miniPlayerWindow.isDestroyed()) return
  if (on === true) { miniPlayerWindow.setWindowButtonVisibility(true); return }
  // True once there is nothing left to watch: window gone, or pointer out
  // and the lights hidden.
  const settled = () => {
    if (!miniPlayerWindow || miniPlayerWindow.isDestroyed()) return true
    const p = screen.getCursorScreenPoint()
    const b = miniPlayerWindow.getBounds()
    if (p.x >= b.x && p.x < b.x + b.width && p.y >= b.y && p.y < b.y + b.height) return false
    miniPlayerWindow.setWindowButtonVisibility(false)
    return true
  }
  if (settled()) return
  miniHoverTimer = setInterval(() => {
    if (settled()) { clearInterval(miniHoverTimer); miniHoverTimer = null }
  }, 250)
})

ipcMain.on('miniplayer-control', (_e, action) => {
  if (win && !win.isDestroyed()) win.webContents.send('miniplayer-control', action)
})

// Closing (button or click-anywhere) just closes the window - the 'closed'
// handler above is the single place that restores the main window, so every
// way this window can go away ends up there instead of duplicating the logic.
ipcMain.on('miniplayer-restore', () => {
  if (miniPlayerWindow && !miniPlayerWindow.isDestroyed()) miniPlayerWindow.close()
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

  // Apple Silicon only. An Intel Mac gets undefined and is sent to the release
  // page rather than handed a build it cannot run. The arm64 build carries its
  // arch in the filename, so the match stays explicit even though it is now the
  // only dmg published; older releases still have an unsuffixed x64 one.
  if (process.platform === 'darwin') {
    return process.arch === 'arm64' ? byExt(/\.dmg$/i).find(a => /arm64/i.test(a.name)) : undefined
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

// ── On-device translation models ─────────────────────────────────────────────
//
// Mozilla Firefox Translations models, one per source language into English,
// downloaded on first use instead of shipped (about 50-70 MB each). The
// manifest pins every file by sha256. Each file is fetched from Cascade's
// GitHub release first and Mozilla's CDN second, and must match the hash
// whichever answered.
//
// A model directory only ever exists complete: files land in <key>.partial/
// and the directory is renamed once every file has verified. So "ready" is
// simply "the directory exists", and a download killed halfway leaves nothing
// that reads as installed.

const TRANSLATION_MANIFEST = require('./translation-models.json')
const BERGAMOT_RUNTIME_DIR = path.join(__dirname, 'build', 'bergamot', 'runtime')

// Resolved on first ask, like DEBUG_SENTINEL: app.getPath() must never run
// during require(), before the app is ready.
let _translationModelsDir = null
function translationModelsDir() {
  if (!_translationModelsDir) _translationModelsDir = path.join(app.getPath('userData'), 'translation-models')
  return _translationModelsDir
}

// Trust boundary: keys arrive over IPC and URLs and end up in filesystem paths,
// so only a key the manifest itself defines is ever accepted.
function translationModel(key) {
  if (typeof key !== 'string' || !Object.prototype.hasOwnProperty.call(TRANSLATION_MANIFEST.models, key)) {
    throw new Error(`Unknown translation model: ${key}`)
  }
  return TRANSLATION_MANIFEST.models[key]
}

const translationModelBytes = (model) => Object.values(model.files).reduce((n, f) => n + f.size, 0)
const translationModelReady = (key) => fs.existsSync(path.join(translationModelsDir(), key))

const _translationDownloads = new Map()   // key -> { promise, transferred }

function translationModelsStatus() {
  return Object.fromEntries(Object.entries(TRANSLATION_MANIFEST.models).map(([key, model]) => {
    const dl = _translationDownloads.get(key)
    return [key, {
      name: model.name,
      bytes: translationModelBytes(model),
      state: dl ? 'downloading' : translationModelReady(key) ? 'ready' : 'absent',
      transferred: dl ? dl.transferred : 0,
    }]
  }))
}

function sendTranslationProgress(payload) {
  if (win && !win.isDestroyed()) win.webContents.send('translation-models:progress', payload)
}

function downloadTranslationModel(key) {
  const model = translationModel(key)
  if (translationModelReady(key)) return Promise.resolve()
  const inFlight = _translationDownloads.get(key)
  if (inFlight) return inFlight.promise   // a second click joins the first download

  const total = translationModelBytes(model)
  const entry = { transferred: 0, promise: null }
  const promise = (async () => {
    const dir = translationModelsDir()
    const partial = path.join(dir, `${key}.partial`)
    fs.rmSync(partial, { recursive: true, force: true })   // leftovers from an interrupted run
    fs.mkdirSync(partial, { recursive: true })

    let completed = 0   // bytes in files that already verified
    let lastSent = 0
    const report = (fileBytes, force) => {
      entry.transferred = completed + fileBytes
      const now = Date.now()
      if (force || now - lastSent >= 250) {
        lastSent = now
        sendTranslationProgress({ key, state: 'downloading', transferred: entry.transferred, total })
      }
    }

    for (const f of Object.values(model.files)) {
      const dest = path.join(partial, f.file)
      const sources = [`${TRANSLATION_MANIFEST.github}${key}-en.${f.file}`, f.mozilla]
      let lastError = null
      for (const url of sources) {
        try {
          // downloadFile resolves on a stream that ended early, so the hash is
          // what actually proves a complete, untampered file. Never skip it.
          await downloadFile(url, dest, p => report(p.transferred))
          if (await verifyDigest(dest, `sha256:${f.sha256}`)) { lastError = null; break }
          lastError = new Error('checksum mismatch')
        } catch (err) {
          lastError = err
        }
        try { fs.unlinkSync(dest) } catch {}
        report(0, true)
      }
      if (lastError) throw new Error(`${f.file}: ${lastError.message}`)
      completed += f.size
      report(0, true)
    }
    fs.renameSync(partial, path.join(dir, key))
  })()
  entry.promise = promise
  _translationDownloads.set(key, entry)
  promise
    .catch(() => {})   // the IPC caller receives the rejection; this chain only cleans up
    .finally(() => {
      _translationDownloads.delete(key)
      sendTranslationProgress({ key, state: translationModelReady(key) ? 'ready' : 'absent', transferred: 0, total })
    })
  return promise
}

function removeTranslationModel(key) {
  const model = translationModel(key)
  if (_translationDownloads.has(key)) throw new Error('This model is still downloading')
  fs.rmSync(path.join(translationModelsDir(), key), { recursive: true, force: true })
  sendTranslationProgress({ key, state: 'absent', transferred: 0, total: translationModelBytes(model) })
}

// translator.js keys a registry by from+to ("zhen"), so Simplified and
// Traditional Chinese could never share one. Each translator asks for a
// registry holding only its own model, and only once that model is installed.
function translationRegistryResponse(key) {
  let model
  try { model = translationModel(key) } catch { return new Response('{}', { status: 404 }) }
  if (!translationModelReady(key)) return new Response('{}', { status: 404 })
  const files = Object.fromEntries(Object.entries(model.files).map(([part, f]) =>
    [part, { name: `cascade-model://app/models/${key}/${encodeURIComponent(f.file)}` }]))
  return new Response(JSON.stringify({ [`${key.slice(0, 2)}en`]: files }), {
    headers: { 'content-type': 'application/json' },
  })
}

ipcMain.handle('translation-models:status', () => translationModelsStatus())
ipcMain.handle('translation-models:download', (_e, key) => downloadTranslationModel(key))
ipcMain.handle('translation-models:remove', (_e, key) => removeTranslationModel(key))

// ── Apple Translation (macOS 26+) ────────────────────────────────────────────
//
// On a Mac that supports it, lyric translation can use the translation built
// into macOS instead of Mozilla's downloaded models. Apple's framework is Swift
// only, so native/apple-translate is a small helper process, built by
// scripts/build-apple-translate.js and spoken to over stdin/stdout, one JSON
// line each way.
//
// One long-lived process, started on first use and ended after
// APPLE_TRANSLATE_IDLE_MS without a request, so a sheet's lines share one
// loaded model instead of paying Apple's startup per line.

// The helper is executed, and nothing inside app.asar can be: electron-builder
// unpacks build/apple-translate/ (asarUnpack), so a packaged build finds it
// under app.asar.unpacked instead.
const APPLE_TRANSLATE_BIN = path.join(__dirname, 'build', 'apple-translate', 'apple-translate')
  .replace(`app.asar${path.sep}`, `app.asar.unpacked${path.sep}`)
const APPLE_TRANSLATE_IDLE_MS = 5 * 60 * 1000
const APPLE_SETTINGS_URL = 'x-apple.systempreferences:com.apple.Localization-Settings.extension'

// Only macOS 26+ has the windowless API the helper uses, and the helper is
// built with a macOS 26 deployment target, so an older Mac never launches it.
function appleTranslationSupported() {
  return process.platform === 'darwin'
    && parseInt(process.getSystemVersion(), 10) >= 26
    && fs.existsSync(APPLE_TRANSLATE_BIN)
}

let _appleHelper = null   // { proc, pending: Map<id, {resolve, reject}>, seq, buffer }
let _appleIdleTimer = null

function appleHelper() {
  if (_appleHelper) return _appleHelper
  const proc = spawn(APPLE_TRANSLATE_BIN, [], { stdio: ['pipe', 'pipe', 'ignore'] })
  const helper = { proc, pending: new Map(), seq: 0, buffer: '' }

  proc.stdout.setEncoding('utf8')
  proc.stdout.on('data', chunk => {
    helper.buffer += chunk
    let nl
    while ((nl = helper.buffer.indexOf('\n')) >= 0) {
      const line = helper.buffer.slice(0, nl)
      helper.buffer = helper.buffer.slice(nl + 1)
      let msg
      try { msg = JSON.parse(line) } catch { continue }
      const waiter = helper.pending.get(msg.id)
      if (!waiter) continue
      helper.pending.delete(msg.id)
      if (msg.error) waiter.reject(new Error(msg.error))
      else waiter.resolve(msg)
    }
  })

  // A helper that dies takes every request in flight with it. Fail them all
  // and forget it, so the next request starts a fresh one.
  const fail = (err) => {
    if (_appleHelper === helper) _appleHelper = null
    for (const waiter of helper.pending.values()) waiter.reject(err)
    helper.pending.clear()
  }
  proc.on('error', fail)
  proc.stdin.on('error', fail)
  proc.on('exit', code => fail(new Error(`Apple Translation helper exited (${code})`)))

  _appleHelper = helper
  return helper
}

function appleRequest(request) {
  clearTimeout(_appleIdleTimer)
  const helper = appleHelper()
  const id = ++helper.seq
  return new Promise((resolve, reject) => {
    helper.pending.set(id, { resolve, reject })
    helper.proc.stdin.write(JSON.stringify({ ...request, id }) + '\n')
  }).finally(() => {
    if (_appleHelper && !_appleHelper.pending.size) {
      _appleIdleTimer = setTimeout(() => {
        if (_appleHelper && !_appleHelper.pending.size) { _appleHelper.proc.kill(); _appleHelper = null }
      }, APPLE_TRANSLATE_IDLE_MS)
    }
  })
}

app.on('will-quit', () => { _appleHelper?.proc.kill() })

ipcMain.handle('apple-translation:supported', () => appleTranslationSupported())

// Status of every language Cascade translates, straight from macOS.
ipcMain.handle('apple-translation:availability', async () => {
  if (!appleTranslationSupported()) return {}
  const { status } = await appleRequest({ op: 'availability', languages: Object.keys(TRANSLATION_MANIFEST.models) })
  return status
})

// Trust boundary: both arguments come from the renderer. Only a language
// Cascade itself offers, and a single lyric line of sane length, go to macOS.
ipcMain.handle('apple-translation:translate', async (_e, key, text) => {
  translationModel(key)
  if (typeof text !== 'string' || text.length > 2000) throw new Error('Invalid text to translate')
  if (!appleTranslationSupported()) throw new Error('Apple Translation is not available on this Mac')
  const { text: english } = await appleRequest({ op: 'translate', source: key, text })
  return english
})

// ── Lyric translation cache ─────────────────────────────────────────────────
// Translated lyric lines, kept between sessions so a song translated once is
// instant after a restart. The renderer owns expiry (25 days, see
// src/core/translation-cache.ts) and cleans what it loads; this only reads and
// writes the file. Written to a temp file and renamed, so a crash mid-write
// never leaves half a file behind.
const TRANSLATION_CACHE_MAX = 5000
const translationCachePath = () => path.join(app.getPath('userData'), 'translation-cache.json')

ipcMain.handle('translation-cache:load', () => {
  try { return JSON.parse(fs.readFileSync(translationCachePath(), 'utf8')) } catch { return [] }
})

// Trust boundary: the entries come from the renderer. Only the expected shape,
// and no more than the renderer ever keeps, reaches the disk.
ipcMain.handle('translation-cache:save', (_e, entries) => {
  const ok = Array.isArray(entries) && entries.length <= TRANSLATION_CACHE_MAX && entries.every(e =>
    Array.isArray(e) && e.length === 3 && typeof e[0] === 'string' && e[0].length <= 4000 &&
    typeof e[1] === 'string' && e[1].length <= 4000 && typeof e[2] === 'number')
  if (!ok) throw new Error('Invalid translation cache')
  const file = translationCachePath()
  fs.writeFileSync(`${file}.tmp`, JSON.stringify(entries))
  fs.renameSync(`${file}.tmp`, file)
})

// Translation Languages is a button inside Language & Region with no link of
// its own, so this opens Language & Region and the prompt says where to click.
ipcMain.handle('apple-translation:open-settings', () => shell.openExternal(APPLE_SETTINGS_URL))

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

// Windows can install itself. These are the flags electron-updater passes to an
// electron-builder NSIS installer: --updated marks it an upgrade rather than a
// fresh install, /S suppresses the wizard, --force-run relaunches us afterwards.
//
// /D pins the target directory. Without it a silent assisted installer (this one
// has allowToChangeInstallationDirectory) falls back to its default path rather
// than wherever the user actually installed, so an update can land beside the old
// copy instead of over it. NSIS requires /D last and unquoted, which is why it is
// built that way and not passed through a quoting helper.
function installSilentlyWindows(installerPath) {
  const args = ['--updated', '/S', '--force-run', `/D=${path.dirname(process.execPath)}`]
  const child = spawn(installerPath, args, { detached: true, stdio: 'ignore' })
  child.unref()
  return child
}

ipcMain.handle('updater:install', () => {
  if (!pendingDownload?.destPath) {
    if (pendingDownload?.releaseUrl) shell.openExternal(pendingDownload.releaseUrl)
    return
  }

  const handOver = () => shell.openPath(pendingDownload.destPath).then(() => {
    // macOS still needs the drag to Applications, so it stays open. Everything
    // else is handing off to an installer that has to replace a running binary.
    if (process.platform !== 'darwin') setTimeout(() => app.quit(), 1500)
  })

  // macOS replaces the app in place and relaunches; see mac-update.js. Any
  // reason that is not safe (running from the DMG or a translocated copy, a
  // folder this account cannot write to, a staged copy that fails its checks)
  // falls back to opening the DMG, which is what every Mac update did before.
  // An unpackaged dev run has no Cascade.app of its own to replace.
  if (process.platform === 'darwin') {
    if (!app.isPackaged) return handOver()
    const log = (line) => {
      if (updaterWindow && !updaterWindow.isDestroyed()) updaterWindow.webContents.send('updater:log', line)
    }
    return installInPlace({
      dmgPath: pendingDownload.destPath,
      appBundle: path.resolve(process.execPath, '..', '..', '..'),
      expectedVersion: pendingDownload.version,
      bundleId: require('./package.json').build.appId,
      pid: process.pid,
      log,
    }).then(() => {
      setTimeout(() => app.quit(), 300)
    }).catch((err) => {
      console.error('[updater] In-place update failed, opening the installer:', err.message)
      log(`Could not update in place (${err.message}). Opening the installer instead.`)
      return handOver()
    })
  }

  if (process.platform !== 'win32') return handOver()

  try {
    let quitTimer = null
    const child = installSilentlyWindows(pendingDownload.destPath)
    // spawn reports a missing or unrunnable installer asynchronously, so the
    // quit waits long enough to hear about it. Quitting first would leave the
    // user with no app and no installer.
    child.on('error', (err) => {
      console.error('[updater] Silent install failed, opening the installer:', err.message)
      clearTimeout(quitTimer)
      handOver()
    })
    quitTimer = setTimeout(() => app.quit(), 1000)
  } catch (err) {
    console.error('[updater] Silent install failed, opening the installer:', err.message)
    handOver()
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

