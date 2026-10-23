// What to translate in each lyric line of a sheet in a non-Latin-script
// language that mixes in English (J-pop, K-pop, a Russian verse in an English
// song). Translating every line sent English lines through a Japanese-to-English
// model, which handed them back reworded or garbled under the original.
//
// The script marks the foreign text exactly, so per line:
//   skip  no foreign-script letters: nothing to translate.
//   line  mostly foreign, or foreign in several places: the whole line, shown
//         under it as before.
//   run   mostly English with one foreign phrase: just that phrase, shown under
//         the phrase itself.
//
// Latin-script languages (Spanish, French) get `line` everywhere: short Latin
// words are too ambiguous to tell apart from English one by one.

export type LinePlan =
  | { mode: 'skip' }
  | { mode: 'line'; text: string }
  | { mode: 'run'; text: string }

/** Letters of a script English is never written in. */
const FOREIGN = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}\p{Script=Hangul}\p{Script=Cyrillic}\p{Script=Arabic}\p{Script=Hebrew}\p{Script=Greek}\p{Script=Thai}\p{Script=Devanagari}]/u
/** Scripts with no spaces between words, or syllable blocks: one character
 *  carries about as much as a couple of English letters. */
const DENSE = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}\p{Script=Hangul}]/u
const LATIN = /\p{Script=Latin}/u
/** Marks that belong to a foreign phrase without being letters of its script:
 *  the long-vowel mark, the iteration mark, wave dash and middle dot. */
const JOINER = /[ー々〜・]/u

/** Languages written in a non-Latin script, by ISO 639-1 base. */
const NON_LATIN_LANGS = new Set(['ja', 'zh', 'ko', 'ru', 'uk', 'be', 'bg', 'sr', 'mk', 'ar', 'fa', 'he', 'el', 'th', 'hi'])

/** Whether `lang` (a translation key such as 'ja' or 'zh-Hans') is written in
 *  a non-Latin script, which is what makes per-line planning possible. */
export function isNonLatinLanguage(lang: string | null | undefined): boolean {
  return !!lang && NON_LATIN_LANGS.has(lang.slice(0, 2).toLowerCase())
}

/**
 * The foreign phrases in `text`: each a maximal stretch that starts and ends on
 * a foreign letter (or joiner) and has no Latin letter in it. Spaces and
 * punctuation inside count as part of the phrase ("사랑해 너를", "君の、せい").
 */
export function foreignRuns(text: string): string[] {
  const chars = [...text]
  const runs: string[] = []
  let start = -1, last = -1
  const close = () => { if (start >= 0) runs.push(chars.slice(start, last + 1).join('')); start = last = -1 }
  chars.forEach((c, i) => {
    if (FOREIGN.test(c) || (start >= 0 && JOINER.test(c))) {
      if (start < 0) start = i
      last = i
    } else if (LATIN.test(c)) {
      close()
    }
  })
  close()
  return runs
}

/** How much of a line is foreign, 0 to 1, weighing a dense-script character
 *  as two Latin letters. */
export function foreignShare(text: string): number {
  let foreign = 0, latin = 0
  for (const c of text) {
    if (FOREIGN.test(c)) foreign += DENSE.test(c) ? 2 : 1
    else if (LATIN.test(c)) latin++
  }
  return foreign + latin ? foreign / (foreign + latin) : 0
}

/** One line's plan; `lang` is the sheet's translation language. */
export function planLine(text: string, lang: string | null | undefined): LinePlan {
  const clean = text.trim()
  if (!clean) return { mode: 'skip' }
  if (!isNonLatinLanguage(lang)) return { mode: 'line', text: clean }
  const runs = foreignRuns(clean)
  if (!runs.length) return { mode: 'skip' }
  if (runs.length === 1 && foreignShare(clean) < 0.5) return { mode: 'run', text: runs[0] as string }
  return { mode: 'line', text: clean }
}

/** Every line's plan, for a whole sheet. */
export function planSheet(lines: string[], lang: string | null | undefined): LinePlan[] {
  return lines.map(l => planLine(l, lang))
}
