/**
 * The four top-level destinations, as icons with labels.
 *
 * Four, not the previous five: Albums, Artists and Songs were three slots spent
 * on one idea - "my music, sliced differently" - and are now segments inside
 * Library, which frees a slot for Settings.
 *
 * Rendered inside FloatingChrome's glass capsule, so it paints no background of
 * its own.
 *
 * @format
 */
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Icon, type IconName } from '@cascade/app';
import { colors, radius, spacing, type as typeScale } from '../theme';

const ICON_SIZE = 20;

export const NAV_ITEMS = ['Home', 'Library', 'Search', 'Settings'] as const;
export type NavItemName = (typeof NAV_ITEMS)[number];

/** The desktop app's own icons - see packages/app's Icon. */
const ICONS: Record<NavItemName, IconName> = {
  Home: 'home',
  Library: 'library',
  Search: 'search',
  Settings: 'settings',
};

interface NavBarProps {
  current: string;
  onNavigate: (name: NavItemName) => void;
}

function NavBar({ current, onNavigate }: NavBarProps) {
  return (
    <View style={styles.bar}>
      {NAV_ITEMS.map(item => {
        const active = item === current;
        return (
          <Pressable
            key={item}
            accessibilityRole="tab"
            accessibilityState={{ selected: active }}
            accessibilityLabel={item}
            onPress={() => onNavigate(item)}
            style={({ pressed }) => [styles.item, pressed && styles.itemPressed]}>
            <Icon name={ICONS[item]} size={ICON_SIZE} color={active ? colors.accent : colors.text3} />
            <Text style={[styles.label, active && styles.labelActive]}>{item}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    // No background: the glass capsule around this supplies it.
    paddingBottom: spacing.xs,
  },
  item: {
    flex: 1,
    alignItems: 'center',
    gap: 2,
    paddingVertical: spacing.xs,
    borderRadius: radius.sm,
  },
  itemPressed: { opacity: 0.6 },
  label: { fontSize: typeScale.hint * 0.82, color: colors.text3, fontWeight: '600' },
  labelActive: { color: colors.accent },
});

export default NavBar;
