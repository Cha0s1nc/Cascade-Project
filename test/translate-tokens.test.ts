// Guards the one step in the translation pipeline that fails *silently*.
//
// If en-mul's language tokens are not registered as `added_tokens`, the
// tokenizer spells ">>fra<<" out as ordinary SentencePiece pieces, the model
// copies the literal text into its output and never switches language, and
// nothing anywhere throws. The user just gets back nonsense that looks like a
// bad translation rather than a broken build. Everything else in this feature
// fails loudly; this does not, so it gets the test.

import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const { patchTargetTokens, TARGET_TOKENS } = require('../scripts/fetch-models.js')

/** A tokenizer.json with just enough shape to exercise the id lookup. */
function fixture(vocab: Record<string, number>, addedTokens: unknown[] = []) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cascade-tok-'))
  fs.mkdirSync(path.join(dir, 'opus-mt-en-mul'), { recursive: true })
  fs.writeFileSync(
    path.join(dir, 'opus-mt-en-mul', 'tokenizer.json'),
    JSON.stringify({ model: { vocab }, added_tokens: addedTokens }),
  )
  return dir
}

function readBack(dir: string) {
  return JSON.parse(fs.readFileSync(path.join(dir, 'opus-mt-en-mul', 'tokenizer.json'), 'utf8'))
}

const fullVocab = Object.fromEntries(TARGET_TOKENS.map((t: string, i: number) => [t, 100 + i]))

test('registers every offered target token with its real vocab id', () => {
  const dir = fixture({ ...fullVocab, hello: 1 })
  assert.equal(patchTargetTokens(dir), TARGET_TOKENS.length)

  const added = readBack(dir).added_tokens
  assert.equal(added.length, TARGET_TOKENS.length)
  for (const t of TARGET_TOKENS) {
    const entry = added.find((a: { content: string }) => a.content === t)
    assert.ok(entry, `${t} was not registered`)
    // A wrong id is the worst outcome: it silently selects another language.
    assert.equal(entry.id, fullVocab[t])
    // normalized:false keeps it verbatim, special:true makes it atomic and
    // strips it from decoded output if the model ever echoes one back.
    assert.equal(entry.normalized, false)
    assert.equal(entry.special, true)
    assert.equal(entry.rstrip, true)
  }
})

test('is idempotent, so a rebuild does not duplicate entries', () => {
  const dir = fixture({ ...fullVocab })
  assert.equal(patchTargetTokens(dir), TARGET_TOKENS.length)
  assert.equal(patchTargetTokens(dir), 0)
  assert.equal(readBack(dir).added_tokens.length, TARGET_TOKENS.length)
})

test('preserves added_tokens the model already shipped', () => {
  const existing = { id: 0, content: '</s>', special: true }
  const dir = fixture({ ...fullVocab }, [existing])
  patchTargetTokens(dir)
  const added = readBack(dir).added_tokens
  assert.deepEqual(added[0], existing)
  assert.equal(added.length, TARGET_TOKENS.length + 1)
})

test('handles the array vocab form as well as the object form', () => {
  // tokenizer.json ships vocab either as {token: id} or as [[token, score], ...]
  // where the id is the index. Reading the wrong one yields undefined ids.
  const arrayVocab = TARGET_TOKENS.map((t: string) => [t, 0.0])
  const dir = fixture(arrayVocab as never)
  assert.equal(patchTargetTokens(dir), TARGET_TOKENS.length)
  const added = readBack(dir).added_tokens
  for (let i = 0; i < TARGET_TOKENS.length; i++) {
    assert.equal(added.find((a: { content: string }) => a.content === TARGET_TOKENS[i]).id, i)
  }
})

test('fails loudly when a token is missing from the vocab', () => {
  // This is how we would find out that a future model revision dropped a
  // language, instead of shipping a picker entry that returns nonsense.
  const { ['>>fra<<']: _dropped, ...missingFrench } = fullVocab
  const dir = fixture(missingFrench)
  assert.throws(() => patchTargetTokens(dir), />>fra<< missing from en-mul vocab/)
})

test('never offers Korean, which en-mul cannot produce', () => {
  // opus-mt-en-mul has no >>kor<< token and there is no ONNX export of
  // opus-mt-tc-big-en-ko. If this ever passes, the picker can re-enable Korean.
  assert.ok(!TARGET_TOKENS.includes('>>kor<<'))
})
