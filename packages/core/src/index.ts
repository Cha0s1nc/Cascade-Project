// Bundle entry. esbuild builds this to build/core.js as an IIFE exposing the
// global `CascadeCore`, which index.html loads *before* renderer.js.
//
// This keeps renderer.js and waterfall.js as plain, global-scope scripts - they
// call `CascadeCore.parseLRC(...)` and nothing about their loading changes.
// Converting them to ES modules would break the global scope they share.

// The host contract. `export type` because platform/index.ts is interfaces only
// - nothing is emitted, so the desktop bundle is byte-identical - and because a
// host implementing Platform should not have to reach into core's file layout
// to find the type it is implementing.
export type * from './platform/index.ts'

export * from './core/types.ts'
export * from './core/lyrics.ts'
export * from './core/album-colors.ts'
export * from './core/jellyfin.ts'
export * from './core/queue.ts'
export * from './core/playback.ts'
export * from './core/playback-reporting.ts'
export * from './core/profiles/electron.ts'
export * from './core/profiles/apple.ts'
export * from './core/profiles/android.ts'
export * from './core/remote-control.ts'
export * from './core/ownership.ts'
export * from './core/waterfall-protocol.ts'
