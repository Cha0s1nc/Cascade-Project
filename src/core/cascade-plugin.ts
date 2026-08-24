// Whether the CascadeSLRC Jellyfin plugin is installed on the connected
// server. Cascade depends on it for server-only lyrics mode, the lyrics
// editor, and the cascade-* lyric source options - all of which need to be
// disabled cleanly on a server that never had it, instead of failing per
// track. The actual probe request lives in renderer.js; this is just the
// small, easy-to-invert part - reading the HTTP status it got back.

export type CascadePluginProbe = 'present' | 'absent' | 'unknown'

/**
 * Interprets the status from probing GET {server}/CascadeLyrics/Info with a
 * normal auth header. That route exists only to answer this question, so
 * reaching it at all is the answer and the body is not needed here.
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
