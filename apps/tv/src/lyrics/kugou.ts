/**
 * Kugou KRC lyrics - word-level timing, no auth needed.
 *
 * The desktop routes this through main-process IPC purely because the decrypt
 * needs Buffer and zlib.inflateSync, neither of which exist in a renderer. React
 * Native has pako in-process and no CORS to work around, so the IPC hop
 * disappears entirely and this talks to Kugou directly.
 *
 * The shared half - base64, the XOR key, the 'krc1' header - lives in
 * @cascade/core's decodeKrc, so the two hosts cannot drift on the format.
 *
 * @format
 */
import { inflate } from 'pako';

import { decodeKrc, timeoutSignal } from '@cascade/core';

interface KugouCandidate {
  id: string;
  accesskey: string;
}

/**
 * Search Kugou for a track and return its decrypted KRC, or null.
 *
 * Never throws: this is one racer in a waterfall, and a Kugou outage should
 * cost the other sources nothing.
 */
export async function getKugouKrc(q: {
  title: string;
  artist: string;
  durationMs: number;
}): Promise<string | null> {
  try {
    const keyword = `${q.artist} - ${q.title}`;
    const search =
      'http://lyrics.kugou.com/search?ver=1&man=yes&client=pc' +
      `&keyword=${encodeURIComponent(keyword)}&duration=${Math.round(q.durationMs)}`;

    const sRes = await fetch(search, { signal: timeoutSignal() });
    if (!sRes.ok) return null;
    const sData = (await sRes.json()) as { candidates?: KugouCandidate[] };

    const top = sData.candidates?.[0];
    if (!top) return null;

    const download =
      'http://lyrics.kugou.com/download?ver=1&client=pc' +
      `&id=${encodeURIComponent(top.id)}&accesskey=${encodeURIComponent(top.accesskey)}` +
      '&fmt=krc&charset=utf8';

    const dRes = await fetch(download, { signal: timeoutSignal() });
    if (!dRes.ok) return null;
    const dData = (await dRes.json()) as { content?: string };
    if (!dData.content) return null;

    // `to: 'string'` because pako decodes UTF-8 itself. Hermes has no
    // TextDecoder, so doing it any other way would need a hand-rolled decoder.
    return decodeKrc(dData.content, bytes => inflate(bytes, { to: 'string' }));
  } catch {
    return null;
  }
}
