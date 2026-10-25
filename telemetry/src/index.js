// Cascade's opt-in telemetry: takes the once-a-day ping from
// src/core/telemetry.ts (and apple/CascadeKit's Telemetry.swift) and keeps one
// row per install per day. This is a public endpoint and the client is open
// source, so there is no key to check: everything is validated instead, and
// the numbers are treated as approximate. The request's IP is never read.

const EDITIONS = ['Cascade Electron', 'Cascade Mac', 'Cascade iOS', 'Cascade tvOS', 'Cascade Android']
// desktopDeviceName() in src/core/jellyfin.ts and cascadeDeviceName in Swift.
const DEVICES = ['Windows', 'Mac', 'Linux', 'Desktop', 'iPhone', 'iPad', 'Apple TV', 'Android']
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const VERSION = /^\d+\.\d+\.\d+(-[0-9A-Za-z.]{1,20})?$/
const MAX_SONGS = 5000   // TELEMETRY_MAX_SONGS in src/core/telemetry.ts
const MAX_BODY = 1024

/** The ping, or null if anything about it is off. */
export function parsePing(text) {
  if (text.length > MAX_BODY) return null
  let p
  try { p = JSON.parse(text) } catch { return null }
  if (!p || typeof p !== 'object') return null
  const { installId, version, edition, device, songs } = p
  if (typeof installId !== 'string' || !UUID.test(installId.toLowerCase())) return null
  if (typeof version !== 'string' || !VERSION.test(version)) return null
  if (!EDITIONS.includes(edition) || !DEVICES.includes(device)) return null
  if (!Number.isInteger(songs) || songs < 0 || songs > MAX_SONGS) return null
  return { installId: installId.toLowerCase(), version, edition, device, songs }
}

async function ping(request, env) {
  const p = parsePing(await request.text())
  if (!p) return new Response('Bad ping', { status: 400 })
  const day = new Date().toISOString().slice(0, 10)
  // A second ping the same day (clock change, reinstall of the same id) adds
  // its songs, capped, rather than counting the install twice.
  await env.DB.prepare(
    `INSERT INTO pings (day, install_id, version, edition, device, songs) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
     ON CONFLICT (day, install_id) DO UPDATE SET version = ?3, edition = ?4, device = ?5,
       songs = MIN(songs + ?6, ${MAX_SONGS})`
  ).bind(day, p.installId, p.version, p.edition, p.device, p.songs).run()
  return new Response(null, { status: 204 })
}

/** Aggregates only, never a row: public on purpose, so anyone can see what is kept. */
async function stats(env) {
  const daily = await env.DB.prepare(
    `SELECT day, COUNT(*) AS installs, SUM(songs) AS songs FROM pings
     WHERE day >= date('now', '-30 days') GROUP BY day ORDER BY day`
  ).all()
  const breakdown = col => env.DB.prepare(
    `SELECT ${col} AS name, COUNT(DISTINCT install_id) AS installs FROM pings
     WHERE day >= date('now', '-7 days') GROUP BY ${col} ORDER BY installs DESC`
  ).all()
  const [versions, editions, devices] = await Promise.all([breakdown('version'), breakdown('edition'), breakdown('device')])
  return Response.json({
    daily: daily.results,
    last7Days: { versions: versions.results, editions: editions.results, devices: devices.results },
  })
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (url.pathname === '/ping' && request.method === 'POST') return ping(request, env)
    if (url.pathname === '/stats' && request.method === 'GET') return stats(env)
    return new Response('Not found', { status: 404 })
  },
}
