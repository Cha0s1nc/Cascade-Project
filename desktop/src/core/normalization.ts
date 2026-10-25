// Jellyfin's NormalizationGain (dB) turned into a linear GainNode multiplier.
//
// Pure on purpose, same reasoning as eq-profile.ts: renderer.js owns the
// actual per-deck GainNode (see _ensureEqGraph/_deckNormGain), this just does
// the maths so it can be tested without a DOM or an AudioContext.

import { dbToGain } from './eq-profile.ts'

// A boost past this is more likely to distort or startle than to help. The
// test library has an album deliberately scanned at +34dB (a whisper-quiet
// recording) - applying that in full would be roughly a 50x amplitude
// multiplier, well past where a normal mix starts clipping against the
// element's own headroom. A normally mastered track needs at most a few dB
// either way, so anything asking for more is a genuine outlier; capping the
// boost still makes it louder, just not blown out.
export const NORMALIZATION_MAX_BOOST_DB = 12

// A cut never risks clipping, but NormalizationGain is server data crossing a
// trust boundary same as any stored value - a corrupt or wildly mis-scanned
// number must not reach a GainNode unclamped either. Generous on purpose:
// a real cut this large would mean an actually deafening source file.
export const NORMALIZATION_MAX_CUT_DB = 24

/** Clamp a raw NormalizationGain (dB) into the range this app will apply. */
export function clampNormalizationDb(db: number): number {
  return Math.max(-NORMALIZATION_MAX_CUT_DB, Math.min(NORMALIZATION_MAX_BOOST_DB, db))
}

/**
 * A Jellyfin NormalizationGain value to a linear GainNode multiplier, clamped
 * and NaN-safe. Missing or corrupt data (not a finite number) means unity -
 * the server has no loudness scan for this track/album, or the value is not
 * trustworthy, either way the track should play at its own natural level
 * rather than guess.
 */
export function normalizationGainLinear(db: unknown): number {
  return typeof db === 'number' && Number.isFinite(db) ? dbToGain(clampNormalizationDb(db)) : 1
}
