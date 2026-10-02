import { _electron as electron } from 'playwright-core'
// The installed Electron binary for this platform (the package's main export is its path).
import electronPath from 'electron'

// Run from the repo root: CASCADE_DIR defaults to the current directory.
const ROOT = process.env.CASCADE_DIR || process.cwd()
import http from 'node:http'
import fs from 'node:fs'
const log = { A: [], B: [] }
const mk = (k) => new Promise(r => { const s = http.createServer((req, res) => {
  log[k].push({ method: req.method, url: req.url, h: { 'x-test-token': req.headers['x-test-token'], 'x-other': req.headers['x-other'], host: req.headers.host } })
  res.setHeader('Access-Control-Allow-Origin', '*'); res.setHeader('Access-Control-Allow-Headers', '*')
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return }
  res.setHeader('Content-Type', 'text/plain'); res.end('ok')
}).listen(0, '127.0.0.1', () => r(s)) })
const A = await mk('A'), B = await mk('B')
const pa = A.address().port, pb = B.address().port
const dir = fs.mkdtempSync('/tmp/cascade-ud-')
const app = await electron.launch({ executablePath: electronPath, args: [ROOT, '--no-sandbox', `--user-data-dir=${dir}`], env: { ...process.env, ELECTRON_DISABLE_SECURITY_WARNINGS: '1' } })
const win = await app.firstWindow()
await win.waitForLoadState('domcontentloaded')
await win.waitForFunction(() => window.cascade && window.cascade.connection)
const set = await win.evaluate(([pa]) => window.cascade.connection.set(`http://127.0.0.1:${pa}`, [
  { name: 'X-Test-Token', value: 'abc' }, { name: 'Authorization', value: 'evil' }, { name: 'Host', value: 'evil' }]), [pa])
console.log('sanitized', JSON.stringify(set))
await win.evaluate(async ([pa, pb]) => {
  await fetch(`http://127.0.0.1:${pa}/fetch`, { headers: { 'X-Other': '1' } }).then(r => r.text())
  await new Promise(res => { const i = new Image(); i.onload = i.onerror = res; i.src = `http://127.0.0.1:${pa}/img.png` })
  await new Promise(res => { const a = document.createElement('audio'); a.onerror = a.onloadstart = res; a.src = `http://127.0.0.1:${pa}/a.mp3`; a.load(); setTimeout(res, 1500) })
  await fetch(`http://localhost:${pa}/otherhost`).then(r => r.text())
  await fetch(`http://127.0.0.1:${pb}/otherport`).then(r => r.text())
}, [pa, pb])
console.log(JSON.stringify(log, null, 1))
// persisted?
const hdrs = await win.evaluate(() => window.cascade.connection.getHeaders())
console.log('get', JSON.stringify(hdrs))
const stored = await win.evaluate(() => window.cascade.store.get('customHeaders'))
console.log('store', JSON.stringify(stored))
await app.close(); A.close(); B.close()
