import { _electron as electron } from 'playwright-core'

// Run from the repo root: CASCADE_DIR defaults to the current directory.
const ROOT = process.env.CASCADE_DIR || process.cwd()
import http from 'node:http'
import fs from 'node:fs'
const seen = []
const srv = await new Promise(r => { const s = http.createServer((req, res) => {
  const ok = req.headers['cf-access-client-id'] === 'id123'
  seen.push(`${req.method} ${req.url.split('?')[0]} ${ok ? 'HDR' : 'NOHDR'}`)
  res.setHeader('Access-Control-Allow-Origin', '*'); res.setHeader('Access-Control-Allow-Headers', '*')
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return }
  if (!ok) { res.statusCode = 403; res.end('proxy says no'); return }
  res.setHeader('Content-Type', 'application/json')
  if (req.url.startsWith('/QuickConnect/Enabled')) { res.end('true'); return }
  if (req.url.startsWith('/Users/AuthenticateByName')) { res.end(JSON.stringify({ AccessToken: 'tok', User: { Id: 'u1', Name: 'bob' } })); return }
  res.end('{}')
}).listen(0, '127.0.0.1', () => r(s)) })
const port = srv.address().port
const dir = fs.mkdtempSync('/tmp/cascade-ud-')
const app = await electron.launch({ executablePath: `${ROOT}/node_modules/electron/dist/electron`, args: [ROOT, '--no-sandbox', `--user-data-dir=${dir}`] })
const win = await app.firstWindow()
await win.waitForLoadState('domcontentloaded')
await win.waitForSelector('#setup-overlay:not(.hidden)')
await win.fill('#setup-url', `http://127.0.0.1:${port}`)
await win.fill('#setup-username', 'bob')
await win.fill('#setup-password', 'pw')
// bad headers first
await win.evaluate(() => document.getElementById('setup-advanced').open = true)
await win.fill('#setup-headers', 'Authorization: x\nnocolon')
await win.click('#setup-connect')
console.log('bad-headers error:', await win.textContent('#setup-error'))
await win.fill('#setup-headers', 'CF-Access-Client-Id: id123')
await win.waitForTimeout(900)
console.log('quickconnect shown:', await win.isVisible('#setup-quickconnect'))
await win.click('#setup-connect')
await win.waitForTimeout(2500)
console.log('overlay hidden after connect:', await win.evaluate(() => document.getElementById('setup-overlay').classList.contains('hidden')))
console.log('stored token:', await win.evaluate(() => window.cascade.store.get('token')))
console.log(seen.filter(l => /Authenticate|QuickConnect|Views/.test(l)).join('\n'))
console.log('any request without header:', seen.some(l => l.endsWith('NOHDR')), seen.filter(l => l.endsWith('NOHDR')))
await app.close(); srv.close()
