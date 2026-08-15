/**
 * Sign-in screen: server URL, then username/password or Quick Connect.
 * Mirrors the decisions in apps/desktop/renderer.js's #setup-overlay flow
 * (probeQuickConnect, setup-quickconnect, setup-connect) without its DOM code.
 *
 * @format
 */

import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import {
  authenticate,
  quickConnectApproved,
  quickConnectAuthenticate,
  quickConnectEnabled,
  quickConnectInitiate,
  QUICK_CONNECT_POLL_MS,
  QUICK_CONNECT_TIMEOUT_MS,
} from '@cascade/core';
import type { JfAuthResult } from '@cascade/core';

import { normalizeServerUrl } from '@cascade/app';
import { colors, radius, type as typeScale } from '../theme';

// How long to wait after the last keystroke before asking the server whether
// Quick Connect is enabled - same debounce renderer.js's probeQuickConnect
// uses, so typing a URL doesn't fire a request per character.
const QUICK_CONNECT_PROBE_DEBOUNCE_MS = 500;

// Fixed field height. Bigger on tvOS because it is read from across a room and
// driven with a remote, not a fingertip.
const INPUT_HEIGHT = Platform.isTV ? 72 : 44;

type QuickConnectState =
  | { status: 'idle' }
  | { status: 'polling'; code: string; secret: string; deadline: number };

interface SignInScreenProps {
  deviceId: string;
  appVersion: string;
  initialServerUrl?: string;
  initialUsername?: string;
  initialError?: string;
  onSignedIn: (auth: JfAuthResult, serverUrl: string, password?: string) => Promise<void>;
}

/** Turn a thrown auth error into the one of three messages the user actually
 *  needs - same triage renderer.js's setup-connect catch block does. */
function describeAuthError(err: unknown): string {
  const message = err instanceof Error ? err.message : String(err);
  if (/\b401\b/.test(message) || /unauthorized/i.test(message)) {
    return 'Incorrect username or password.';
  }
  // React Native's fetch reports a dead host as "Network request failed";
  // the browser wording ("Failed to fetch") is matched too in case this ever
  // runs somewhere that shares more of the web fetch implementation.
  if (/network/i.test(message)) {
    return 'Could not reach the server. Check your URL.';
  }
  return `Connection failed: ${message}`;
}

function SignInScreen({
  deviceId,
  appVersion,
  initialServerUrl,
  initialUsername,
  initialError,
  onSignedIn,
}: SignInScreenProps) {
  const [serverUrlInput, setServerUrlInput] = useState(initialServerUrl ?? '');
  const [username, setUsername] = useState(initialUsername ?? '');
  const [password, setPassword] = useState('');
  const [quickConnectAvailable, setQuickConnectAvailable] = useState(false);
  const [quickConnect, setQuickConnect] = useState<QuickConnectState>({ status: 'idle' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(initialError ?? '');

  const url = normalizeServerUrl(serverUrlInput);

  // Probe once the URL settles, same trigger as renderer.js's #setup-url
  // input listener. quickConnectEnabled() never throws, so no try/catch here.
  useEffect(() => {
    if (!url) {
      setQuickConnectAvailable(false);
      return undefined;
    }
    const timer = setTimeout(async () => {
      setQuickConnectAvailable(await quickConnectEnabled(url));
    }, QUICK_CONNECT_PROBE_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [url]);

  // Poll for approval. The cleanup - which runs on unmount, on Cancel (status
  // flips away from 'polling') and before every re-run - is what stops a
  // leaked interval from hitting the server after the user has moved on.
  useEffect(() => {
    if (quickConnect.status !== 'polling') return undefined;
    const { secret, deadline } = quickConnect;
    let cancelled = false;

    const interval = setInterval(async () => {
      if (cancelled) return;

      if (Date.now() > deadline) {
        clearInterval(interval);
        if (!cancelled) {
          setError('That code expired. Try again.');
          setQuickConnect({ status: 'idle' });
        }
        return;
      }

      let approved = false;
      try {
        approved = await quickConnectApproved(url, secret);
      } catch {
        approved = false; // treat like "not yet" - the timeout still applies
      }
      if (cancelled || !approved) return;

      clearInterval(interval);
      try {
        const auth = await quickConnectAuthenticate(url, secret, appVersion, deviceId);
        if (cancelled) return;
        setQuickConnect({ status: 'idle' });
        await onSignedIn(auth, url);
      } catch {
        if (!cancelled) {
          setError('Approved, but signing in failed. Try again.');
          setQuickConnect({ status: 'idle' });
        }
      }
    }, QUICK_CONNECT_POLL_MS);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [quickConnect.status]);

  async function handlePasswordSignIn() {
    if (!url) {
      setError('Server URL and username are required.');
      return;
    }
    if (!username.trim() || !password) {
      setError('Server URL and username are required.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      const auth = await authenticate(url, username.trim(), password, appVersion, deviceId);
      await onSignedIn(auth, url, password);
    } catch (err) {
      setError(describeAuthError(err));
    } finally {
      setBusy(false);
    }
  }

  async function handleStartQuickConnect() {
    if (!url) {
      setError('Enter your server URL first.');
      return;
    }
    setError('');
    setBusy(true);
    try {
      const start = await quickConnectInitiate(url, appVersion, deviceId);
      setQuickConnect({
        status: 'polling',
        code: start.Code,
        secret: start.Secret,
        deadline: Date.now() + QUICK_CONNECT_TIMEOUT_MS,
      });
    } catch {
      setError('Could not start Quick Connect on that server.');
    } finally {
      setBusy(false);
    }
  }

  function handleCancelQuickConnect() {
    setQuickConnect({ status: 'idle' });
    setError('');
  }

  if (quickConnect.status === 'polling') {
    return (
      <View style={styles.container}>
        <Text style={styles.heading}>Enter this code on a signed-in device</Text>
        <Text style={styles.code}>{quickConnect.code}</Text>
        <Text style={styles.hint}>Waiting for approval…</Text>
        {!!error && <Text style={styles.error}>{error}</Text>}
        <Pressable
          accessibilityRole="button"
          onPress={handleCancelQuickConnect}
          style={({ focused, pressed }) => [styles.button, styles.secondaryButton, (focused || pressed) && styles.buttonFocused]}>
          <Text style={styles.secondaryButtonText}>Cancel</Text>
        </Pressable>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Text style={styles.heading}>Sign in to Jellyfin</Text>

      <Text style={styles.label}>Server URL</Text>
      <TextInput
        style={styles.input}
        value={serverUrlInput}
        onChangeText={setServerUrlInput}
        placeholder="https://jellyfin.example.com"
        placeholderTextColor={colors.text3}
        autoCapitalize="none"
        autoCorrect={false}
        keyboardType="url"
        editable={!busy}
      />

      <Text style={styles.label}>Username</Text>
      <TextInput
        style={styles.input}
        value={username}
        onChangeText={setUsername}
        autoCapitalize="none"
        autoCorrect={false}
        editable={!busy}
      />

      <Text style={styles.label}>Password</Text>
      <TextInput
        style={styles.input}
        value={password}
        onChangeText={setPassword}
        secureTextEntry
        editable={!busy}
      />

      {!!error && <Text style={styles.error}>{error}</Text>}

      <Pressable
        accessibilityRole="button"
        onPress={handlePasswordSignIn}
        disabled={busy}
        style={({ focused, pressed }) => [styles.button, (focused || pressed) && styles.buttonFocused, busy && styles.buttonDisabled]}>
        {busy ? <ActivityIndicator color="#fff" /> : <Text style={styles.buttonText}>Sign In</Text>}
      </Pressable>

      {quickConnectAvailable && (
        <Pressable
          accessibilityRole="button"
          onPress={handleStartQuickConnect}
          disabled={busy}
          style={({ focused, pressed }) => [styles.button, styles.secondaryButton, (focused || pressed) && styles.buttonFocused]}>
          <Text style={styles.secondaryButtonText}>Sign in with a code instead</Text>
        </Pressable>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    padding: 24,
    // A TV is 1920 or 3840 points across and watched from the other side of a
    // room. Uncapped, every field spanned the whole screen - working, but
    // visibly never looked at. Capped and centred reads the same on a phone.
    width: '100%',
    maxWidth: 640,
    alignSelf: 'center',
  },
  heading: {
    fontSize: typeScale.heading,
    fontWeight: '600',
    marginBottom: 24,
    textAlign: 'center',
    color: colors.text,
  },
  label: {
    fontSize: typeScale.label,
    fontWeight: '600',
    marginTop: 12,
    marginBottom: 4,
    color: colors.text2,
  },
  input: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    paddingHorizontal: 12,
    // An explicit height rather than vertical padding: tvOS grows a focused
    // UITextField, and a padding-sized field grows with it, so the fields end
    // up different heights and everything below them shifts.
    height: INPUT_HEIGHT,
    fontSize: typeScale.body,
    backgroundColor: colors.surface2,
    color: colors.text,
  },
  button: {
    marginTop: 20,
    borderRadius: radius.sm,
    paddingVertical: Platform.isTV ? 18 : 12,
    alignItems: 'center',
    backgroundColor: colors.accent,
  },
  // The only cue on a TV that says which control the D-pad is on, so it has to
  // be unmissable from across a room rather than a subtle tint.
  buttonFocused: {
    outlineWidth: 3,
    outlineColor: colors.text,
    opacity: 1,
  },
  buttonDisabled: {
    opacity: 0.6,
  },
  buttonText: {
    fontSize: typeScale.button,
    color: colors.text,
    fontWeight: '600',
  },
  secondaryButton: {
    backgroundColor: 'transparent',
    borderWidth: 1,
    borderColor: colors.accent,
  },
  secondaryButtonText: {
    fontSize: typeScale.button,
    color: colors.text,
    fontWeight: '600',
  },
  error: {
    fontSize: typeScale.body,
    color: colors.red,
    marginTop: 16,
    textAlign: 'center',
  },
  code: {
    fontSize: typeScale.code,
    fontWeight: '700',
    textAlign: 'center',
    letterSpacing: 4,
    marginVertical: 16,
    color: colors.gradFrom,
  },
  hint: {
    fontSize: typeScale.hint,
    textAlign: 'center',
    color: colors.text3,
  },
});

export default SignInScreen;
