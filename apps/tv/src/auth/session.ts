// Device identity and session persistence for the sign-in flow.
//
// Mirrors the semantics of apps/desktop/renderer.js's init()/migrateDeviceId()
// and the setup-connect/logout handlers, not their DOM-bound code: a stable
// per-install device id, a stored session that is verified (not just
// trusted) on launch, and a sign-out that only clears credentials.

import { JellyfinClient } from '@cascade/core';
import type { PlatformStorage } from '@cascade/core';

// Same key renderer.js's init() uses for window.cascade.store.get('deviceId'),
// so a future settings sync between platforms is a straight copy.
const DEVICE_ID_KEY = 'deviceId';

/**
 * The device id Jellyfin uses to tell sessions apart, and that remote control
 * uses to target one - see authHeader() in @cascade/core. Generated once per
 * install and cached in the platform store, matching renderer.js's init():
 * check the store first, only generate if nothing is there.
 */
export async function getOrCreateDeviceId(store: PlatformStorage): Promise<string> {
  const existing = await store.get(DEVICE_ID_KEY);
  if (typeof existing === 'string' && existing) return existing;

  const id = generateUuidV4();
  await store.set(DEVICE_ID_KEY, id);
  return id;
}

// ponytail: Math.random, not a CSPRNG - React Native/Hermes has no WebCrypto
// and this id isn't a secret, only needs to be unique. Swap for a real RNG
// (e.g. react-native-get-random-values) if this id ever needs to be
// unguessable, not just unique.
function generateUuidV4(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

/** Trim, drop a trailing slash, and default to https:// when the user typed a
 *  bare host - same normalisation renderer.js's setup handlers apply before
 *  every call, done once here instead of at each call site. */
export function normalizeServerUrl(input: string): string {
  const trimmed = input.trim().replace(/\/+$/, '');
  if (!trimmed) return '';
  return /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

export interface StoredSession {
  serverUrl: string;
  token: string;
  userId: string;
  username: string;
}

/** Returns null unless every field needed to reach the server is present -
 *  a partial session (e.g. serverUrl with no token) is not usable. */
export async function loadStoredSession(store: PlatformStorage): Promise<StoredSession | null> {
  const [serverUrl, token, userId, username] = await Promise.all([
    store.get('serverUrl'),
    store.get('token'),
    store.get('userId'),
    store.get('username'),
  ]);
  if (!serverUrl || !token || !userId) return null;
  return { serverUrl, token, userId, username: username || '' };
}

/**
 * Persist a session after a successful authenticate/quickConnectAuthenticate.
 *
 * `password` is only passed for a username/password sign-in; the platform
 * store routes it to the keychain, same as `token`. Quick Connect has no
 * password, and any previously stored one no longer matches how this session
 * was obtained, so it is dropped rather than left stale - same as renderer.js
 * does after a Quick Connect sign-in.
 */
export async function saveSession(
  store: PlatformStorage,
  session: StoredSession,
  password?: string,
): Promise<void> {
  await store.set('serverUrl', session.serverUrl);
  await store.set('token', session.token);
  await store.set('userId', session.userId);
  await store.set('username', session.username);
  if (password) await store.set('password', password);
  else await store.delete('password');
}

/** Sign-out clears credentials only - serverUrl/username stay so the sign-in
 *  form is still pre-filled next time, same as renderer.js's btn-logout. */
export async function clearSession(store: PlatformStorage): Promise<void> {
  await store.delete('token');
  await store.delete('userId');
  await store.delete('password');
}

/**
 * A stored token can be revoked server-side at any time, so it is only
 * trusted after a real request succeeds - same check renderer.js's connect()
 * does with `/Users/{userId}` before showing the library.
 */
export async function verifySession(session: StoredSession, deviceId: string): Promise<boolean> {
  const client = new JellyfinClient(() => ({
    url: session.serverUrl,
    token: session.token,
    userId: session.userId,
    deviceId,
  }));
  try {
    await client.get(`/Users/${session.userId}`);
    return true;
  } catch {
    return false;
  }
}
