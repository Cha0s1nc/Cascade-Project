/**
 * Placeholder for a signed-in session: who you are, and a way to leave.
 * Library browsing is Phase 3.
 *
 * @format
 */

import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { StoredSession } from '../auth/session';

interface SignedInScreenProps {
  session: StoredSession;
  onSignOut: () => void;
}

/** Host + port only, no scheme - this is just for display. Plain string
 *  stripping rather than `new URL(...).host`: React Native's URL type (see
 *  react-native/src/types/globals.d.ts) only declares href/searchParams, not
 *  the parsed-component accessors the runtime polyfill actually has. */
function serverLabel(serverUrl: string): string {
  return serverUrl.replace(/^[a-z]+:\/\//i, '').replace(/\/+$/, '');
}

function SignedInScreen({ session, onSignOut }: SignedInScreenProps) {
  return (
    <View style={styles.container}>
      <Text style={styles.heading}>Signed in</Text>
      <Text style={styles.label}>Server</Text>
      <Text style={styles.value}>{serverLabel(session.serverUrl)}</Text>
      <Text style={styles.label}>Username</Text>
      <Text style={styles.value}>{session.username || session.userId}</Text>

      <Pressable
        accessibilityRole="button"
        onPress={onSignOut}
        style={({ focused, pressed }) => [styles.button, (focused || pressed) && styles.buttonFocused]}>
        <Text style={styles.buttonText}>Sign Out</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    padding: 24,
  },
  heading: {
    fontSize: 22,
    fontWeight: '600',
    marginBottom: 24,
    textAlign: 'center',
  },
  label: {
    fontWeight: '600',
    marginTop: 12,
  },
  value: {
    marginTop: 2,
  },
  button: {
    marginTop: 32,
    borderRadius: 6,
    paddingVertical: 12,
    alignItems: 'center',
    backgroundColor: '#cc3333',
  },
  buttonFocused: {
    outlineWidth: 2,
    outlineColor: '#fff',
    opacity: 0.85,
  },
  buttonText: {
    color: '#fff',
    fontWeight: '600',
  },
});

export default SignedInScreen;
