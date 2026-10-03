import { _electron as electron } from 'playwright-core'
// The installed Electron binary for this platform (the package's main export is its path).
import electronPath from 'electron'

// Run from the repo root: CASCADE_DIR defaults to the current directory.
const ROOT = process.env.CASCADE_DIR || process.cwd()
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'

// A 3 second 8kHz 16-bit mono WAV with a tone: decodable by Chromium everywhere.
function wav(seconds = 3, rate = 8000) {
  const n = seconds * rate, data = Buffer.alloc(n * 2)
  for (let i = 0; i < n; i++) data.writeInt16LE(Math.round(Math.sin(i / 8) * 8000), i * 2)
  const h = Buffer.alloc(44)
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVEfmt ', 8); h.writeUInt32LE(16, 16)
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28)
  h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(data.length, 40)
  return Buffer.concat([h, data])
}

async function until(win, pred, ms = 15000) {
  const t0 = Date.now()
  for (;;) {
    const s = await win.evaluate(() => window.cascade.offline.summary())
    if (pred(s)) return s
    if (Date.now() - t0 > ms) throw new Error('timeout ' + JSON.stringify(s).slice(0, 500))
    await new Promise(r => setTimeout(r, 150))
  }
}
const good = wav()
const seen = []
const aa = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1', bb = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2', cc = 'ccccccccccccccccccccccccccccccc3', dd = 'ddddddddddddddddddddddddddddddd4', ee = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeee5'
const srv = await new Promise(r => { const s = http.createServer((req, res) => {
  const u = req.url.split('?')[0]
  seen.push(`${req.method} ${u} auth=${req.headers.authorization ? 'y' : 'n'} hdr=${req.headers['x-proxy'] || '-'}`)
  const m = /^\/Items\/(\w+)\/Download$/.exec(u)
  if (m) {
    if (m[1] === aa || m[1] === dd) {
      res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': good.length, 'Content-Disposition': `attachment; filename="${m[1]}.wav"` }); res.end(good); return
    }
    if (m[1] === bb) { // announces the full length, dies halfway
      res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': good.length })
      res.write(good.subarray(0, 1000)); setTimeout(() => res.destroy(), 50); return
    }
    if (m[1] === ee) { // slow: still running when the account signs out
      res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': good.length, 'Content-Disposition': `attachment; filename="${m[1]}.wav"` })
      res.write(good.subarray(0, 1000)); const t = setTimeout(() => res.end(good.subarray(1000)), 3000); res.on('close', () => clearTimeout(t)); return
    }
    if (m[1] === cc) { res.writeHead(403, { 'Content-Type': 'text/plain' }); res.end('no'); return }
  }
  if (/\/Images\/Primary/.test(u)) { res.writeHead(200, { 'Content-Type': 'image/jpeg' }); res.end(Buffer.from([0xff, 0xd8, 0xff, 0xd9])); return }
  res.writeHead(404); res.end()
}).listen(0, '127.0.0.1', () => r(s)) })
const port = srv.address().port, server = `http://127.0.0.1:${port}`
const dir = fs.mkdtempSync('/tmp/cascade-ud-')
const app = await electron.launch({ executablePath: electronPath, args: [ROOT, '--no-sandbox', `--user-data-dir=${dir}`] })
const win = await app.firstWindow()
await win.waitForFunction(() => window.cascade && window.cascade.offline)
// The renderer's launch tells the main process who is signed in (nobody, in this
// fresh profile); let that land before choosing an account here.
await win.waitForTimeout(2500)
console.log('add with nobody signed in:', await win.evaluate(() => window.cascade.offline.add({ Id: 'x1', Name: 'X' }, [{ Id: 'y1', Type: 'Audio' }], { authorization: 'MediaBrowser Token="x"' })))
await win.evaluate(() => window.cascade.offline.setOwner('u-1'))
await win.evaluate(([server]) => window.cascade.connection.set(server, [{ name: 'X-Proxy', value: 'p1' }]), [server])
const album = { Id: 'album0000000000000000000000000001', Name: 'Album', Type: 'MusicAlbum' }
const mk = (Id, n) => ({ Id, Name: n, Type: 'Audio', Album: 'Album', AlbumId: album.Id, Artists: ['A'], RunTimeTicks: 30_000_000, UserData: { PlayCount: 9 } })
const tracks = [mk(aa, 'ok'), mk(bb, 'truncated'), mk(cc, 'forbidden')]
await win.evaluate(() => { window.__ev = []; window.cascade.offline.onEvent(e => window.__ev.push(e)) })
console.log('add:', await win.evaluate(([a, t]) => window.cascade.offline.add(a, t, { authorization: 'MediaBrowser Token="x"' }), [album, tracks]))
await until(win, s => s.active.length === 0 && (Object.keys(s.ready).length + Object.keys(s.failed).length) >= 3)
let sum = await win.evaluate(() => window.cascade.offline.summary())
console.log('ready:', Object.keys(sum.ready).map(k => k.slice(0, 3)), 'failed:', Object.entries(sum.failed).map(([k, v]) => [k.slice(0, 3), v]))
console.log('collections:', JSON.stringify(sum.collections.map(c => ({ id: c.item.Id.slice(0, 5), done: c.done, total: c.total, bytes: c.bytes }))), 'art:', sum.art.map(a => a.slice(0, 5)))
const off = path.join(dir, 'offline', 'u-1')
console.log('media dir:', fs.readdirSync(path.join(off, 'media')))
console.log('art dir:', fs.readdirSync(path.join(off, 'art')))
await new Promise(r => setTimeout(r, 900)); const idx = JSON.parse(fs.readFileSync(path.join(off, 'index.json'), 'utf8'))
console.log('index tracks:', Object.keys(idx.tracks).length, 'slim UserData kept?', 'UserData' in idx.tracks[aa].item, 'file:', idx.tracks[aa].file, 'bytes', idx.tracks[aa].bytes)
console.log('requests:', [...new Set(seen)].join(' | '))

// playback through the protocol, with seeking and WebAudio readability
const url = sum.ready[aa]
const play = await win.evaluate(async (url) => {
  const a = document.createElement('audio'); a.crossOrigin = 'anonymous'; a.src = url
  await new Promise((res, rej) => { a.onloadedmetadata = res; a.onerror = () => rej(new Error('media error ' + (a.error && a.error.code))) })
  const out = { duration: a.duration }
  a.currentTime = 2; await new Promise(r => { a.onseeked = r })
  out.seekedTo = a.currentTime
  const ctx = new AudioContext(); const src = ctx.createMediaElementSource(a); const an = ctx.createAnalyser(); src.connect(an); an.connect(ctx.destination)
  await a.play(); await new Promise(r => setTimeout(r, 400))
  const buf = new Float32Array(an.fftSize); an.getFloatTimeDomainData(buf)
  out.peak = Math.max(...buf.map(Math.abs)); out.playing = !a.paused && a.currentTime > 2
  return out
}, url)
console.log('playback:', JSON.stringify(play))
const probe = await win.evaluate(async ([url, bad]) => {
  const r = {}
  const rng = await fetch(url, { headers: { Range: 'bytes=0-9' } }); r.range = [rng.status, rng.headers.get('content-range'), (await rng.arrayBuffer()).byteLength]
  for (const u of bad) { try { r[u] = (await fetch(u)).status } catch (e) { r[u] = 'ERR' } }
  return r
}, [url, [
  'cascade-offline://local/media/../index.json', 'cascade-offline://local/index.json', 'cascade-offline://local/media/nothere.wav',
  `cascade-offline://local/media/${bb}.partial`, 'cascade-offline://other/media/x.wav', 'cascade-offline://local/media/%2e%2e/index.json', 'cascade-offline://local/art/zzz.jpg']])
console.log('protocol:', JSON.stringify(probe))

// accounts: another account sees none of u-1's music, cannot play it, and a
// download running when u-1 signs out is stopped, not finished into anyone's folder
const slow = { Id: 'slow0000000000000000000000000001', Name: 'Slow', Type: 'MusicAlbum' }
await win.evaluate(([a, t]) => window.cascade.offline.add(a, t, { authorization: 'MediaBrowser Token="x"' }), [slow, [mk(ee, 'slow')]])
await until(win, s => s.active.some(a => a.id === ee && a.received > 0))
await win.evaluate(() => window.cascade.offline.setOwner('u-2'))
sum = await win.evaluate(() => window.cascade.offline.summary())
console.log('as u-2 -> collections:', sum.collections.length, 'ready:', Object.keys(sum.ready).length, 'art:', sum.art.length, '| u-1 track via protocol:', await win.evaluate(async (u) => (await fetch(u)).status, url))
await new Promise(r => setTimeout(r, 3500))
console.log('after the slow stream would have ended -> u-1 media:', fs.readdirSync(path.join(off, 'media')).map(f => f.slice(0, 3) + f.slice(32)), '| u-2 folder:', fs.readdirSync(path.join(dir, 'offline', 'u-2')).map(d => [d, fs.statSync(path.join(dir, 'offline', 'u-2', d)).isDirectory() ? fs.readdirSync(path.join(dir, 'offline', 'u-2', d)) : '-']))
await win.evaluate(() => window.cascade.offline.setOwner(null))
sum = await win.evaluate(() => window.cascade.offline.summary())
console.log('signed out -> collections:', sum.collections.length, '| protocol:', await win.evaluate(async (u) => (await fetch(u)).status, url))
await win.evaluate(() => window.cascade.offline.setOwner('u-1'))
sum = await win.evaluate(() => window.cascade.offline.summary())
console.log('u-1 again -> ready:', Object.keys(sum.ready).map(k => k.slice(0, 3)), 'slow pending:', JSON.stringify(sum.collections.find(c => c.item.Id === slow.Id)), '| protocol:', await win.evaluate(async (u) => (await fetch(u)).status, url))
await win.evaluate((id) => window.cascade.offline.remove(id), slow.Id)

// shared track + removal
const pl = { Id: 'play00000000000000000000000000001', Name: 'P', Type: 'Playlist' }
await win.evaluate(([p, t]) => window.cascade.offline.add(p, t, { authorization: 'MediaBrowser Token="x"' }), [pl, [mk(aa, 'ok'), mk(dd, 'second')]])
await until(win, s => s.active.length === 0 && Object.keys(s.ready).length >= 2)
await win.evaluate((id) => window.cascade.offline.remove(id), album.Id)
sum = await win.evaluate(() => window.cascade.offline.summary())
console.log('after removing album -> ready:', Object.keys(sum.ready).map(k => k.slice(0, 3)), 'media:', fs.readdirSync(path.join(off, 'media')).map(f => f.slice(0, 3)))
await win.evaluate((id) => window.cascade.offline.remove(id), pl.Id)
console.log('after removing both -> media:', fs.readdirSync(path.join(off, 'media')), 'art:', fs.readdirSync(path.join(off, 'art')))

// plays queue
await win.evaluate(() => window.cascade.offline.addPlay({ itemId: 'abc123', userId: 'u-1', date: '2026-02-03T04:05:06Z' }))
await win.evaluate(() => window.cascade.offline.addPlay({ itemId: '../x', userId: 'u-1', date: '2026-02-03T04:05:06Z' }))
console.log('plays taken:', JSON.stringify(await win.evaluate(() => window.cascade.offline.takePlays())), 'then:', JSON.stringify(await win.evaluate(() => window.cascade.offline.takePlays())))
await app.close(); srv.close()
