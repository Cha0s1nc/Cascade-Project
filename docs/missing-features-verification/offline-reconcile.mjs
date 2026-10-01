import { _electron as electron } from 'playwright-core'

// Run from the repo root: CASCADE_DIR defaults to the current directory.
const ROOT = process.env.CASCADE_DIR || process.cwd()
import fs from 'node:fs'
import path from 'node:path'
const dir = fs.mkdtempSync('/tmp/cascade-ud-')
const off = path.join(dir, 'offline')
fs.mkdirSync(path.join(off, 'media'), { recursive: true }); fs.mkdirSync(path.join(off, 'art'), { recursive: true })
const A = 'a'.repeat(32), B = 'b'.repeat(32), C = 'c'.repeat(32)
fs.writeFileSync(path.join(off, 'index.json'), JSON.stringify({
  tracks: { [A]: { item: { Id: A, Name: 'present' }, file: `media/${A}.flac`, bytes: 5 }, [B]: { item: { Id: B, Name: 'missing' }, file: `media/${B}.flac`, bytes: 5 },
            [C]: { item: { Id: C, Name: 'escape' }, file: 'media/../../evil', bytes: 5 } },
  collections: [{ item: { Id: 'col1', Name: 'C', Type: 'MusicAlbum' }, trackIds: [A, B, C] }], plays: [] }))
fs.writeFileSync(path.join(off, 'media', `${A}.flac`), 'xxxxx')
fs.writeFileSync(path.join(off, 'media', `${B}.partial`), 'half')   // an unfinished download
fs.writeFileSync(path.join(off, 'media', 'stray.flac'), 'nobody')   // finished after its collection was removed
fs.writeFileSync(path.join(off, 'art', 'x.partial'), 'half')
const app = await electron.launch({ executablePath: `${ROOT}/node_modules/electron/dist/electron`, args: [ROOT, '--no-sandbox', `--user-data-dir=${dir}`] })
const win = await app.firstWindow()
await win.waitForFunction(() => window.cascade && window.cascade.offline)
const s = await win.evaluate(() => window.cascade.offline.summary())
console.log('ready:', Object.keys(s.ready).map(k => k[0]), 'collections:', JSON.stringify(s.collections.map(c => [c.done, c.total])))
console.log('media:', fs.readdirSync(path.join(off, 'media')), 'art:', fs.readdirSync(path.join(off, 'art')))
await app.close()
