// Same fixture source as language.test.ts: Article 1 of the UDHR, public
// domain, rather than in-copyright lyrics.

import test from 'node:test'
import assert from 'node:assert/strict'
import { translationLanguageFor, chineseScript, cyrillicLanguage, SCRIPT_PAIRS, pickTranslationEngine } from '../src/core/translation-models.ts'

const UDHR = {
  en: 'All human beings are born free and equal in dignity and rights. They are endowed with reason and conscience and should act towards one another in a spirit of brotherhood.',
  es: 'Todos los seres humanos nacen libres e iguales en dignidad y derechos y, dotados como estan de razon y conciencia, deben comportarse fraternalmente los unos con los otros.',
  fr: 'Tous les etres humains naissent libres et egaux en dignite et en droits. Ils sont doues de raison et de conscience et doivent agir les uns envers les autres dans un esprit de fraternite.',
  ja: 'すべての人間は、生まれながらにして自由であり、かつ、尊厳と権利とについて平等である。人間は、理性と良心とを授けられており、互いに同胞の精神をもって行動しなければならない。',
  ko: '모든 사람은 태어날 때부터 자유로우며 그 존엄과 권리에 있어 동등하다. 사람은 천부적으로 이성과 양심을 부여받았으며 서로 형제애의 정신으로 행동하여야 한다.',
  zhHans: '人人生而自由，在尊严和权利上一律平等。他们赋有理性和良心，并应以兄弟关系的精神相对待。',
  zhHant: '人人生而自由，在尊嚴和權利上一律平等。他們賦有理性和良心，並應以兄弟關係的精神相對待。',
  ru: 'Все люди рождаются свободными и равными в своем достоинстве и правах. Они наделены разумом и совестью и должны поступать в отношении друг друга в духе братства.',
  uk: 'Всі люди народжуються вільними і рівними у своїй гідності та правах. Вони наділені розумом і совістю і повинні діяти у відношенні один до одного в дусі братерства.',
  de: 'Alle Menschen sind frei und gleich an Würde und Rechten geboren. Sie sind mit Vernunft und Gewissen begabt und sollen einander im Geist der Brüderlichkeit begegnen.',
  pt: 'Todos os seres humanos nascem livres e iguais em dignidade e em direitos. Dotados de razão e de consciência, devem agir uns para com os outros em espírito de fraternidade.',
  th: 'มนุษย์ทั้งหลายเกิดมามีอิสระและเสมอภาคกันในเกียรติศักดิ์และสิทธิ ต่างมีเหตุผลและมโนธรรม และควรปฏิบัติต่อกันด้วยเจตนารมณ์แห่งภราดรภาพ',
  hi: 'सभी मनुष्यों को गौरव और अधिकारों के मामले में जन्मजात स्वतन्त्रता और समानता प्राप्त है। उन्हें बुद्धि और अन्तरात्मा की देन प्राप्त है और परस्पर उन्हें भाईचारे के भाव से बर्ताव करना चाहिए।',
}

test('names the language for each of Cascade\'s own models', () => {
  assert.equal(translationLanguageFor([UDHR.ja]), 'ja')
  assert.equal(translationLanguageFor([UDHR.ko]), 'ko')
  assert.equal(translationLanguageFor([UDHR.zhHans]), 'zh-Hans')
  assert.equal(translationLanguageFor([UDHR.zhHant]), 'zh-Hant')
  assert.equal(translationLanguageFor([UDHR.es]), 'es')
})

test('names languages only Apple Translation takes', () => {
  // No Cascade model for these; whether this Mac can do them is
  // pickTranslationEngine's call.
  assert.equal(translationLanguageFor([UDHR.fr]), 'fr')
  assert.equal(translationLanguageFor([UDHR.de]), 'de')
  assert.equal(translationLanguageFor([UDHR.pt]), 'pt')
  assert.equal(translationLanguageFor([UDHR.th]), 'th')
  assert.equal(translationLanguageFor([UDHR.hi]), 'hi')
  assert.equal(translationLanguageFor([UDHR.ru]), 'ru')
  assert.equal(translationLanguageFor([UDHR.uk]), 'uk')
})

test('offers nothing for English or for text too thin to judge', () => {
  assert.equal(translationLanguageFor([UDHR.en]), null)
  assert.equal(translationLanguageFor([]), null)
  assert.equal(translationLanguageFor(['Ooh', 'Ahh']), null)
})

test('reads the whole sheet, not the first line', () => {
  assert.equal(translationLanguageFor(['Idol', UDHR.ja]), 'ja')
})

test('cyrillicLanguage tells Russian from Ukrainian by their own letters', () => {
  // A short Russian line that trigram matching called Ukrainian.
  assert.equal(translationLanguageFor(['Я люблю гулять под дождём, когда улицы пустые вечером']), 'ru')
  assert.equal(cyrillicLanguage('Їжак їсть яблука'), 'uk')
  assert.equal(cyrillicLanguage('Съешь ещё этих мягких булок'), 'ru')
  assert.equal(cyrillicLanguage('Мама мыла раму'), 'ru')
  assert.equal(cyrillicLanguage('Мама'), null)   // nothing distinctive
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
  const m = { hasModel: true }
  // Apple off, or not available on this Mac: always Mozilla.
  assert.equal(pickTranslationEngine({ ...m, appleEnabled: false, appleStatus: 'installed', mozillaChosen: false }), 'mozilla')
  assert.equal(pickTranslationEngine({ ...m, appleEnabled: true, appleStatus: undefined, mozillaChosen: false }), 'mozilla')
  // Installed in macOS wins, even over an earlier choice of Mozilla.
  assert.equal(pickTranslationEngine({ ...m, appleEnabled: true, appleStatus: 'installed', mozillaChosen: false }), 'apple')
  assert.equal(pickTranslationEngine({ ...m, appleEnabled: true, appleStatus: 'installed', mozillaChosen: true }), 'apple')
  // Installable but not installed: ask, unless Mozilla was already chosen.
  assert.equal(pickTranslationEngine({ ...m, appleEnabled: true, appleStatus: 'supported', mozillaChosen: false }), 'needs-install')
  assert.equal(pickTranslationEngine({ ...m, appleEnabled: true, appleStatus: 'supported', mozillaChosen: true }), 'mozilla')
  // Apple has no model at all: nothing to install, so no prompt.
  assert.equal(pickTranslationEngine({ ...m, appleEnabled: true, appleStatus: 'unsupported', mozillaChosen: false }), 'mozilla')
})

test('pickTranslationEngine without a Cascade model: Apple or nothing', () => {
  const n = { hasModel: false, mozillaChosen: false }
  assert.equal(pickTranslationEngine({ ...n, appleEnabled: true, appleStatus: 'installed' }), 'apple')
  assert.equal(pickTranslationEngine({ ...n, appleEnabled: true, appleStatus: 'supported' }), 'needs-install')
  // A stale "use Cascade's model" choice cannot pick a model that does not exist.
  assert.equal(pickTranslationEngine({ ...n, appleEnabled: true, appleStatus: 'supported', mozillaChosen: true }), 'needs-install')
  assert.equal(pickTranslationEngine({ ...n, appleEnabled: true, appleStatus: 'unsupported' }), 'none')
  assert.equal(pickTranslationEngine({ ...n, appleEnabled: false, appleStatus: 'installed' }), 'none')
  assert.equal(pickTranslationEngine({ ...n, appleEnabled: true, appleStatus: undefined }), 'none')
})
