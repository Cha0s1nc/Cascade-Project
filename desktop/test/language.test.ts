// Fixtures are Article 1 of the Universal Declaration of Human Rights, which
// the UN publishes in 500+ languages and places in the public domain. Real song
// lyrics would be the obvious thing to test a lyrics feature with, and are
// exactly the wrong thing to commit: in-copyright verse checked into a GPL repo.
// The UDHR is the standard corpus for language detection anyway.

import test from 'node:test'
import assert from 'node:assert/strict'
import { detectLanguage, shouldOfferTranslation } from '../src/core/language.ts'

const UDHR: Record<string, string> = {
  en: 'All human beings are born free and equal in dignity and rights. They are endowed with reason and conscience and should act towards one another in a spirit of brotherhood.',
  es: 'Todos los seres humanos nacen libres e iguales en dignidad y derechos y, dotados como estan de razon y conciencia, deben comportarse fraternalmente los unos con los otros.',
  fr: 'Tous les etres humains naissent libres et egaux en dignite et en droits. Ils sont doues de raison et de conscience et doivent agir les uns envers les autres dans un esprit de fraternite.',
  de: 'Alle Menschen sind frei und gleich an Wuerde und Rechten geboren. Sie sind mit Vernunft und Gewissen begabt und sollen einander im Geiste der Brueberlichkeit begegnen.',
  pt: 'Todos os seres humanos nascem livres e iguais em dignidade e em direitos. Dotados de razao e de consciencia, devem agir uns para com os outros em espirito de fraternidade.',
  it: 'Tutti gli esseri umani nascono liberi ed eguali in dignita e diritti. Essi sono dotati di ragione e di coscienza e devono agire gli uni verso gli altri in spirito di fratellanza.',
  ru: 'Все люди рождаются свободными и равными в своем достоинстве и правах. Они наделены разумом и совестью и должны поступать в отношении друг друга в духе братства.',
  ja: 'すべての人間は、生まれながらにして自由であり、かつ、尊厳と権利とについて平等である。人間は、理性と良心とを授けられており、互いに同胞の精神をもって行動しなければならない。',
  zh: '人人生而自由，在尊严和权利上一律平等。他们赋有理性和良心，并应以兄弟关系的精神相对待。',
}

test('detects the language of each UDHR translation', () => {
  for (const [expected, text] of Object.entries(UDHR)) {
    assert.equal(detectLanguage(text), expected, `expected ${expected} for: ${text.slice(0, 40)}`)
  }
})

test('returns empty string rather than guessing on thin input', () => {
  // '' means "no idea", never "English". Collapsing the two would put a
  // translate button on every instrumental interlude.
  assert.equal(detectLanguage(''), '')
  assert.equal(detectLanguage('Oh'), '')
  assert.equal(detectLanguage('   \n  \t '), '')
  assert.equal(detectLanguage('La la la'), '')
})

test('offers translation for non-English lyrics only', () => {
  assert.equal(shouldOfferTranslation([UDHR.es]), true)
  assert.equal(shouldOfferTranslation([UDHR.ja]), true)
  assert.equal(shouldOfferTranslation([UDHR.en]), false)
})

test('never offers translation when there is nothing to go on', () => {
  assert.equal(shouldOfferTranslation([]), false)
  assert.equal(shouldOfferTranslation(['', '', '']), false)
  assert.equal(shouldOfferTranslation(['Ooh', 'Ahh']), false)
})

test('judges the whole sheet, not the first line', () => {
  // The bug this guards: a Spanish song whose first line is its English title
  // was detected as English off lines[0] and never offered a translation.
  const lines = ['Bailando', ...UDHR.es.split('. ')]
  assert.equal(shouldOfferTranslation(lines), true)
})

test('normalises whitespace before measuring length', () => {
  // Lyric sheets are full of ragged spacing; padding must not be mistaken for
  // enough signal to detect on.
  assert.equal(detectLanguage('a\n\n   \t  b'), '')
})
