// What a Jellyfin server says to people, outside of playback:
// - a message an admin sends a session from the dashboard (Dashboard >
//   Devices or Activity > Send message), which reaches a client as the
//   DisplayMessage general command over the socket, and
// - the login disclaimer an admin sets in Dashboard > General > Branding,
//   which Jellyfin's own sign-in page shows under the form.
// Both are text from the server, shown as plain text only.

export interface ServerMessage {
  header: string
  text: string
  /** How long to show it, in ms, when the sender set one; otherwise until closed. */
  timeoutMs: number | null
}

const MAX_HEADER = 120
const MAX_TEXT = 2000

const clean = (v: unknown, max: number): string =>
  typeof v === 'string' ? v.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').trim().slice(0, max) : ''

/** A DisplayMessage command's arguments (strings, as every general command's
 *  are), or null when there is nothing to show. */
export function parseDisplayMessage(args: unknown): ServerMessage | null {
  const a = args && typeof args === 'object' ? args as Record<string, unknown> : {}
  const header = clean(a.Header, MAX_HEADER)
  const text = clean(a.Text, MAX_TEXT)
  if (!header && !text) return null
  const ms = Number(a.TimeoutMs)
  return { header: header || 'Message from your server', text, timeoutMs: Number.isFinite(ms) && ms > 0 ? Math.min(ms, 600_000) : null }
}

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' }

/** The Branding LoginDisclaimer as plain text. Jellyfin allows HTML there;
 *  line breaks are kept, tags dropped, the common entities decoded. */
export function loginDisclaimerText(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  return raw
    .replace(/<\s*br\s*\/?>/gi, '\n')
    .replace(/<\/\s*(p|div|li|h[1-6])\s*>/gi, '\n')
    .replace(/<[^>]*>/g, '')
    .replace(/&(#\d+|#x[0-9a-f]+|[a-z]+);/gi, (m, e: string) => {
      if (e[0] === '#') {
        const n = e[1].toLowerCase() === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)
        return Number.isFinite(n) && n > 31 && n < 0x110000 ? String.fromCodePoint(n) : ''
      }
      return ENTITIES[e.toLowerCase()] ?? m
    })
    .split('\n').map(l => l.replace(/[ \t]+/g, ' ').trim()).join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
    .slice(0, MAX_TEXT)
}

/** The server's login disclaimer as plain text, or '' for none or no answer.
 *  /Branding/Configuration needs no sign-in, which is the point: it is shown
 *  before anyone has one. Asked through the main process's fetch, so the
 *  reverse proxy headers apply as for every other request. */
export async function fetchLoginDisclaimer(url: string, fetchImpl: typeof fetch = fetch): Promise<string> {
  try {
    const r = await fetchImpl(`${url}/Branding/Configuration`, { signal: AbortSignal.timeout(6000) })
    if (!r.ok) return ''
    return loginDisclaimerText((await r.json())?.LoginDisclaimer)
  } catch {
    return ''
  }
}
