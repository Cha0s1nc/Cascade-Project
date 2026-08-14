// One shared JellyfinClient per signed-in session.
//
// Screens import getJellyfinClient() rather than constructing their own -
// JellyfinClient takes a config *getter* (see its constructor comment in
// @cascade/core) specifically so there is one source of truth for the current
// session; a second client per screen would just be a second place for stale
// credentials to hide.

import { JellyfinClient } from '@cascade/core';
import type { ServerConfig } from '@cascade/core';

import { platform } from '../platform';
import type { StoredSession } from '../auth/session';

let config: ServerConfig | null = null;
let client: JellyfinClient | null = null;

/**
 * renderer.js's connect() stores this key as `JSON.stringify(ids)` and undoes
 * that with `JSON.parse` on read (see apps/desktop/renderer.js ~line 503).
 * Mobile's own store (src/platform/index.ts's mmkvStorage) already round-trips
 * every value through JSON once, so a value written *on mobile* comes back as
 * a real array - but nothing writes this key on mobile yet, so read
 * defensively for either shape rather than assuming one.
 */
async function loadLibraryIds(): Promise<string[] | undefined> {
  const raw = await platform.store.get('libraryIds');
  if (Array.isArray(raw)) return raw;
  if (typeof raw === 'string') {
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : undefined;
    } catch {
      return undefined;
    }
  }
  return undefined;
}

/**
 * Build the shared client for a signed-in session. Called once, from App.tsx,
 * whenever auth moves into the signedIn state (initial launch verification or
 * a fresh sign-in) - every screen after that calls getJellyfinClient().
 */
export async function initJellyfinClient(session: StoredSession, deviceId: string): Promise<JellyfinClient> {
  const libraryIds = await loadLibraryIds();
  config = { url: session.serverUrl, token: session.token, userId: session.userId, libraryIds, deviceId };
  client = new JellyfinClient(() => config as ServerConfig);
  return client;
}

export function getJellyfinClient(): JellyfinClient {
  if (!client) throw new Error('getJellyfinClient() called before initJellyfinClient()');
  return client;
}
