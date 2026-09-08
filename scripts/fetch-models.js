#!/usr/bin/env node
// Downloads the two Marian translation models into models/ so electron-builder
// can bundle them. Not committed - 224 MB has no business in git. Every build
// script runs this first; it no-ops once the files are on disk.
//
// Two models because en-mul only goes English -> X. A Spanish lyric translated
// to French is mul-en then en-mul, pivoting through English.
const fs = require('fs')
const path = require('path')

const HOST = 'https://huggingface.co'
const MODELS = ['Xenova/opus-mt-mul-en', 'Xenova/opus-mt-en-mul']
const FILES = [
  'config.json', 'generation_config.json', 'tokenizer.json',
  'tokenizer_config.json', 'special_tokens_map.json', 'vocab.json',
  'onnx/encoder_model_quantized.onnx',
  'onnx/decoder_model_merged_quantized.onnx',
]
const OUT = path.join(__dirname, '..', 'models')

async function get(repo, file, dest) {
  if (fs.existsSync(dest) && fs.statSync(dest).size > 0) return false
  const url = `${HOST}/${repo}/resolve/main/${file}`
  const res = await fetch(url)
  if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${url}`)
  fs.mkdirSync(path.dirname(dest), { recursive: true })
  // Write to a temp name and rename, so an interrupted download can never leave
  // a truncated file that the size check above would then accept as complete.
  const tmp = dest + '.part'
  fs.writeFileSync(tmp, Buffer.from(await res.arrayBuffer()))
  fs.renameSync(tmp, dest)
  return true
}

// The target languages the picker offers, as en-mul's own ISO 639-3 tokens.
// Korean is not here because en-mul has no >>kor<< token at all - see
// src/translate-worker.ts.
const TARGET_TOKENS = [
  '>>spa<<', '>>fra<<', '>>deu<<', '>>jpn<<', '>>cmn<<',
  '>>por<<', '>>ita<<', '>>rus<<', '>>ara<<', '>>hin<<',
]

/**
 * Registers en-mul's language tokens in its tokenizer's `added_tokens`.
 *
 * Without this the pivot silently produces garbage. en-mul picks its target
 * from a ">>fra<<" token prefixed to the input, and transformers.js v4 routes
 * encoding through the native tokenizers backend - which only treats
 * `added_tokens` as atomic. The language codes ship in the vocab but NOT in
 * `added_tokens`, so ">>fra<< Bonjour" was being spelled out as ordinary
 * SentencePiece pieces. The model then copied the literal ">>fra<<" into its
 * output and never switched language.
 *
 * MarianTokenizer does override _encode_text to handle exactly this, but that
 * method is dead code in v4 - defined and never called. Registering the ten
 * tokens we actually offer is a build-time fix that needs no runtime patching
 * and no downgrade to the unmaintained @xenova/transformers v2.
 */
function patchTargetTokens(outDir = OUT) {
  const file = path.join(outDir, 'opus-mt-en-mul', 'tokenizer.json')
  const d = JSON.parse(fs.readFileSync(file, 'utf8'))
  const vocab = d.model.vocab
  const lookup = Array.isArray(vocab)
    ? Object.fromEntries(vocab.map((entry, i) => [entry[0], i]))
    : vocab
  const have = new Set(d.added_tokens.map(t => t.content))

  let added = 0
  for (const content of TARGET_TOKENS) {
    if (have.has(content)) continue
    const id = lookup[content]
    if (id === undefined) throw new Error(`${content} missing from en-mul vocab`)
    // rstrip so the space after the token does not become a leading space on
    // the first real word; normalized false keeps it verbatim.
    d.added_tokens.push({
      id, content, single_word: false,
      lstrip: false, rstrip: true, normalized: false, special: true,
    })
    added++
  }
  if (added) fs.writeFileSync(file, JSON.stringify(d))
  return added
}

// transformers.js otherwise pulls the ONNX runtime wasm from cdn.jsdelivr.net
// at runtime. Copying it in next to the weights is what makes "on-device"
// actually true, and keeps the app working with no network at all.
//
// Only the plain build - the jsep/jspi/asyncify variants are for WebGPU and
// stack-switching, neither of which Chromium 122 gives us, and they are 15-26 MB
// each to carry for nothing.
const ORT_SRC = path.join(__dirname, '..', 'node_modules', 'onnxruntime-web', 'dist')
const ORT_FILES = ['ort-wasm-simd-threaded.wasm', 'ort-wasm-simd-threaded.mjs']

function copyOrt() {
  const dest = path.join(OUT, 'ort')
  fs.mkdirSync(dest, { recursive: true })
  let n = 0
  for (const f of ORT_FILES) {
    const src = path.join(ORT_SRC, f)
    if (!fs.existsSync(src)) throw new Error(`missing ${src} - run npm install first`)
    const to = path.join(dest, f)
    // Re-copy when onnxruntime-web is upgraded, or the app ships a wasm binary
    // that does not match the JS bundled into the worker.
    if (fs.existsSync(to) && fs.statSync(to).size === fs.statSync(src).size) continue
    fs.copyFileSync(src, to)
    n++
  }
  return n
}

async function main() {
  let fetched = 0
  for (const repo of MODELS) {
    const name = repo.split('/')[1]
    for (const file of FILES) {
      const dest = path.join(OUT, name, file)
      if (await get(repo, file, dest)) {
        fetched++
        console.log(`  ${name}/${file}  ${(fs.statSync(dest).size / 1e6).toFixed(1)} MB`)
      }
    }
  }
  const patched = patchTargetTokens()
  const ort = copyOrt()
  console.log(fetched || ort || patched
    ? `models: fetched ${fetched} file(s), registered ${patched} language token(s), copied ${ort} runtime file(s)`
    : 'models: already present')
}

// Only run when invoked directly, so the token logic above can be unit tested.
if (require.main === module) {
  main().catch(e => { console.error('models: FAILED -', e.message); process.exit(1) })
}

module.exports = { patchTargetTokens, TARGET_TOKENS, OUT }
