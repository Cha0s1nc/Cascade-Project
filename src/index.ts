// Bundle entry. esbuild builds this to build/core.js as an IIFE exposing the
// global `CascadeCore`, which index.html loads *before* renderer.js.
//
// This keeps renderer.js and waterfall.js as plain, global-scope scripts - they
// call `CascadeCore.parseLRC(...)` and nothing about their loading changes.
// Converting them to ES modules would break the global scope they share.

export * from './core/types.ts'
export * from './core/lyrics.ts'
export * from './core/jellyfin.ts'
export * from './core/queue.ts'
export * from './core/playlist-edit.ts'
export * from './core/playback.ts'
export * from './core/playback-reporting.ts'
export * from './core/profiles/electron.ts'
export * from './core/remote-control.ts'
export * from './core/ownership.ts'
export * from './core/waterfall-protocol.ts'
export * from './core/album-colors.ts'
export * from './core/eq.ts'
export * from './core/eq-profile.ts'
export * from './core/crossfade.ts'
export * from './core/cascade-plugin.ts'
