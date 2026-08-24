// Whether the CascadeSLRC Jellyfin plugin is installed on the connected
// server. Cascade depends on it for server-only lyrics mode, the lyrics
// editor, and the cascade-* lyric source options - all of which need to be
// disabled cleanly on a server that never had it, instead of failing per
// track. The actual probe request lives in renderer.js; this is just the
// small, easy-to-invert part - reading the HTTP status it got back.

export type CascadePluginProbe = 'present' | 'absent' | 'unknown'

/**
 * Interprets the status from probing
 * GET {server}/Audio/not-a-guid/CascadeLyrics with a normal auth header.
 *
 * This relies on the plugin's controller being declared
 *   [ApiController]
 *   [Route("Audio/{itemId}/CascadeLyrics")]
 *   public IActionResult GetLyrics([FromRoute] Guid itemId)
 * with [Authorize] (any signed-in user) and, importantly, NO `:guid` route
 * constraint on itemId.
 *
 * - 400: the route matched and auth passed, then ASP.NET's [ApiController]
 *   rejected "not-a-guid" while binding it to a Guid. Only happens if the
 *   plugin's controller is actually there - present.
 * - 404: no route matched at all, so Jellyfin's own router 404'd before the
 *   plugin ever got a say - absent.
 * - anything else (401, a 5xx, or no status at all because the request
 *   threw) didn't actually answer the question - unknown. Callers should
 *   treat unknown the same as present, so a network hiccup never disables a
 *   feature that actually works.
 *
 * If that route ever gains a `:guid` constraint, "not-a-guid" would 404
 * before reaching [Authorize] or the action, and every server with the
 * plugin installed would read as absent. Do not add one.
 */
export function interpretCascadePluginProbe(status: number | null): CascadePluginProbe {
  if (status === 400) return 'present'
  if (status === 404) return 'absent'
  return 'unknown'
}
