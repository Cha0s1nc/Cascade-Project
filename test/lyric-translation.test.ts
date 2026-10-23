import { test } from 'node:test'
import assert from 'node:assert/strict'
import { foreignRuns, foreignShare, isNonLatinLanguage, planLine, planSheet } from '../src/core/lyric-translation.ts'

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
