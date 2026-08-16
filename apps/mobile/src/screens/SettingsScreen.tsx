/**
 * Settings.
 *
 * Sign Out and Waterfall used to live in Home's header, jammed beside the
 * greeting because there was nowhere else to put them. They belong here, and
 * Home gets its greeting back.
 *
 * @format
 */
import { ScrollView, StyleSheet, Text, View, Pressable } from 'react-native';
import { useNavigation } from '@react-navigation/native';

import { isLiquidGlassSupported } from '@cascade/app';
import type { StoredSession } from '@cascade/app';

import { colors, gutter, radius, spacing, type as typeScale } from '../theme';
import { CHROME_INSET } from '../navigation/FloatingChrome';

interface SettingsScreenProps {
  session: StoredSession;
  appVersion: string;
  onSignOut: () => void;
}

function Row({
  label,
  value,
  onPress,
  destructive,
}: {
  label: string;
  value?: string;
  onPress?: () => void;
  destructive?: boolean;
}) {
  const body = (
    <View style={styles.row}>
      <Text style={[styles.rowLabel, destructive && styles.rowLabelDestructive]}>{label}</Text>
      {!!value && (
        <Text style={styles.rowValue} numberOfLines={1}>
          {value}
        </Text>
      )}
    </View>
  );

  if (!onPress) return body;
  return (
    <Pressable accessibilityRole="button" onPress={onPress} style={({ pressed }) => pressed && styles.rowPressed}>
      {body}
    </Pressable>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle}>{title}</Text>
      <View style={styles.card}>{children}</View>
    </View>
  );
}

function SettingsScreen({ session, appVersion, onSignOut }: SettingsScreenProps) {
  const navigation = useNavigation();

  return (
    <ScrollView style={styles.root} contentContainerStyle={styles.content}>
      <Text style={styles.heading}>Settings</Text>

      <Section title="Account">
        <Row label="Signed in as" value={session.username} />
        <Row label="Server" value={session.serverUrl.replace(/^https?:\/\//, '')} />
        <Row label="Sign Out" destructive onPress={onSignOut} />
      </Section>

      <Section title="Listening together">
        <Row label="Waterfall" value="Host or join a room" onPress={() => navigation.navigate('Waterfall' as never)} />
      </Section>

      <Section title="About">
        <Row label="Version" value={appVersion || '—'} />
        {/* Worth surfacing: it silently changes how the whole app looks, and
            "why does mine look different" is otherwise unanswerable. */}
        <Row label="Liquid Glass" value={isLiquidGlassSupported ? 'On' : 'Not supported on this OS'} />
      </Section>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { backgroundColor: colors.bg },
  content: { paddingHorizontal: gutter, paddingTop: spacing.lg, paddingBottom: CHROME_INSET, flexGrow: 1 },
  heading: {
    fontSize: typeScale.heading,
    fontWeight: '700',
    color: colors.text,
    marginBottom: spacing.lg,
  },
  section: { marginBottom: spacing.xl },
  sectionTitle: {
    fontSize: typeScale.hint,
    fontWeight: '600',
    color: colors.text3,
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginBottom: spacing.xs,
  },
  card: { backgroundColor: colors.surface, borderRadius: radius.md, overflow: 'hidden' },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.md,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  rowPressed: { opacity: 0.6 },
  rowLabel: { fontSize: typeScale.body, color: colors.text },
  rowLabelDestructive: { color: colors.red },
  rowValue: { fontSize: typeScale.body, color: colors.text3, flexShrink: 1, textAlign: 'right' },
});

export default SettingsScreen;
