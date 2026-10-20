// Which language is this lyric in? Answered on-device.
//
// This used to be a fetch to api.mymemory.translated.net, fired automatically
// on every track that had lyrics - no click, no consent, no setting. That sent
// a line of whatever the user was playing to a third party just to ask "is this
// English?", which is a listening-history leak dressed up as a language check.
//
// franc is trigram frequency matching. It ships its own tables, touches no
// network, and answers in under a millisecond.

import { franc } from 'franc-min'

/** franc speaks ISO 639-3; the lyrics picker, the Marian target tokens and
 *  Apple's Translation framework speak ISO 639-1. Only the languages the UI can
 *  act on are mapped (every language Apple Translation takes, which covers
 *  Cascade's own models too) - for everything else the caller only needs "not
 *  English", and an unmapped code answers that just as well. */
const ISO3_TO_ISO1: Record<string, string> = {
  eng: 'en', spa: 'es', fra: 'fr', deu: 'de', jpn: 'ja', kor: 'ko',
  cmn: 'zh', por: 'pt', ita: 'it', rus: 'ru', arb: 'ar', hin: 'hi',
  ind: 'id', nld: 'nl', pol: 'pl', tha: 'th', tur: 'tr', ukr: 'uk', vie: 'vi',
}

/** Below this, trigram matching is guessing. A two-word line is not enough to
 *  separate English from Dutch, so callers should hand in several joined lines
 *  rather than the first one. */
const MIN_CHARS = 24

/**
 * Best-guess language of `text`, as ISO 639-1 where known, else the raw ISO
 * 639-3, else '' when there is not enough signal to say.
 *
 * '' means "no idea", never "English" - the callers below treat those
 * differently and collapsing them would put a translate button on every
 * instrumental interlude.
 */
export function detectLanguage(text: string): string {
  const clean = text.replace(/\s+/g, ' ').trim()
  if (clean.length < MIN_CHARS) return ''
  const iso3 = franc(clean, { minLength: MIN_CHARS })
  if (iso3 === 'und') return ''
  return ISO3_TO_ISO1[iso3] ?? iso3
}

// Scripts English is never written in. A line with a few of these letters is
// a line in another language, however much English surrounds it.
const NON_LATIN = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}\p{Script=Hangul}\p{Script=Cyrillic}\p{Script=Arabic}\p{Script=Hebrew}\p{Script=Greek}\p{Script=Thai}\p{Script=Devanagari}]/gu

/**
 * The text to detect a sheet's language from: the lines in a non-Latin script
 * when there are enough of them to matter, else the whole sheet.
 *
 * Detecting over the whole sheet let a mostly English song with Japanese
 * verses (UN-APEX, TV edit) come back as English and never offer a
 * translation. Counting lines rather than letters keeps one stray kanji in a
 * credit from flipping an English song.
 *
 * ponytail: Latin-script languages mixed into English (Spanish verses in an
 * English chorus) still go by the whole sheet; per-line trigram guesses on
 * short Latin lines call English lines Scots or Dutch. Vote per stanza if
 * those start slipping through.
 */
export function sheetSample(lines: string[]): string {
  const filled = lines.map(l => l.trim()).filter(Boolean)
  const foreign = filled.filter(l => (l.match(NON_LATIN)?.length ?? 0) >= 2)
  const text = foreign.length >= Math.max(2, filled.length * 0.15) ? foreign : filled
  return text.join(' ').slice(0, 1000)
}

/**
 * Whether to offer translation for these lyric lines.
 *
 * Takes the whole sheet rather than one line on purpose: a Spanish song opening
 * on an English title line used to be detected as English off `lines[0]` and
 * never offered a translation at all.
 */
export function shouldOfferTranslation(lines: string[]): boolean {
  const lang = detectLanguage(sheetSample(lines))
  return lang !== '' && lang !== 'en'
}
