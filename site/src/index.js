// cascade.chaosinc.xyz: the project's site (public/, served as static
// assets), the maintainer login, and the announcements panel.
// announcements.cascade.chaosinc.xyz is this same Worker and serves only the
// feed every Cascade app fetches at launch. The feed is announcements.json in
// the cascade-plugins R2 bucket, so plugins.chaosinc.xyz/announcements.json
// is the same file. /releases.json (the releases page and the landing page's
// download buttons read it) and /changelog.json (the apps' update windows) sit
// beside it in the bucket, written by the Cascade repo's publish workflow on
// every release.
//
// Login is GitHub OAuth against ALLOWED_LOGINS (wrangler.toml), checked on
// every request, so taking a name off the list locks them out at once. A
// session is an HMAC-signed cookie on this host only. See NOTES.md for the
// secrets and the GitHub OAuth app.

import ADMIN_HTML from './admin.html'
import { stampAuthors, validateFeed } from './announcements.js'

const FEED_HOST = 'announcements.cascade.chaosinc.xyz'
const FEED_KEY = 'announcements.json'
const FEED_CACHE = 'public, max-age=300'
// Release data, by path. Unlike the feed, a missing file is a 404: the apps
// and pages that read it each have their own fallback.
const RELEASE_FILES = { '/releases.json': 'releases.json', '/changelog.json': 'changelog.json' }
const SESSION_COOKIE = 'cascade_session'
const STATE_COOKIE = 'cascade_oauth'
const SESSION_MS = 12 * 60 * 60 * 1000
const MAX_SAVE = 256 * 1024
const ADMIN_HOME = '/admin/announcements'
const ADMIN_CSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    const path = url.pathname
    if (url.hostname === FEED_HOST) return path === '/' || path === '/announcements.json' ? feed(request, env) : text(404, 'Not found')
    if (path === '/announcements.json') return feed(request, env)
    if (RELEASE_FILES[path]) return releaseFile(request, env, RELEASE_FILES[path])
    if (path === '/login') return login(url, env)
    if (path === '/login/callback') return callback(request, url, env)
    if (path === '/logout' && request.method === 'POST') return logout(url)
    if (path === '/admin' || path.startsWith('/admin/')) return admin(request, url, env)
    return env.ASSETS.fetch(request)
  },
}

// ── The feed

async function feed(request, env) {
  if (request.method !== 'GET' && request.method !== 'HEAD') return text(405, 'Method not allowed')
  // ponytail: an R2 read per request, well inside the free tier; put
  // caches.default in front if launches ever number in the millions.
  const obj = await env.FEED.get(FEED_KEY)
  return new Response(obj ? obj.body : '[]', {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': FEED_CACHE, 'Access-Control-Allow-Origin': '*' },
  })
}

async function releaseFile(request, env, key) {
  if (request.method !== 'GET' && request.method !== 'HEAD') return text(405, 'Method not allowed')
  const obj = await env.FEED.get(key)
  if (!obj) return text(404, 'Not found')
  return new Response(obj.body, {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': FEED_CACHE, 'Access-Control-Allow-Origin': '*' },
  })
}

// ── The panel

async function admin(request, url, env) {
  const who = await sessionLogin(request, env)
  if (url.pathname === ADMIN_HOME && request.method === 'GET') {
    if (!who) return redirect(`/login?next=${encodeURIComponent(ADMIN_HOME)}`)
    return new Response(ADMIN_HTML, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Content-Security-Policy': ADMIN_CSP } })
  }
  if (url.pathname === '/admin/announcements.json') {
    if (!who) return json(401, { error: 'Signed out. Reload to sign in again.' })
    if (request.method === 'GET') return json(200, { login: who, items: await readFeed(env) })
    if (request.method === 'PUT') return save(request, url, env, who)
    return json(405, { error: 'Method not allowed' })
  }
  if (url.pathname === '/admin' || url.pathname === '/admin/') return redirect(ADMIN_HOME)
  return text(404, 'Not found')
}

async function save(request, url, env, who) {
  // SameSite=Lax already keeps the cookie off a cross-site PUT; this backs it up.
  if (request.headers.get('Origin') !== url.origin) return json(403, { error: 'Saves only come from this page' })
  const body = await request.text()
  if (body.length > MAX_SAVE) return json(413, { error: 'Too big' })
  let raw
  try { raw = JSON.parse(body) } catch { return json(400, { error: 'Not JSON' }) }
  const result = validateFeed(raw)
  if (result.error) return json(400, result)
  // ponytail: last save wins. Fine for one or two maintainers; check the R2
  // etag (onlyIf) if two people ever edit at once.
  const items = stampAuthors(result.items, await readFeed(env), who)
  await env.FEED.put(FEED_KEY, JSON.stringify(items, null, 2) + '\n', {
    httpMetadata: { contentType: 'application/json', cacheControl: FEED_CACHE },
  })
  return json(200, { login: who, items })
}

async function readFeed(env) {
  const obj = await env.FEED.get(FEED_KEY)
  if (!obj) return []
  try { return await obj.json() } catch { return [] }
}

// ── GitHub login

function login(url, env) {
  const state = randomHex(16)
  const gh = new URL('https://github.com/login/oauth/authorize')
  // No scope: the public profile is all it reads, to learn the login.
  gh.search = new URLSearchParams({ client_id: env.GITHUB_CLIENT_ID, redirect_uri: `${url.origin}/login/callback`, state, allow_signup: 'false' })
  const next = safeNext(url.searchParams.get('next'))
  return redirect(gh.href, [cookie(STATE_COOKIE, `${state}.${encodeURIComponent(next)}`, { path: '/login', maxAge: 600 })])
}

async function callback(request, url, env) {
  const [state, next] = (readCookies(request)[STATE_COOKIE] ?? '').split('.')
  const clearState = cookie(STATE_COOKIE, '', { path: '/login', maxAge: 0 })
  if (!state || url.searchParams.get('state') !== state) return page(400, 'That sign-in expired. Try again.', [clearState])
  const code = url.searchParams.get('code')
  if (!code) return page(400, 'GitHub did not sign you in.', [clearState])

  const tokenRes = await fetch('https://github.com/login/oauth/access_token', {
    method: 'POST',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_id: env.GITHUB_CLIENT_ID, client_secret: env.GITHUB_CLIENT_SECRET, code, redirect_uri: `${url.origin}/login/callback` }),
  })
  const token = (await tokenRes.json().catch(() => ({}))).access_token
  if (typeof token !== 'string') return page(502, 'GitHub did not sign you in. Try again.', [clearState])
  const userRes = await fetch('https://api.github.com/user', {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'User-Agent': 'cascade-site' },
  })
  const who = userRes.ok ? (await userRes.json().catch(() => ({}))).login : null
  if (typeof who !== 'string') return page(502, 'Could not read your GitHub account. Try again.', [clearState])
  if (!allowed(env, who)) return page(403, `${who} is not a Cascade maintainer.`, [clearState])

  const session = await sign(env, JSON.stringify({ login: who, exp: Date.now() + SESSION_MS }))
  return redirect(safeNext(decodeURIComponent(next ?? '')), [clearState, cookie(SESSION_COOKIE, session, { path: '/', maxAge: SESSION_MS / 1000 })])
}

function logout(url) {
  return redirect(`${url.origin}/`, [cookie(SESSION_COOKIE, '', { path: '/', maxAge: 0 })])
}

const allowed = (env, who) => (env.ALLOWED_LOGINS ?? '').split(',').some(n => n.trim().toLowerCase() === who.toLowerCase())

// Only back into the panel, never off-site.
const safeNext = n => typeof n === 'string' && /^\/admin(\/[\w./-]*)?$/.test(n) && !n.includes('//') ? n : ADMIN_HOME

/** The signed-in login, or null. Also null once the login leaves the allowlist. */
async function sessionLogin(request, env) {
  const raw = readCookies(request)[SESSION_COOKIE]
  if (!raw || !env.SESSION_SECRET) return null
  const [body, sig] = raw.split('.')
  try {
    if (!body || !sig || !await crypto.subtle.verify('HMAC', await hmacKey(env), fromB64(sig), new TextEncoder().encode(body))) return null
    const p = JSON.parse(new TextDecoder().decode(fromB64(body)))
    return typeof p.login === 'string' && p.exp > Date.now() && allowed(env, p.login) ? p.login : null
  } catch {
    return null
  }
}

/** base64url(payload).base64url(HMAC-SHA256 of that). */
async function sign(env, payload) {
  const body = toB64(new TextEncoder().encode(payload))
  const sig = await crypto.subtle.sign('HMAC', await hmacKey(env), new TextEncoder().encode(body))
  return `${body}.${toB64(new Uint8Array(sig))}`
}

const hmacKey = env => crypto.subtle.importKey('raw', new TextEncoder().encode(env.SESSION_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify'])
const toB64 = bytes => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const fromB64 = s => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0))
const randomHex = n => [...crypto.getRandomValues(new Uint8Array(n))].map(b => b.toString(16).padStart(2, '0')).join('')

// ── Responses

function readCookies(request) {
  const out = {}
  for (const part of (request.headers.get('Cookie') ?? '').split(';')) {
    const i = part.indexOf('=')
    if (i > 0) out[part.slice(0, i).trim()] = part.slice(i + 1).trim()
  }
  return out
}

const cookie = (name, value, { path, maxAge }) => `${name}=${value}; Path=${path}; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Lax`

function redirect(location, cookies = []) {
  const headers = new Headers({ Location: location, 'Cache-Control': 'no-store' })
  for (const c of cookies) headers.append('Set-Cookie', c)
  return new Response(null, { status: 302, headers })
}

const json = (status, body) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } })
const text = (status, body) => new Response(body, { status, headers: { 'Content-Type': 'text/plain; charset=utf-8' } })

function page(status, message, cookies = []) {
  const esc = message.replace(/[&<>"']/g, c => `&#${c.charCodeAt(0)};`)
  const headers = new Headers({ 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Content-Security-Policy': ADMIN_CSP })
  for (const c of cookies) headers.append('Set-Cookie', c)
  return new Response(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Cascade</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 16px;color:#1d1d1f;background:#fff}a{color:#0a66d8}@media (prefers-color-scheme:dark){body{color:#f2f2f7;background:#111}a{color:#5aa4ff}}</style>
<p>${esc}</p><p><a href="/login">Sign in again</a> or <a href="/">go home</a>.</p>`, { status, headers })
}
