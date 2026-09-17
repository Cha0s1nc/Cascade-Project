// Vendors Mozilla's bergamot translation runtime into build/bergamot/.
//
// The package is written for pages loaded over http(s) as ES modules, and
// Cascade's window is a file:// page running plain scripts, which it cannot be
// loaded into as-is. Three adjustments, each checked so an upgrade that moves
// the code fails the build instead of shipping a runtime that silently breaks:
//
// 1. translator.js is bundled to an IIFE exposing the global `Bergamot`, the
//    same way src/index.ts becomes `CascadeCore`. It finds its worker with
//    `new URL(..., import.meta.url)`, which has no value in a bundle, so
//    import.meta.url is defined as `self.__bergamotBase`, set by index.html to
//    the bundle's own URL.
// 2. The worker fetches its .wasm relative to itself, and fetch() from file://
//    is blocked. That one URL is pointed at cascade-model://app/runtime/, which
//    main.js serves from build/bergamot/runtime/.
// 3. The node:worker_threads import sits in a branch that only runs under
//    Node, so it is left external rather than bundled.

const fs = require('fs')
const path = require('path')
const esbuild = require('esbuild')

const PKG = path.join(__dirname, '..', 'node_modules', '@browsermt', 'bergamot-translator')
const OUT = path.join(__dirname, '..', 'build', 'bergamot')

fs.rmSync(OUT, { recursive: true, force: true })
fs.mkdirSync(path.join(OUT, 'worker'), { recursive: true })
fs.mkdirSync(path.join(OUT, 'runtime'), { recursive: true })

esbuild.buildSync({
  entryPoints: [path.join(PKG, 'translator.js')],
  bundle: true,
  format: 'iife',
  globalName: 'Bergamot',
  define: { 'import.meta.url': 'self.__bergamotBase' },
  external: ['node:worker_threads'],
  target: 'chrome122',
  outfile: path.join(OUT, 'translator.js'),
  logLevel: 'error',
})

const WASM_URL_IN = "new URL('./bergamot-translator-worker.wasm', self.location)"
const WASM_URL_OUT = "'cascade-model://app/runtime/bergamot-translator-worker.wasm'"
const worker = fs.readFileSync(path.join(PKG, 'worker', 'translator-worker.js'), 'utf8')
const hits = worker.split(WASM_URL_IN).length - 1
if (hits !== 1) {
  throw new Error(`build-bergamot: expected the wasm URL exactly once in translator-worker.js, found ${hits}. The runtime changed; re-check this patch.`)
}
fs.writeFileSync(path.join(OUT, 'worker', 'translator-worker.js'), worker.replace(WASM_URL_IN, WASM_URL_OUT))

fs.copyFileSync(path.join(PKG, 'worker', 'bergamot-translator-worker.js'), path.join(OUT, 'worker', 'bergamot-translator-worker.js'))
fs.copyFileSync(path.join(PKG, 'worker', 'bergamot-translator-worker.wasm'), path.join(OUT, 'runtime', 'bergamot-translator-worker.wasm'))

console.log('bergamot runtime -> build/bergamot/')
