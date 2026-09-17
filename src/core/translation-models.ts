// Which on-device translation model a lyric sheet needs, if any.
//
// Translation runs Mozilla's Firefox Translations models (Marian, via the
// bergamot WASM runtime). Each is one source language into English, downloaded
// on first use - see translation-models.json and main.js. Only these five are
// offered: a sheet in any other language gets no Translate button at all,
// because there is no model that could honour the click.

import { detectLanguage } from './language.ts'

export type TranslationModelKey = 'ja' | 'ko' | 'zh-Hans' | 'zh-Hant' | 'es'

export const TRANSLATION_MODEL_KEYS: readonly TranslationModelKey[] = ['ja', 'ko', 'zh-Hans', 'zh-Hant', 'es']

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

/**
 * The model a sheet needs, or null when none of ours can translate it.
 * Takes the whole sheet for the same reason shouldOfferTranslation does: a
 * Japanese song opening on an English title line must still read as Japanese.
 */
export function translationModelFor(lines: string[]): TranslationModelKey | null {
  const text = lines.join(' ').slice(0, 1000)
  const lang = detectLanguage(text)
  if (lang === 'ja' || lang === 'ko' || lang === 'es') return lang
  if (lang === 'zh') return chineseScript(text)
  return null
}

/** What Apple's Translation framework says about one language into English. */
export type AppleLanguageStatus = 'installed' | 'supported' | 'unsupported'

/** 'needs-install': Apple could translate this once the language is installed
 *  in macOS, and the user has not chosen Mozilla's model for it instead. */
export type TranslationEngine = 'apple' | 'mozilla' | 'needs-install'

/**
 * Which engine translates a sheet in one of the supported languages.
 *
 * `appleEnabled` is the setting AND this Mac being able to use it (macOS 26+
 * with the helper built). `appleStatus` is undefined whenever Apple is not in
 * play. `mozillaChosen` is the user having picked Mozilla's model for this
 * language from the install prompt; it only ever matters while the language
 * is not installed in macOS, so installing it later switches back to Apple
 * with no setting to undo.
 */
export function pickTranslationEngine(o: {
  appleEnabled: boolean
  appleStatus?: AppleLanguageStatus
  mozillaChosen: boolean
}): TranslationEngine {
  if (!o.appleEnabled || !o.appleStatus) return 'mozilla'
  if (o.appleStatus === 'installed') return 'apple'
  // Nothing to install: Apple has no model for this language at all, so
  // asking would be a prompt with no way to say yes.
  if (o.appleStatus === 'unsupported') return 'mozilla'
  return o.mozillaChosen ? 'mozilla' : 'needs-install'
}
