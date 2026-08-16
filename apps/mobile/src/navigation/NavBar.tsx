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

import { colors, radius, spacing, type as typeScale } from '../theme';

export const NAV_ITEMS = ['Home', 'Library', 'Search', 'Settings'] as const;
export type NavItemName = (typeof NAV_ITEMS)[number];

/**
 * Text-presentation glyphs rather than an icon library.
 *
 * U+FE0E where the code point is emoji-eligible, for the same reason the
 * transport controls carry it: without it Apple renders these as full-colour
 * emoji beside monochrome text. An icon font would mean a native dependency and
 * a rebuild of both apps for four glyphs.
 */
const ICONS: Record<NavItemName, string> = {
  Home: '⌂',              // house
  Library: '♫',           // beamed notes - this library is music
  Search: '⌕',            // magnifier
  Settings: '⚙︎',    // gear
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
            <Text style={[styles.icon, active && styles.iconActive]}>{ICONS[item]}</Text>
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
  icon: { fontSize: 20, lineHeight: 24, color: colors.text3 },
  iconActive: { color: colors.accent },
  label: { fontSize: typeScale.hint * 0.82, color: colors.text3, fontWeight: '600' },
  labelActive: { color: colors.text },
});

export default NavBar;
