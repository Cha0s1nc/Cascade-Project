// Extra HTTP headers and client certificates for a Jellyfin server that sits
// behind a reverse proxy (Cloudflare Access service tokens, Authelia, mTLS).
// The proxy rejects any request without the header or certificate, so without
// this the app cannot even reach the sign-in.
//
// Everything here is pure. main.js applies it in onBeforeSendHeaders (the only
// place that also covers <img>, <audio> and <video> requests, which a fetch
// wrapper cannot reach) and in select-client-certificate.

export interface CustomHeader { name: string; value: string }

/** More than this is a typo or paste accident, not a proxy's requirements. */
export const MAX_CUSTOM_HEADERS = 16
export const MAX_HEADER_VALUE_LENGTH = 4096

/**
 * Names a user may not set: they would break the request framing or replace
 * Cascade's own sign-in. Lowercase. X-Emby-Authorization is Jellyfin's older
 * spelling of Authorization, so it is held to the same rule.
 */
export const BLOCKED_HEADER_NAMES: ReadonlySet<string> = new Set([
  'authorization', 'x-emby-authorization', 'host', 'content-length', 'transfer-encoding',
])

// RFC 9110 token characters.
const TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

/** Why `name` cannot be a header name, or null when it can. */
export function headerNameProblem(name: unknown): string | null {
  if (typeof name !== 'string' || !name) return 'A header needs a name.'
  if (!TOKEN.test(name)) return `"${name.slice(0, 40)}" is not a valid header name.`
  if (BLOCKED_HEADER_NAMES.has(name.toLowerCase())) return `${name} cannot be overridden.`
  return null
}

/** Why `value` cannot be a header value, or null when it can. */
export function headerValueProblem(value: unknown): string | null {
  if (typeof value !== 'string' || !value) return 'A header needs a value.'
  if (value.length > MAX_HEADER_VALUE_LENGTH) return 'That header value is too long.'
  // A line break would let a value smuggle in a second header.
  if (/[\u0000-\u0008\u000a-\u001f\u007f]/.test(value)) return 'A header value cannot contain control characters.'
  return null
}

/**
 * The text a person types, one `Name: Value` per line, into headers. Blank
 * lines and lines starting with # are skipped. Returns every problem, with its
 * line, rather than stopping at the first, so one pass fixes the lot.
 */
export function parseHeaderLines(text: string): { headers: CustomHeader[]; errors: string[] } {
  const headers: CustomHeader[] = []
  const errors: string[] = []
  const seen = new Set<string>()
  const lines = String(text ?? '').split(/\r?\n/)
  lines.forEach((raw, i) => {
    const line = raw.trim()
    if (!line || line.startsWith('#')) return
    const at = line.indexOf(':')
    if (at < 0) { errors.push(`Line ${i + 1}: use Name: Value.`); return }
    const name = line.slice(0, at).trim()
    const value = line.slice(at + 1).trim()
    const problem = headerNameProblem(name) ?? headerValueProblem(value)
    if (problem) { errors.push(`Line ${i + 1}: ${problem}`); return }
    if (seen.has(name.toLowerCase())) { errors.push(`Line ${i + 1}: ${name} is listed twice.`); return }
    seen.add(name.toLowerCase())
    headers.push({ name, value })
  })
  if (headers.length > MAX_CUSTOM_HEADERS) {
    errors.push(`At most ${MAX_CUSTOM_HEADERS} headers.`)
    headers.length = MAX_CUSTOM_HEADERS
  }
  return { headers, errors }
}

/** The inverse of parseHeaderLines, for filling the field. */
export function formatHeaderLines(headers: readonly CustomHeader[]): string {
  return headers.map(h => `${h.name}: ${h.value}`).join('\n')
}

/**
 * Headers from the store or over IPC, which are untrusted: anything invalid,
 * duplicated or past the cap is dropped, never repaired.
 */
export function sanitizeCustomHeaders(raw: unknown): CustomHeader[] {
  if (!Array.isArray(raw)) return []
  const out: CustomHeader[] = []
  const seen = new Set<string>()
  for (const h of raw) {
    const name = h?.name
    const value = h?.value
    if (headerNameProblem(name) || headerValueProblem(value)) continue
    const key = (name as string).toLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    out.push({ name: name as string, value: value as string })
    if (out.length >= MAX_CUSTOM_HEADERS) break
  }
  return out
}

/**
 * scheme://host:port with the default port left off, and a WebSocket treated
 * as the HTTP it upgrades from (the remote-control socket goes to the same
 * server). Null for anything that is not an http(s) or ws(s) URL.
 */
export function requestOrigin(url: unknown): string | null {
  if (typeof url !== 'string') return null
  let u: URL
  try { u = new URL(url) } catch { return null }
  const scheme = u.protocol === 'ws:' ? 'http:' : u.protocol === 'wss:' ? 'https:' : u.protocol
  if (scheme !== 'http:' && scheme !== 'https:') return null
  const port = u.port && !((scheme === 'http:' && u.port === '80') || (scheme === 'https:' && u.port === '443')) ? `:${u.port}` : ''
  return `${scheme}//${u.hostname}${port}`
}

/**
 * The headers to add to a request to `requestUrl`: all of them when it goes to
 * the Jellyfin server's own origin, none for any other host (lyrics providers,
 * GitHub, Mozilla, the Waterfall relay). A server path (https://host/jellyfin)
 * does not matter: the proxy answers for the whole origin.
 */
export function headersForRequest(requestUrl: string, serverUrl: string | null | undefined, headers: readonly CustomHeader[]): CustomHeader[] {
  if (!headers.length || !serverUrl) return []
  const target = requestOrigin(requestUrl)
  const server = requestOrigin(serverUrl)
  return target && server && target === server ? [...headers] : []
}

/** `existing` with `extra` set on it. A header already present under any
 *  capitalization is replaced, not duplicated. Returns a new object. */
export function withCustomHeaders(
  existing: Record<string, string | string[]>,
  extra: readonly CustomHeader[],
): Record<string, string | string[]> {
  const out: Record<string, string | string[]> = { ...existing }
  for (const h of extra) {
    for (const key of Object.keys(out)) if (key.toLowerCase() === h.name.toLowerCase()) delete out[key]
    out[h.name] = h.value
  }
  return out
}

/** The slice of Electron's Certificate this module reads. */
export interface ClientCertificate { fingerprint: string; subjectName: string; issuerName: string; validExpiry?: number }

export type CertificateChoice =
  | { kind: 'use'; index: number }
  | { kind: 'ask'; candidates: number[] }
  | { kind: 'none' }

/**
 * Which certificate to answer a server's request with. `index` always refers
 * to the list as given. An expired certificate is never offered (the server
 * would refuse it and the person would see a blank failure). A remembered
 * choice wins while it is still in the list; a single candidate needs no
 * question; several need one.
 */
export function chooseClientCertificate(
  certs: readonly ClientCertificate[],
  savedFingerprint: string | null | undefined,
  nowSec: number,
): CertificateChoice {
  const live: number[] = []
  certs.forEach((c, i) => {
    if (typeof c?.validExpiry === 'number' && c.validExpiry < nowSec) return
    live.push(i)
  })
  if (!live.length) return { kind: 'none' }
  if (savedFingerprint) {
    const saved = live.find(i => certs[i].fingerprint === savedFingerprint)
    if (saved !== undefined) return { kind: 'use', index: saved }
  }
  if (live.length === 1) return { kind: 'use', index: live[0] }
  return { kind: 'ask', candidates: live }
}
