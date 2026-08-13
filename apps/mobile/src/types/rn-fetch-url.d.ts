// React Native's own ambient types (node_modules/react-native/src/types/globals.d.ts)
// under-declare two Fetch-API globals relative to what the runtime actually
// supports. @cascade/core is written against the real spec and it runs
// correctly on RN today - only the *types* are behind:
//
//  - URLSearchParams: RN's globals.d.ts only declares `append`/`toString`
//    ("Based on definitions of lib.dom" but a stale subset). The actual
//    runtime polyfill (Libraries/Blob/URLSearchParams.js) implements the
//    full API - get/set/delete/has/sort/forEach/etc are all there.
//  - fetch(): RN's globals.d.ts types `input` as `RequestInfo` only.
//    lib.dom's signature is `RequestInfo | URL`. RN's fetch is whatwg-fetch,
//    whose Request constructor does `this.url = String(input)` for anything
//    that isn't already a Request - a URL instance stringifies to its href,
//    so passing one works fine at runtime.
//
// This augments the ambient globals to match reality, without touching
// packages/core (which is correctly written against the standard API) or
// react-native's own type package.
export {}

declare global {
  interface URLSearchParams {
    get(name: string): string | null
    getAll(name: string): string[]
    has(name: string): boolean
    set(name: string, value: string): void
    delete(name: string): void
    sort(): void
    forEach(
      callback: (value: string, key: string, parent: URLSearchParams) => void,
      thisArg?: unknown,
    ): void
    keys(): IterableIterator<string>
    values(): IterableIterator<string>
    entries(): IterableIterator<[string, string]>
  }

  // eslint-disable-next-line no-var
  function fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>
}
