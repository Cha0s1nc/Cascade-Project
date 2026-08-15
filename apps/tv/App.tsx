/**
 * Auth entry point: restores a verified session on launch, otherwise shows
 * sign-in. Signed-out vs signed-in is a function of auth state, not a route -
 * the navigation library only takes over once RootNavigator mounts, for what
 * happens inside a signed-in session.
 *
 * @format
 */

import { useEffect, useState } from 'react';
import { ActivityIndicator, Platform, StatusBar, StyleSheet } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';

import type { JfAuthResult } from '@cascade/core';

import { colors } from './src/theme';
import { platform } from '@cascade/app';
import { waterfallService } from '@cascade/app';
import { startRemoteControl, stopRemoteControl } from '@cascade/app';
import { initJellyfinClient } from '@cascade/app';
import {
  clearSession,
  getOrCreateDeviceId,
  loadStoredSession,
  saveSession,
  verifySession,
  type StoredSession,
} from '@cascade/app';
import SignInScreen from './src/screens/SignInScreen';
import RootNavigator from './src/navigation/RootNavigator';

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
      if (ok) {
        // Built here rather than lazily inside a screen, so every screen after
        // this point can assume getJellyfinClient() already has a client.
        await initJellyfinClient(stored, id);
        if (cancelled) return;
        waterfallService.displayName = stored.username || '';
        startRemoteControl(stored.userId);
      }
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
    await initJellyfinClient(session, deviceId);
    waterfallService.displayName = session.username || '';
    startRemoteControl(session.userId);
    setAuth({ status: 'signedIn', session });
  }

  async function handleSignOut() {
    if (auth.status !== 'signedIn') return;
    const { serverUrl, username } = auth.session;
    // Stop advertising before the token goes: a socket left open on a cleared
    // session keeps this device in other clients' "Play On" lists.
    stopRemoteControl();
    await clearSession(platform.store);
    setAuth({ status: 'signedOut', serverUrl, username });
  }

  return (
    <SafeAreaProvider>
      {/* Light glyphs, because everything behind them is now dark. tvOS has no
          status bar, so this is a no-op there rather than a special case. */}
      <StatusBar barStyle="light-content" backgroundColor={colors.bg} />
      {/* Full-bleed on tvOS. The insets exist for notches and home
          indicators; on a TV they are an overscan guess that cost the app 160
          points of width, which showed up as a grid floating in a letterboxed
          window. Content keeps clear of the edge via theme's `gutter` instead,
          which is the same protection applied where it does not shrink the
          scroller. */}
      <SafeAreaView style={styles.container} edges={Platform.isTV ? [] : undefined}>
        {auth.status === 'loading' && (
          <ActivityIndicator style={styles.loading} size="large" color={colors.accent} />
        )}

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

        {auth.status === 'signedIn' && <RootNavigator session={auth.session} onSignOut={handleSignOut} />}
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    // The root surface. Without this the safe-area insets render white and
    // frame every screen in a pale border on an otherwise dark app.
    backgroundColor: colors.bg,
  },
  loading: {
    flex: 1,
    justifyContent: 'center',
  },
});

export default App;
