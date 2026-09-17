// Same fixture source as language.test.ts: Article 1 of the UDHR, public
// domain, rather than in-copyright lyrics.

import test from 'node:test'
import assert from 'node:assert/strict'
import { translationModelFor, chineseScript, SCRIPT_PAIRS, pickTranslationEngine } from '../src/core/translation-models.ts'

const UDHR = {
  en: 'All human beings are born free and equal in dignity and rights. They are endowed with reason and conscience and should act towards one another in a spirit of brotherhood.',
  es: 'Todos los seres humanos nacen libres e iguales en dignidad y derechos y, dotados como estan de razon y conciencia, deben comportarse fraternalmente los unos con los otros.',
  fr: 'Tous les etres humains naissent libres et egaux en dignite et en droits. Ils sont doues de raison et de conscience et doivent agir les uns envers les autres dans un esprit de fraternite.',
  ja: 'すべての人間は、生まれながらにして自由であり、かつ、尊厳と権利とについて平等である。人間は、理性と良心とを授けられており、互いに同胞の精神をもって行動しなければならない。',
  ko: '모든 사람은 태어날 때부터 자유로우며 그 존엄과 권리에 있어 동등하다. 사람은 천부적으로 이성과 양심을 부여받았으며 서로 형제애의 정신으로 행동하여야 한다.',
  zhHans: '人人生而自由，在尊严和权利上一律平等。他们赋有理性和良心，并应以兄弟关系的精神相对待。',
  zhHant: '人人生而自由，在尊嚴和權利上一律平等。他們賦有理性和良心，並應以兄弟關係的精神相對待。',
}

test('picks the model for each supported language', () => {
  assert.equal(translationModelFor([UDHR.ja]), 'ja')
  assert.equal(translationModelFor([UDHR.ko]), 'ko')
  assert.equal(translationModelFor([UDHR.zhHans]), 'zh-Hans')
  assert.equal(translationModelFor([UDHR.zhHant]), 'zh-Hant')
  assert.equal(translationModelFor([UDHR.es]), 'es')
})

test('offers nothing for languages without a model', () => {
  // English needs no translation, and French has no model to download - both
  // must mean no Translate button, not a button that can only fail.
  assert.equal(translationModelFor([UDHR.en]), null)
  assert.equal(translationModelFor([UDHR.fr]), null)
  assert.equal(translationModelFor([]), null)
  assert.equal(translationModelFor(['Ooh', 'Ahh']), null)
})

test('reads the whole sheet, not the first line', () => {
  assert.equal(translationModelFor(['Idol', UDHR.ja]), 'ja')
})

test('chineseScript follows the majority spelling, ties to Simplified', () => {
  assert.equal(chineseScript('我们这个'), 'zh-Hans')
  assert.equal(chineseScript('我們這個'), 'zh-Hant')
  assert.equal(chineseScript('人人生而自由'), 'zh-Hans')   // no distinguishing characters
  assert.equal(chineseScript('们們'), 'zh-Hans')           // a tie
})

test('the script tables stay aligned pair for pair', () => {
  const s = [...SCRIPT_PAIRS.SIMPLIFIED]
  const t = [...SCRIPT_PAIRS.TRADITIONAL]
  assert.equal(s.length, t.length)
  s.forEach((c, i) => assert.notEqual(c, t[i], `pair ${i} is the same character: ${c}`))
  assert.equal(new Set(s).size, s.length, 'duplicate in SIMPLIFIED')
  assert.equal(new Set(t).size, t.length, 'duplicate in TRADITIONAL')
  // No character may appear in both tables, or it would count for both sides.
  assert.equal(s.filter(c => t.includes(c)).length, 0)
})

test('pickTranslationEngine prefers Apple only where it can actually run', () => {
  // Apple off, or not available on this Mac: always Mozilla.
  assert.equal(pickTranslationEngine({ appleEnabled: false, appleStatus: 'installed', mozillaChosen: false }), 'mozilla')
  assert.equal(pickTranslationEngine({ appleEnabled: true, appleStatus: undefined, mozillaChosen: false }), 'mozilla')
  // Installed in macOS wins, even over an earlier choice of Mozilla.
  assert.equal(pickTranslationEngine({ appleEnabled: true, appleStatus: 'installed', mozillaChosen: false }), 'apple')
  assert.equal(pickTranslationEngine({ appleEnabled: true, appleStatus: 'installed', mozillaChosen: true }), 'apple')
  // Installable but not installed: ask, unless Mozilla was already chosen.
  assert.equal(pickTranslationEngine({ appleEnabled: true, appleStatus: 'supported', mozillaChosen: false }), 'needs-install')
  assert.equal(pickTranslationEngine({ appleEnabled: true, appleStatus: 'supported', mozillaChosen: true }), 'mozilla')
  // Apple has no model at all: nothing to install, so no prompt.
  assert.equal(pickTranslationEngine({ appleEnabled: true, appleStatus: 'unsupported', mozillaChosen: false }), 'mozilla')
})
