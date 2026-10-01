import { _electron as electron } from 'playwright-core'

// Run from the repo root: CASCADE_DIR defaults to the current directory.
const ROOT = process.env.CASCADE_DIR || process.cwd()
import http from 'node:http'
import fs from 'node:fs'

function wav(seconds = 20, rate = 8000) {
  const n = seconds * rate, data = Buffer.alloc(n * 2)
  for (let i = 0; i < n; i++) data.writeInt16LE(Math.round(Math.sin(i / 8) * 8000), i * 2)
  const h = Buffer.alloc(44)
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVEfmt ', 8); h.writeUInt32LE(16, 16)
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28)
  h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(data.length, 40)
  return Buffer.concat([h, data])
}
const good = wav()
const log = []
const T1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1'
const ALB = 'album0000000000000000000000000001'
function makeServer(port) {
  return new Promise(r => { const s = http.createServer((req, res) => {
    const u = req.url.split('?')[0]
    log.push(`${req.method} ${req.url}`)
    res.setHeader('Access-Control-Allow-Origin', '*'); res.setHeader('Access-Control-Allow-Headers', '*'); res.setHeader('Access-Control-Allow-Methods', '*')
    if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return }
    let body = ''; req.on('data', d => body += d); req.on('end', () => {
      if (u === '/Users/AuthenticateByName') { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ AccessToken: 'tok', User: { Id: 'u1', Name: 'bob' } })); return }
      if (u === '/QuickConnect/Enabled') { res.setHeader('Content-Type', 'application/json'); res.end('false'); return }
      if (u === '/Users/u1') { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ Id: 'u1', Policy: { IsAdministrator: true, EnableContentDownloading: true } })); return }
      if (u === '/Users/u1/Views') { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ Items: [{ Id: 'lib1', Name: 'Music', CollectionType: 'music' }] })); return }
      if (/^\/Items\/\w+\/Download$/.test(u)) { res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': good.length, 'Content-Disposition': 'attachment; filename="x.wav"' }); res.end(good); return }
      if (/\/Images\/Primary/.test(u)) { res.writeHead(200, { 'Content-Type': 'image/jpeg' }); res.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64')); return }
      if (req.method === 'POST') { res.statusCode = 204; res.end(); return }
      res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }))
    })
  }).listen(port, '127.0.0.1', () => r(s)) })
}
const tmp = await makeServer(0); const port = tmp.address().port; tmp.close(); await new Promise(r => setTimeout(r, 100))
let srv = await makeServer(port)
const server = `http://127.0.0.1:${port}`
const dir = fs.mkdtempSync('/tmp/cascade-ud-')
const launch = () => electron.launch({ executablePath: `${ROOT}/node_modules/electron/dist/electron`, args: [ROOT, '--no-sandbox', `--user-data-dir=${dir}`] })

// ---- run 1: sign in, download ----
let app = await launch(); let win = await app.firstWindow()
await win.waitForSelector('#setup-overlay:not(.hidden)')
await win.fill('#setup-url', server); await win.fill('#setup-username', 'bob'); await win.fill('#setup-password', 'pw')
await win.click('#setup-connect')
await win.waitForFunction(() => document.getElementById('setup-overlay').classList.contains('hidden'))
await win.waitForTimeout(1500)
await win.evaluate(async () => { await window.cascade.store.set('wizardSeenRevision', 999); await window.cascade.store.set('videoIntroSeen', true); for (const id of ['firstrun-overlay','video-intro-overlay']) document.getElementById(id)?.classList.add('hidden') })
const album = { Id: ALB, Name: 'Offline Album', Type: 'MusicAlbum' }
const track = { Id: T1, Name: 'Song One', Type: 'Audio', Album: 'Offline Album', AlbumId: ALB, Artists: ['Artist'], RunTimeTicks: 200_000_000 }
await win.evaluate(([a, t]) => window.cascade.offline.add(a, [t], { authorization: 'MediaBrowser Token="tok"' }), [album, track])
for (let i = 0; i < 40; i++) { const s = await win.evaluate(() => window.cascade.offline.summary()); if (s.collections[0]?.done === 1 && s.art.length) break; await win.waitForTimeout(200) }
await win.evaluate(() => refreshOffline())
await win.click('[data-view="downloads"]')
await win.waitForSelector('.dl-card')
await win.waitForTimeout(300); console.log('art loaded:', await win.evaluate(() => { const i = document.querySelector('.dl-art img'); return i ? [i.complete, i.naturalWidth, i.src.slice(0, 40)] : null }))
console.log('RUN1 card:', await win.textContent('.dl-name'), '|', await win.textContent('.dl-meta'), '| total:', await win.textContent('#downloads-total'), '| art html:', await win.evaluate(() => document.querySelector('.dl-art').innerHTML), JSON.stringify(await win.evaluate(() => ({art: [..._offline.art], n: _offline.collections.length}))))
await win.waitForTimeout(700)  // let the debounced index save land
await app.close(); srv.close()
await new Promise(r => setTimeout(r, 300))

// ---- run 2: server down ----
app = await launch(); win = await app.firstWindow()
await win.waitForFunction(() => document.body.classList.contains('offline-mode'), null, { timeout: 30000 })
console.log('RUN2 offline-mode:', true, '| active view:', await win.evaluate(() => document.querySelector('.view.active').id), '| banner hidden:', await win.evaluate(() => document.getElementById('downloads-banner').hidden))
console.log('setup overlay hidden:', await win.evaluate(() => document.getElementById('setup-overlay').classList.contains('hidden')))
await win.waitForSelector('.dl-card')
console.log('card:', await win.textContent('.dl-name'), '|', await win.textContent('.dl-meta'))
await win.click('[data-dl="songs"]'); await win.waitForSelector('.dl-tracks .track-row')
console.log('songs listed:', await win.locator('.dl-tracks .track-row').count(), '| row art:', await win.getAttribute('.dl-tracks .track-thumb img', 'src'))
await win.click('[data-dl="play"]')
await win.waitForTimeout(2500)
console.log('playing:', JSON.stringify(await win.evaluate(() => { const a = audio; return { src: a.src, paused: a.paused, t: a.currentTime, err: a.error && a.error.code } })))
console.log('now playing title:', await win.evaluate(() => document.getElementById('np-title')?.textContent || document.querySelector('.np-title')?.textContent))
const sum = await win.evaluate(() => window.cascade.offline.summary())
console.log('plays queued:', sum.plays)
await win.evaluate(() => stopPlayback())

// ---- run 2b: server back ----
srv = await makeServer(port)
log.length = 0
await win.evaluate(() => window.dispatchEvent(new Event('online')))
await win.waitForFunction(() => !document.body.classList.contains('offline-mode'), null, { timeout: 30000 })
await win.waitForTimeout(1500)
console.log('RUN2b left offline mode; active view:', await win.evaluate(() => document.querySelector('.view.active').id))
console.log('replayed:', log.filter(l => l.startsWith('POST /UserPlayedItems')).map(l => l.replace(/datePlayed=[^&]+/, 'datePlayed=<date>')))
console.log('plays after replay:', (await win.evaluate(() => window.cascade.offline.summary())).plays)
await app.close(); srv.close()
