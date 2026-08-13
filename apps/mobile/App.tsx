/**
 * Auth entry point: restores a verified session on launch, otherwise shows
 * sign-in. No navigation library - there are exactly two screens, and which
 * one renders is a function of auth state, not a route.
 *
 * @format
 */

import { useEffect, useState } from 'react';
import { ActivityIndicator, StyleSheet } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';

import type { JfAuthResult } from '@cascade/core';

import { platform } from './src/platform';
import {
  clearSession,
  getOrCreateDeviceId,
  loadStoredSession,
  saveSession,
  verifySession,
  type StoredSession,
} from './src/auth/session';
import SignInScreen from './src/screens/SignInScreen';
import SignedInScreen from './src/screens/SignedInScreen';

type AuthState =
  | { status: 'loading' }
  | { status: 'signedOut'; serverUrl?: string; username?: string; error?: string }
  | { status: 'signedIn'; session: StoredSession };

function App() {
  const [auth, setAuth] = useState<AuthState>({ status: 'loading' });
  const [deviceId, setDeviceId] = useState('');
  const [appVersion, setAppVersion] = useState('');

  useEffect(() => {
    let cancelled = false;

    (async () => {
      // Needed before any request - it goes into every Jellyfin auth header -
      // so this runs ahead of the stored-session check below.
      const id = await getOrCreateDeviceId(platform.store);
      const version = await platform.getVersion();
      if (cancelled) return;
      setDeviceId(id);
      setAppVersion(version);

      const stored = await loadStoredSession(platform.store);
      if (cancelled) return;
      if (!stored) {
        setAuth({ status: 'signedOut' });
        return;
      }

      // A stored token can have been revoked server-side; only trust it after
      // a live request succeeds, so a revoked session bounces to sign-in
      // instead of showing an empty, half-broken app.
      const ok = await verifySession(stored, id);
      if (cancelled) return;
      setAuth(
        ok
          ? { status: 'signedIn', session: stored }
          : {
              status: 'signedOut',
              serverUrl: stored.serverUrl,
              username: stored.username,
              error: 'Your session expired. Sign in again.',
            },
      );
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  async function handleSignedIn(result: JfAuthResult, serverUrl: string, password?: string) {
    const session: StoredSession = {
      serverUrl,
      token: result.AccessToken,
      userId: result.User.Id,
      username: result.User.Name || '',
    };
    await saveSession(platform.store, session, password);
    setAuth({ status: 'signedIn', session });
  }

  async function handleSignOut() {
    if (auth.status !== 'signedIn') return;
    const { serverUrl, username } = auth.session;
    await clearSession(platform.store);
    setAuth({ status: 'signedOut', serverUrl, username });
  }

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.container}>
        {auth.status === 'loading' && <ActivityIndicator style={styles.loading} size="large" />}

        {auth.status === 'signedOut' && (
          <SignInScreen
            deviceId={deviceId}
            appVersion={appVersion}
            initialServerUrl={auth.serverUrl}
            initialUsername={auth.username}
            initialError={auth.error}
            onSignedIn={handleSignedIn}
          />
        )}

        {auth.status === 'signedIn' && <SignedInScreen session={auth.session} onSignOut={handleSignOut} />}
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  loading: {
    flex: 1,
    justifyContent: 'center',
  },
});

export default App;
