/**
 * Getting the pixels of a cover, so core can pull colours out of them.
 *
 * The desktop does this with a canvas. React Native has no canvas and no way to
 * read an <Image>'s pixels, which is what the plan expected to need Skia for.
 * It turns out not to: Jellyfin will re-encode any cover as PNG on request, and
 * a PNG is decodable in plain JavaScript. So this asks the server for an 80x80
 * PNG - the same 80x80 the desktop canvas produces - and decodes it here.
 *
 * upng-js rather than the better-maintained fast-png, for one hard reason:
 * fast-png builds a `new TextDecoder('latin1')` at module scope to read PNG text
 * chunks, and Hermes has no TextDecoder. That throws while the module is being
 * evaluated, which no try/catch around the call site can contain - it took the
 * whole app down the moment a track started. upng-js touches no such global, and
 * its one dependency is pako, which the lyrics work needs anyway.
 *
 * That removes the whole reason Phase 5 was going to cost three native
 * dependencies (Skia, Reanimated, Worklets). The background itself needs none
 * either: RN 0.83 parses radial-gradient natively.
 *
 * @format
 */
import UPNG from 'upng-js';

import { extractTopColors } from '@cascade/core';
import type { BlobColor } from '@cascade/core';

import { getServerConfig } from '../api/client';

/** Matches the desktop's canvas size, so both hosts sample the same way. */
const SAMPLE_PX = 80;

/**
 * Covers already looked at, keyed by item id.
 *
 * Worth caching because the result is deterministic and the work is not free:
 * a fetch, a PNG inflate and a k-means pass. Skipping repeats matters most when
 * a queue loops back to a track, which is exactly when a re-derive would be
 * most visible as a stutter.
 *
 * Bounded, because a long listening session walks through a lot of albums and
 * an unbounded map here would be a slow leak on a device that never restarts.
 */
const cache = new Map<string, BlobColor[]>();
const CACHE_LIMIT = 60;

function remember(id: string, colors: BlobColor[]): void {
  if (cache.size >= CACHE_LIMIT) {
    // Oldest insertion first - Map preserves insertion order.
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(id, colors);
}

/**
 * The blob colours for an item's cover, or an empty array if it has no art or
 * the fetch fails.
 *
 * Never throws. This drives decoration: a cover that will not load should leave
 * the background on its previous colours, not take a screen down with it.
 */
export async function paletteFor(itemId: string, imageTag?: string | null): Promise<BlobColor[]> {
  if (!imageTag) return [];

  const cached = cache.get(itemId);
  if (cached) return cached;

  try {
    const { url, token } = getServerConfig();
    const src =
      `${url}/Items/${itemId}/Images/Primary` +
      `?fillHeight=${SAMPLE_PX}&fillWidth=${SAMPLE_PX}&format=Png&api_key=${token}`;

    const res = await fetch(src);
    if (!res.ok) return [];

    // toRGBA8 normalises every PNG flavour (palette, greyscale, 16-bit) to
    // packed RGBA, which is exactly what core wants - so there is no channel
    // juggling to get wrong here. A still PNG has one frame.
    const decoded = UPNG.decode(await res.arrayBuffer());
    const frame = UPNG.toRGBA8(decoded)[0];
    if (!frame) return [];
    const colors = extractTopColors(new Uint8Array(frame));
    remember(itemId, colors);
    return colors;
  } catch {
    return [];
  }
}
