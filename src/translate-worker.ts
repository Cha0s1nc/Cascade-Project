// Lyrics translation, entirely on-device.
//
// Runs in a Worker because a Marian forward pass on WASM takes seconds and this
// app is playing audio - blocking the main thread would glitch the Web Audio
// graph, not just the UI.
//
// Two models, because Helsinki's multilingual pairs are one-directional:
// mul-en is any -> English, en-mul is English -> any. A non-English target
// therefore pivots through English, which costs a second pass and some fidelity
// on the way out. See TARGET_TOKEN for what that rules out.
import { pipeline, env, type TranslationPipeline } from '@huggingface/transformers'

// Everything local. Without these, transformers.js reaches out to
// huggingface.co for the weights AND to cdn.jsdelivr.net for the ONNX runtime
// wasm binary - the second one is easy to miss, and it is exactly the kind of
// silent third-party traffic this whole change exists to remove.
env.allowRemoteModels = false
env.allowLocalModels = true
env.localModelPath = 'cascade-model://app'

// Typed optional because onnxruntime-node has no wasm backend. In a Worker it
// is always there, and a silent skip here would send the runtime back to the
// jsdelivr CDN, so this throws rather than degrading quietly.
const wasmBackend = env.backends.onnx.wasm
if (!wasmBackend) throw new Error('onnxruntime wasm backend unavailable')

wasmBackend.wasmPaths = {
  wasm: 'cascade-model://app/ort/ort-wasm-simd-threaded.wasm',
  mjs: 'cascade-model://app/ort/ort-wasm-simd-threaded.mjs',
}
// Threaded wasm needs SharedArrayBuffer, which needs cross-origin isolation we
// do not have on a custom protocol. One thread is the honest setting; the
// dedupe and batching below are what buy the speed back.
// ponytail: single-threaded. If this is ever too slow, the upgrade is COOP/COEP
// headers on the cascade-model handler plus numThreads = 4.
wasmBackend.numThreads = 1

// NOT optional, and not a performance tweak. The default level ('all') runs a
// QDQ transform that rejects these models outright:
//   qdq_actions.cc:137 TransposeDQWeightsForMatMulNBits
//   Missing required scale: model.shared.weight_merged_0_scale
// The uint8 exports predate that pass. 'basic' skips it and loads fine, and
// measured slightly faster than 'disabled' besides.
const SESSION_OPTIONS = { graphOptimizationLevel: 'basic' as const }

// en-mul selects its target with an ISO 639-3 token prefixed to the input, and
// only the 194 languages in its vocab are reachable.
//
// Korean is deliberately absent: opus-mt-en-mul has no >>kor<< token, and there
// is no ONNX export of opus-mt-tc-big-en-ko to fall back to. English -> Korean
// has no local path at this model size, so the picker disables that option
// rather than silently returning untranslated text. Korean as a *source* is
// fine - mul-en handles it.
const TARGET_TOKEN: Record<string, string> = {
  es: '>>spa<<', fr: '>>fra<<', de: '>>deu<<', ja: '>>jpn<<',
  zh: '>>cmn<<', pt: '>>por<<', it: '>>ita<<', ru: '>>rus<<',
  ar: '>>ara<<', hi: '>>hin<<',
}

let toEnglish: TranslationPipeline | null = null
let fromEnglish: TranslationPipeline | null = null

async function getToEnglish() {
  if (!toEnglish) {
    toEnglish = await pipeline('translation', 'opus-mt-mul-en',
      { session_options: SESSION_OPTIONS }) as TranslationPipeline
  }
  return toEnglish
}

async function getFromEnglish() {
  if (!fromEnglish) {
    fromEnglish = await pipeline('translation', 'opus-mt-en-mul',
      { session_options: SESSION_OPTIONS }) as TranslationPipeline
  }
  return fromEnglish
}

const BATCH = 8

/** Translates `texts` positionally - output[i] corresponds to input[i], and a
 *  blank input stays blank. Marian on an empty sequence returns junk rather
 *  than an empty string, so blanks never reach the model. */
async function run(id: number, pipe: TranslationPipeline, texts: string[], prefix = ''): Promise<string[]> {
  const out = new Array<string>(texts.length).fill('')

  // Choruses repeat, and a lyric sheet is mostly repeats. Translating
  // "la la la" eleven times is eleven forward passes for one answer.
  const unique = new Map<string, number[]>()
  texts.forEach((t, i) => {
    const key = t.trim()
    if (!key) return
    const hit = unique.get(key)
    if (hit) hit.push(i)
    else unique.set(key, [i])
  })
  if (!unique.size) return out

  const keys = [...unique.keys()]
  for (let i = 0; i < keys.length; i += BATCH) {
    const slice = keys.slice(i, i + BATCH)
    const res = await pipe(slice.map(k => prefix + k)) as Array<{ translation_text: string }>
    slice.forEach((k, j) => {
      // Falling back to the original line keeps the sheet aligned; a dropped
      // line would shift every later translation onto the wrong lyric.
      const text = res[j]?.translation_text ?? k
      for (const idx of unique.get(k)!) out[idx] = text
    })
    self.postMessage({ type: 'progress', id, done: Math.min(i + BATCH, keys.length), total: keys.length })
  }
  return out
}

export interface TranslateRequest {
  id: number
  lines: string[]
  target: string
}

self.onmessage = async (e: MessageEvent<TranslateRequest>) => {
  const { id, lines, target } = e.data
  try {
    // total 0 means "no progress to report yet". The first call has to read
    // ~114 MB off disk and build two ORT sessions before a single line is
    // translated, and a button that sits silent for ten seconds reads as hung.
    self.postMessage({ type: 'progress', id, done: 0, total: 0 })

    let out = await run(id, await getToEnglish(), lines)
    if (target !== 'en') {
      const token = TARGET_TOKEN[target]
      if (!token) throw new Error(`No on-device model can translate into "${target}"`)
      out = await run(id, await getFromEnglish(), out, token + ' ')
    }
    self.postMessage({ type: 'result', id, lines: out })
  } catch (err) {
    self.postMessage({ type: 'error', id, message: err instanceof Error ? err.message : String(err) })
  }
}
