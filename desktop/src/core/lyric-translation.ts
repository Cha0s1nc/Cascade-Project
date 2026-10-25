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

// ── Latin-script sheets: which words the translator changed ─────────────────
// Short Latin words cannot be told apart from English one by one ("me", "no",
// "a"), but the translator can: given a line, it passes English through and
// changes the rest. So a Latin-script line is translated whole, and the result
// is compared word by word with the original. Mostly passed through: the line
// is English with a foreign phrase or two, and each changed stretch gets the
// English it became, under it. Mostly changed: the line is foreign, and its
// translation is shown row by row under the line's rows (splitForRows).

export interface Gloss {
  /** The source characters [from, to) this English goes under. */
  from: number
  to: number
  text: string
}

export type LatinView =
  | { mode: 'none' }
  | { mode: 'glosses'; glosses: Gloss[] }
  | { mode: 'rows' }

interface Token { norm: string; start: number; end: number }

/** Words, with where they are. Apostrophes inside a word stay in it ("vo'",
 *  "don't"); everything else splits. */
export function wordTokens(text: string): Token[] {
  const out: Token[] = []
  for (const m of text.matchAll(/[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]*)*/gu)) {
    out.push({ norm: m[0].toLowerCase().replace(/’/g, "'"), start: m.index, end: m.index + m[0].length })
  }
  return out
}

/** The same English word, give or take an ending the translator likes to fix
 *  ("mess" and "messes", "love" and "loved"). */
function sameWord(a: string, b: string): boolean {
  if (a === b) return true
  const [short, long] = a.length <= b.length ? [a, b] : [b, a]
  return long.startsWith(short) && /^(?:s|es|d|ed|ing|'s)$/.test(long.slice(short.length))
}

/** Pairs of matched token indexes, in order (a longest common subsequence). */
function matchTokens(a: Token[], b: Token[]): Array<[number, number]> {
  const n = a.length, m = b.length
  const len: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      len[i]![j] = sameWord(a[i]!.norm, b[j]!.norm) ? len[i + 1]![j + 1]! + 1 : Math.max(len[i + 1]![j]!, len[i]![j + 1]!)
    }
  }
  const pairs: Array<[number, number]> = []
  for (let i = 0, j = 0; i < n && j < m;) {
    if (sameWord(a[i]!.norm, b[j]!.norm)) { pairs.push([i, j]); i++; j++ }
    else if (len[i + 1]![j]! >= len[i]![j + 1]!) i++
    else j++
  }
  return pairs
}

/** How a Latin-script line and its English relate; see the note above. */
export function latinView(source: string, english: string): LatinView {
  const a = wordTokens(source), b = wordTokens(english)
  if (!a.length || !b.length) return { mode: 'none' }
  const pairs = matchTokens(a, b)
  if (pairs.length === a.length) return { mode: 'none' }
  if (pairs.length / a.length < 0.5) return { mode: 'rows' }
  // Each stretch between matched words, on both sides.
  const glosses: Gloss[] = []
  const anchors: Array<[number, number]> = [[-1, -1], ...pairs, [a.length, b.length]]
  for (let k = 0; k + 1 < anchors.length; k++) {
    const [i0, j0] = anchors[k]!, [i1, j1] = anchors[k + 1]!
    if (i1 - i0 > 1 && j1 - j0 > 1) {
      glosses.push({ from: a[i0 + 1]!.start, to: a[i1 - 1]!.end, text: english.slice(b[j0 + 1]!.start, b[j1 - 1]!.end) })
    }
  }
  return glosses.length ? { mode: 'glosses', glosses } : { mode: 'none' }
}

/**
 * `english` cut into one piece per row of the source line, at word breaks, in
 * proportion to how much of the line each row holds (`shares`, summing to 1).
 * Close for languages with English's word order (Spanish, French, Portuguese);
 * not a word-for-word alignment, which neither translation engine reports.
 */
export function splitForRows(english: string, shares: number[]): string[] {
  const words = english.trim().split(/\s+/).filter(Boolean)
  if (shares.length <= 1 || words.length <= 1) return [words.join(' ')]
  const total = words.reduce((n, w) => n + w.length + 1, -1)
  const out: string[] = []
  let w = 0, used = 0, share = 0
  for (let r = 0; r < shares.length; r++) {
    share += shares[r]!
    const goal = r === shares.length - 1 ? Infinity : share * total
    const row: string[] = []
    // Take words while the row's end is nearer the goal with the word than without.
    while (w < words.length) {
      const next = used + (used ? 1 : 0) + words[w]!.length
      if (row.length && Math.abs(next - goal) > Math.abs(used - goal)) break
      // Leave at least one word for every row still to come.
      if (row.length && words.length - w <= shares.length - 1 - r) break
      row.push(words[w]!)
      used = next
      w++
    }
    out.push(row.join(' '))
  }
  return out
}
