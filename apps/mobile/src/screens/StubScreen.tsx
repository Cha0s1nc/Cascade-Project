/**
 * Placeholder for a nav destination that isn't built yet (Albums/Artists/
 * Songs/Search - Phase 3a is Home only). Says so plainly rather than
 * rendering an empty screen that looks broken.
 *
 * @format
 */
import { StyleSheet, Text, View } from 'react-native';

import { colors, spacing, type as typeScale } from '../theme';

interface StubScreenProps {
  title: string;
}

function StubScreen({ title }: StubScreenProps) {
  return (
    <View style={styles.container}>
      <Text style={styles.heading}>{title}</Text>
      <Text style={styles.body}>{title} isn't built yet.</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.xl,
    backgroundColor: colors.bg,
  },
  heading: {
    fontSize: typeScale.heading,
    fontWeight: '600',
    color: colors.text,
    marginBottom: spacing.sm,
  },
  body: {
    fontSize: typeScale.body,
    color: colors.text2,
    textAlign: 'center',
  },
});

export default StubScreen;
