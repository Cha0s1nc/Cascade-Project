// Whether the Cascade Server Jellyfin plugin is installed on the connected
// server. Cascade depends on it for server-only lyrics mode, the lyrics
// editor, and the cascade-* lyric source options - all of which need to be
// disabled cleanly on a server that never had it, instead of failing per
// track. The actual probe request lives in renderer.js; this is just the
// small, easy-to-invert part - reading the HTTP status it got back.
//
// The plugin was called Cascade Lyrics before 2.0.0.0. Its routes moved from
// CascadeLyrics/* and Audio/{id}/CascadeLyrics to CascadeServer/*, and a
// server can still be running the old build, so the probe tries the new
// route first and falls back to the old one.

export type CascadePluginProbe = 'present' | 'absent' | 'unknown'

/** Which route family the plugin answered on: 'server' is 2.0.0.0 and up. */
export type CascadePluginApi = 'server' | 'legacy'

/**
 * Interprets the status from probing GET {server}/CascadeServer/Info (or the
 * old CascadeLyrics/Info) with a normal auth header. That route exists only to
 * answer this question, so reaching it at all is the answer and the body is
 * not needed here.
 *
 * - 200: the plugin is there and said so.
 * - 404: no such route, so no plugin.
 * - anything else (401, a 5xx, or no status at all because the request threw)
 *   did not actually answer - unknown. Callers should treat unknown the same
 *   as present, so a network hiccup never disables a feature that works.
 */
export function interpretCascadePluginProbe(status: number | null): CascadePluginProbe {
  if (status === 200) return 'present'
  if (status === 404) return 'absent'
  return 'unknown'
}

/**
 * Combines the new-route probe with the old-route probe. `legacyStatus` is
 * only meaningful when the new route said 404; the caller skips that request
 * otherwise and passes null.
 *
 * The api is 'legacy' only when the old route is the one that could answer:
 * an unknown on the new route says nothing about which build is there, so it
 * stays on the current routes.
 */
export function resolveCascadePluginProbe(
  serverStatus: number | null,
  legacyStatus: number | null,
): { probe: CascadePluginProbe; api: CascadePluginApi } {
  const first = interpretCascadePluginProbe(serverStatus)
  if (first !== 'absent') return { probe: first, api: 'server' }
  return { probe: interpretCascadePluginProbe(legacyStatus), api: 'legacy' }
}

/** Path (no leading slash) of the plugin's lyrics GET/POST route for an item. */
export function cascadeLyricsPath(api: CascadePluginApi, itemId: string): string {
  return api === 'legacy' ? `Audio/${itemId}/CascadeLyrics` : `CascadeServer/Lyrics/${itemId}`
}
