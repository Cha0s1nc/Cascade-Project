import { _electron as electron } from 'playwright-core'
// The installed Electron binary for this platform (the package's main export is its path).
import electronPath from 'electron'

// Run from the repo root: CASCADE_DIR defaults to the current directory.
const ROOT = process.env.CASCADE_DIR || process.cwd()
import http from 'node:http'
import fs from 'node:fs'
const srv = await new Promise(r => { const s = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*'); res.setHeader('Access-Control-Allow-Headers', '*')
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return }
  res.setHeader('Content-Type', 'application/json')
  if (req.url.startsWith('/Users/AuthenticateByName')) { res.end(JSON.stringify({ AccessToken: 't', User: { Id: 'u1', Name: 'b' } })); return }
  if (req.url.startsWith('/QuickConnect/Enabled')) { res.end('false'); return }
  if (req.url.startsWith('/Users/u1/Views')) { res.end(JSON.stringify({ Items: [{ Id: 'l', Name: 'M', CollectionType: 'music' }] })); return }
  if (req.url.startsWith('/Users/u1')) { res.end(JSON.stringify({ Id: 'u1', Policy: {} })); return }
  if (req.method === 'POST') { res.statusCode = 204; res.end(); return }
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }))
}).listen(0, '127.0.0.1', () => r(s)) })
const dir = fs.mkdtempSync('/tmp/cascade-ud-')
const app = await electron.launch({ executablePath: electronPath, args: [ROOT, '--no-sandbox', `--user-data-dir=${dir}`] })
const win = await app.firstWindow()
await win.waitForSelector('#setup-overlay:not(.hidden)')
await win.fill('#setup-url', `http://127.0.0.1:${srv.address().port}`); await win.fill('#setup-username', 'b'); await win.fill('#setup-password', 'p')
await win.click('#setup-connect')
await win.waitForFunction(() => document.getElementById('setup-overlay').classList.contains('hidden'))
await win.waitForTimeout(1200)
await win.evaluate(() => { for (const id of ['firstrun-overlay','video-intro-overlay']) document.getElementById(id)?.classList.add('hidden') })
console.log('is packaged:', await win.evaluate(() => window.cascade.isPackaged()))
console.log('btn dimmed (needs-admin):', await win.evaluate(() => document.getElementById('btn-miniplayer-open').classList.contains('needs-admin')))
await win.evaluate(() => document.getElementById('btn-miniplayer-open').click())
let mini
for (let i = 0; i < 40 && !mini; i++) { mini = app.windows().find(w => w.url().includes('miniplayer.html')); await new Promise(r => setTimeout(r, 200)) }
console.log('miniplayer window opened:', !!mini)
await mini.waitForLoadState('domcontentloaded')
console.log('_miniplayerOpen in main window:', await win.evaluate(() => _miniplayerOpen))
await app.evaluate(({ BrowserWindow }) => { const w = BrowserWindow.getAllWindows().find(x => x.webContents.getURL().includes('miniplayer.html')); w.setMinimumSize(300, 100); w.setSize(300, 640) })
await mini.waitForTimeout(600)
console.log('volume row visible in tall layout:', await mini.isVisible('.vol-row'))
const box = await mini.locator('#vol-bar').boundingBox()
await mini.mouse.click(box.x + box.width * 0.3, box.y + box.height / 2)
await mini.waitForTimeout(500)
console.log('main window volume after slider click at 30%:', await win.evaluate(() => volume))
console.log('slider fill:', await mini.evaluate(() => document.getElementById('vol-fill').style.width))
await app.close(); srv.close()
