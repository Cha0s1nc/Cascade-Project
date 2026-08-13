// Declares `window.cascade` for renderer.js.
//
// Derived from the ElectronPlatform contract rather than hand-copied, so the
// preload and this declaration cannot drift: src/preload.ts is checked against
// the same interface. Adding a bridge method in one place without the other is
// now a build error.
//
// Applies to plain .js in the editor too - renderer.js gets autocomplete on
// window.cascade.* with no `checkJs` required.

import type { ElectronPlatform } from '../src/platform/index.ts'

declare global {
  interface Window {
    cascade: ElectronPlatform
  }

  /**
   * The bundled portable core (src/index.ts -> build/core.js), loaded by
   * index.html as a plain script before renderer.js and waterfall.js.
   *
   * Typed as the module's own shape so renderer.js gets real completions on
   * `CascadeCore.*` and on everything destructured out of it.
   */
  const CascadeCore: typeof import('../src/index.ts')
}

export {}
