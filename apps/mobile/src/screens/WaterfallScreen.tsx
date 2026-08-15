/**
 * Hosting or joining a Waterfall room.
 *
 * Deliberately plain: the interesting behaviour is all in WaterfallService and
 * the protocol in core. This is a code, two buttons and a roster.
 *
 * @format
 */
import { useState } from 'react';
import { ActivityIndicator, Platform, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { useNavigation } from '@react-navigation/native';

import { useWaterfall, waterfallService } from '../waterfall/WaterfallService';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

const INPUT_HEIGHT = Platform.isTV ? 72 : 44;

function Button({
  label,
  onPress,
  disabled,
  secondary,
}: {
  label: string;
  onPress: () => void;
  disabled?: boolean;
  secondary?: boolean;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      disabled={disabled}
      style={({ focused, pressed }) => [
        styles.button,
        secondary && styles.buttonSecondary,
        (focused || pressed) && styles.buttonFocused,
        disabled && styles.buttonDisabled,
      ]}>
      <Text style={styles.buttonText}>{label}</Text>
    </Pressable>
  );
}

function WaterfallScreen() {
  const room = useWaterfall();
  const navigation = useNavigation();
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);

  async function run(fn: () => Promise<void>) {
    setBusy(true);
    try {
      await fn();
    } catch {
      // The service already put the reason in its snapshot; nothing to add.
    } finally {
      setBusy(false);
    }
  }

  if (room.status === 'connected') {
    return (
      <View style={styles.container}>
        <Text style={styles.heading}>{room.role === 'host' ? 'Hosting' : 'Listening along'}</Text>
        <Text style={styles.code}>{room.code}</Text>
        <Text style={styles.hint}>
          {room.role === 'host'
            ? 'Others can join with this code.'
            : 'Playback follows the host.'}
        </Text>

        <Text style={styles.rosterLabel}>In the room</Text>
        {room.roster.length === 0 ? (
          <Text style={styles.hint}>Nobody else yet.</Text>
        ) : (
          room.roster.map(m => (
            <Text key={m.id} style={styles.rosterName}>
              {m.name}
            </Text>
          ))
        )}

        <Button label="Leave room" secondary onPress={() => waterfallService.leave()} />
        <Button label="Back" secondary onPress={() => navigation.goBack()} />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Text style={styles.heading}>Waterfall</Text>
      <Text style={styles.hint}>Listen to the same thing, in sync, on different devices.</Text>

      <Text style={styles.label}>Room code</Text>
      <TextInput
        style={styles.input}
        value={code}
        onChangeText={t => setCode(t.toUpperCase())}
        autoCapitalize="characters"
        autoCorrect={false}
        maxLength={8}
        placeholder="ABC12"
        placeholderTextColor={colors.text3}
        editable={!busy}
      />

      {!!room.error && <Text style={styles.error}>{room.error}</Text>}
      {(busy || room.status === 'connecting') && <ActivityIndicator style={styles.spinner} color={colors.accent} />}

      <Button
        label="Join room"
        disabled={busy || code.trim().length < 4}
        onPress={() => void run(() => waterfallService.join(code.trim()))}
      />
      <Button
        label="Host a new room"
        secondary
        disabled={busy}
        onPress={() =>
          void run(async () => {
            // The relay mints the code; this only displays it.
            setCode(await waterfallService.host());
          })
        }
      />
      <Button label="Back" secondary onPress={() => navigation.goBack()} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    padding: gutter,
    width: '100%',
    maxWidth: 640,
    alignSelf: 'center',
    backgroundColor: colors.bg,
  },
  heading: {
    fontSize: typeScale.heading,
    fontWeight: '600',
    color: colors.text,
    textAlign: 'center',
    marginBottom: spacing.sm,
  },
  code: {
    fontSize: typeScale.code,
    fontWeight: '700',
    letterSpacing: 6,
    color: colors.gradFrom,
    textAlign: 'center',
    marginVertical: spacing.lg,
  },
  label: {
    fontSize: typeScale.label,
    fontWeight: '600',
    color: colors.text2,
    marginTop: spacing.lg,
    marginBottom: spacing.xs,
  },
  input: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.md,
    height: INPUT_HEIGHT,
    fontSize: typeScale.body,
    letterSpacing: 4,
    backgroundColor: colors.surface2,
    color: colors.text,
  },
  button: {
    marginTop: spacing.lg,
    borderRadius: radius.sm,
    paddingVertical: Platform.isTV ? 18 : 12,
    alignItems: 'center',
    backgroundColor: colors.accent,
  },
  buttonSecondary: { backgroundColor: 'transparent', borderWidth: 1, borderColor: colors.accent },
  buttonFocused: { outlineWidth: 3, outlineColor: colors.text },
  buttonDisabled: { opacity: 0.5 },
  buttonText: { fontSize: typeScale.button, color: colors.text, fontWeight: '600' },
  hint: { fontSize: typeScale.hint, color: colors.text3, textAlign: 'center' },
  rosterLabel: {
    fontSize: typeScale.hint,
    fontWeight: '600',
    color: colors.text3,
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginTop: spacing.xl,
    marginBottom: spacing.xs,
    textAlign: 'center',
  },
  rosterName: { fontSize: typeScale.body, color: colors.text, textAlign: 'center' },
  error: { fontSize: typeScale.body, color: colors.red, textAlign: 'center', marginTop: spacing.md },
  spinner: { marginTop: spacing.md },
});

export default WaterfallScreen;
