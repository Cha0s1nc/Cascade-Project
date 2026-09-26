// Lyric translations kept on disk between sessions. Pure, no I/O: main.js
// reads and writes the file, renderer.js holds the live map.
//
// An entry is [cacheKey, english, translatedAtMs]. cacheKey is renderer.js's
// "engine|model|line". Entries expire 25 days after they were translated, the
// same limit the Cascade Server plugin keeps SpicyLyrics lyrics under: a
// translation is derived from the lyric text, so it is held no longer.
// Reading an entry does not extend it.

export type TranslationCacheEntry = [key: string, text: string, at: number]

export const TRANSLATION_CACHE_TTL_MS = 25 * 24 * 60 * 60 * 1000
export const TRANSLATION_CACHE_MAX = 5000

export function translationExpired(at: number, now: number): boolean {
  return !(now - at < TRANSLATION_CACHE_TTL_MS) || at > now + 60_000
}

/**
 * Cleans entries read from disk (untrusted: hand-edited or from an older
 * build): drops malformed and expired ones, keeps the newest `max` in their
 * original order (oldest first, as the renderer's LRU map wants them).
 */
export function liveTranslationEntries(raw: unknown, now: number, max = TRANSLATION_CACHE_MAX): TranslationCacheEntry[] {
  if (!Array.isArray(raw)) return []
  const ok = raw.filter((e): e is TranslationCacheEntry =>
    Array.isArray(e) && e.length === 3 &&
    typeof e[0] === 'string' && e[0].length > 0 && e[0].length <= 4000 &&
    typeof e[1] === 'string' && e[1].length <= 4000 &&
    typeof e[2] === 'number' && Number.isFinite(e[2]) &&
    !translationExpired(e[2], now))
  return ok.slice(-max)
}
