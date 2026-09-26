// Which language a lyric sheet would be translated from, and by what.
//
// Two engines. Mozilla's Firefox Translations models (Marian, via the bergamot
// WASM runtime) are Cascade's own: one source language into English each,
// downloaded on first use, five languages - see translation-models.json and
// main.js. Apple's Translation framework (macOS 26+) is the other, and on this
// Mac's OS it covers far more languages on-device than System Settings lists.
// A sheet gets a Translate button when either engine can take its language.

import { detectLanguage } from './language.ts'

export type TranslationModelKey = 'ja' | 'ko' | 'zh-Hans' | 'zh-Hant' | 'es'

/** Languages Cascade has its own (Mozilla) model for. */
export const TRANSLATION_MODEL_KEYS: readonly TranslationModelKey[] = ['ja', 'ko', 'zh-Hans', 'zh-Hant', 'es']

/**
 * Languages Cascade asks Apple's Translation framework about, as the codes it
 * takes. Only what to ask: macOS's answer per Mac (installed, supported,
 * unsupported) decides what is actually offered. These are the languages
 * Apple Translation handles into English on macOS 26+.
 */
export const APPLE_TRANSLATION_KEYS: readonly string[] = [
  'ar', 'de', 'es', 'fr', 'hi', 'id', 'it', 'ja', 'ko', 'nl',
  'pl', 'pt', 'ru', 'th', 'tr', 'uk', 'vi', 'zh-Hans', 'zh-Hant',
]

export const isModelKey = (key: string): key is TranslationModelKey =>
  (TRANSLATION_MODEL_KEYS as readonly string[]).includes(key)

// Common characters written differently in the two Chinese scripts, paired by
// position. franc answers "Chinese" for both, and Mozilla ships a separate
// model for each, so this picks between them by counting which spelling the
// text uses. Deliberately only characters that are unambiguous: pairs where the
// simplified form is also an ordinary traditional character in its own right
// (后, 里, 几, 么, 干, 系, 并 ...) are left out, or they would pull traditional
// text toward simplified.
// ponytail: a frequency heuristic, not a converter. A misjudged sheet still
// translates, through the other script's model and somewhat less well.
const SIMPLIFIED  = '们这个来时说会对爱让过还没为发边见听话难远梦离开关长风声忆红泪丽样从头动无与东车飞云灯岁记恋断线问间门场请谁该认识读语写买卖钱儿学实气热应经结给终当两吗伤亲轻转运进选连视觉观现谢严权赋'
const TRADITIONAL = '們這個來時說會對愛讓過還沒為發邊見聽話難遠夢離開關長風聲憶紅淚麗樣從頭動無與東車飛雲燈歲記戀斷線問間門場請誰該認識讀語寫買賣錢兒學實氣熱應經結給終當兩嗎傷親輕轉運進選連視覺觀現謝嚴權賦'

export function chineseScript(text: string): 'zh-Hans' | 'zh-Hant' {
  let simplified = 0
  let traditional = 0
  for (const ch of text) {
    if (SIMPLIFIED.includes(ch)) simplified++
    else if (TRADITIONAL.includes(ch)) traditional++
  }
  // A tie, including no evidence either way, goes to Simplified: far more
  // lyrics are published in it.
  return traditional > simplified ? 'zh-Hant' : 'zh-Hans'
}

/** Exposed for the test that keeps the two tables aligned. */
export const SCRIPT_PAIRS = { SIMPLIFIED, TRADITIONAL }

// Letters only one of the two languages uses. Trigram matching mixes Russian
// and Ukrainian up on short text (a Russian line came back as Ukrainian), and
// the source language is what Apple translates from, so these settle it.
const UKRAINIAN_ONLY = 'іїєґІЇЄҐ'
const RUSSIAN_ONLY = 'ыэъёЫЭЪЁ'

/** 'ru' or 'uk' by their distinctive letters, or null with no evidence either way. */
export function cyrillicLanguage(text: string): 'ru' | 'uk' | null {
  let uk = 0
  let ru = 0
  for (const ch of text) {
    if (UKRAINIAN_ONLY.includes(ch)) uk++
    else if (RUSSIAN_ONLY.includes(ch)) ru++
  }
  return uk > ru ? 'uk' : ru > uk ? 'ru' : null
}

/**
 * The language a sheet would be translated from, or null when neither engine
 * could take it. Takes the whole sheet for the same reason
 * shouldOfferTranslation does: a Japanese song opening on an English title
 * line must still read as Japanese. Whether Apple can actually take it on this
 * Mac is pickTranslationEngine's call, not this one's.
 */
export function translationLanguageFor(lines: string[]): string | null {
  const text = lines.join(' ').slice(0, 1000)
  const lang = detectLanguage(text)
  if (lang === 'zh') return chineseScript(text)
  const key = lang === 'ru' || lang === 'uk' ? cyrillicLanguage(text) ?? lang : lang
  return isModelKey(key) || APPLE_TRANSLATION_KEYS.includes(key) ? key : null
}

/** What Apple's Translation framework says about one language into English. */
export type AppleLanguageStatus = 'installed' | 'supported' | 'unsupported'

/** 'needs-install': Apple could translate this once the language is installed
 *  in macOS, and the user has not chosen Mozilla's model for it instead.
 *  'none': nothing on this Mac can translate it, so there is no button. */
export type TranslationEngine = 'apple' | 'mozilla' | 'needs-install' | 'none'

/**
 * Which engine translates a sheet, or 'none' when nothing here can.
 *
 * `appleEnabled` is the setting AND this Mac being able to use it (macOS 26+
 * with the helper built). `appleStatus` is undefined whenever Apple is not in
 * play. `hasModel` is Cascade having its own model for the language (one of
 * the five); without one, Apple is the only way. `mozillaChosen` is the user
 * having picked Mozilla's model for this language from the install prompt; it
 * only ever matters while the language is not installed in macOS, so
 * installing it later switches back to Apple with no setting to undo.
 */
export function pickTranslationEngine(o: {
  appleEnabled: boolean
  appleStatus?: AppleLanguageStatus
  hasModel: boolean
  mozillaChosen: boolean
}): TranslationEngine {
  const fallback = o.hasModel ? 'mozilla' : 'none'
  if (!o.appleEnabled || !o.appleStatus) return fallback
  if (o.appleStatus === 'installed') return 'apple'
  // Nothing to install: Apple has no model for this language at all, so
  // asking would be a prompt with no way to say yes.
  if (o.appleStatus === 'unsupported') return fallback
  return o.mozillaChosen && o.hasModel ? 'mozilla' : 'needs-install'
}
