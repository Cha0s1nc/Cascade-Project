import { test } from 'node:test'
import assert from 'node:assert/strict'
import { foreignRuns, foreignShare, isNonLatinLanguage, latinView, planLine, planSheet, splitForRows, wordTokens } from '../src/core/lyric-translation.ts'

test('foreignRuns: the foreign stretches, spaces and joiners inside, Latin outside', () => {
  assert.deepEqual(foreignRuns('Baby I love you 愛してる'), ['愛してる'])
  assert.deepEqual(foreignRuns('君のbabyになりたい'), ['君の', 'になりたい'])
  assert.deepEqual(foreignRuns('Say 사랑해 너를 tonight'), ['사랑해 너를'])
  assert.deepEqual(foreignRuns('「スーパーノヴァ」 yeah'), ['スーパーノヴァ'])
  assert.deepEqual(foreignRuns('Oh oh oh'), [])
})

test('foreignShare weighs a dense-script character as two Latin letters', () => {
  assert.equal(foreignShare('abc'), 0)
  assert.equal(foreignShare('愛'), 1)
  assert.ok(Math.abs(foreignShare('Baby I love you 愛してる') - 8 / 20) < 1e-9)
  assert.equal(foreignShare('...'), 0)
})

test('planLine: skip English, the phrase in a mostly-English line, the whole line otherwise', () => {
  assert.deepEqual(planLine('Oh oh oh', 'ja'), { mode: 'skip' })
  assert.deepEqual(planLine('   ', 'ja'), { mode: 'skip' })
  assert.deepEqual(planLine('Baby I love you 愛してる', 'ja'), { mode: 'run', text: '愛してる' })
  assert.deepEqual(planLine('君のbabyになりたい', 'ja'), { mode: 'line', text: '君のbabyになりたい' })
  assert.deepEqual(planLine('夜に駆ける', 'ja'), { mode: 'line', text: '夜に駆ける' })
  assert.deepEqual(planLine('Я люблю тебя, baby', 'ru'), { mode: 'line', text: 'Я люблю тебя, baby' })
  assert.deepEqual(planLine('All I need is you, тебя', 'ru'), { mode: 'run', text: 'тебя' })
  // Two separate phrases read better translated together.
  assert.equal(planLine('Hey 君 and you 僕 tonight we go', 'ja').mode, 'line')
})

test('planLine: a Latin-script language translates every line, as before', () => {
  assert.deepEqual(planLine('Te quiero, baby', 'es'), { mode: 'line', text: 'Te quiero, baby' })
  assert.deepEqual(planLine('Oh oh oh', 'es'), { mode: 'line', text: 'Oh oh oh' })
  assert.equal(isNonLatinLanguage('zh-Hant'), true)
  assert.equal(isNonLatinLanguage('fr'), false)
  assert.equal(isNonLatinLanguage(null), false)
  assert.equal(planSheet(['a', '愛'], 'ja').length, 2)
})

test('latinView: a passed-through line has nothing, a foreign word gets its English under it', () => {
  assert.deepEqual(latinView('Oh oh oh', 'Oh oh oh!'), { mode: 'none' })
  const src = 'Nobody mess with my familia'
  const v = latinView(src, 'Nobody mess with my family')
  assert.deepEqual(v, { mode: 'glosses', glosses: [{ from: src.indexOf('familia'), to: src.length, text: 'family' }] })
  // An English word the translator "fixed" is not a gloss.
  assert.deepEqual(latinView(src, 'Nobody messes with my family'), v)
  // A phrase in the middle.
  const mid = 'I want you mi amor tonight'
  const m = latinView(mid, 'I want you my love tonight')
  assert.equal(m.mode, 'glosses')
  assert.deepEqual(m.mode === 'glosses' && m.glosses.map(g => [mid.slice(g.from, g.to), g.text]), [['mi amor', 'my love']])
})

test('latinView: a mostly changed line is shown row by row', () => {
  assert.deepEqual(latinView("Y yo me vo' a morir leal y nunca como un traicionero", 'And I am going to die loyal and never like a traitor'), { mode: 'rows' })
  assert.deepEqual(wordTokens("Y yo me vo' a").map(t => t.norm), ['y', 'yo', 'me', "vo'", 'a'])
})

test('splitForRows: word breaks in proportion to the rows', () => {
  const en = 'And I am going to die loyal and never like a traitor'
  // By share of characters, not word for word: "and" goes with the row nearer its share.
  assert.deepEqual(splitForRows(en, [27 / 53, 26 / 53]), ['And I am going to die loyal', 'and never like a traitor'])
  assert.deepEqual(splitForRows(en, [0.7, 0.3]), ['And I am going to die loyal and never', 'like a traitor'])
  assert.deepEqual(splitForRows(en, [1]), [en])
  assert.deepEqual(splitForRows('Hi', [0.5, 0.5]), ['Hi'])
  // Every row gets a word when there are enough.
  const three = splitForRows('one two three', [0.9, 0.05, 0.05])
  assert.equal(three.length, 3)
  assert.ok(three.every(Boolean))
})
