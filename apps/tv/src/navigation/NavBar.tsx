/**
 * The top-level destinations, laid out differently per platform but navigating
 * identically. Phone: a bottom row, touched. TV: a focusable top row, D-pad
 * driven - `focused` from Pressable's state callback is the same pattern
 * SignInScreen's buttons already use for a TV focus ring.
 *
 * @format
 */
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing, type as typeScale } from '../theme';

export const NAV_ITEMS = ['Home', 'Library', 'Search', 'Settings'] as const;

/**
 * Text-presentation glyphs, matching the phone app. U+FE0E where the code point
 * is emoji-eligible, or Apple renders these as full-colour emoji beside
 * monochrome text.
 */
const ICONS: Record<NavItemName, string> = {
  Home: '⌂',
  Library: '♫',
  Search: '⌕',
  Settings: '⚙︎',
};
export type NavItemName = (typeof NAV_ITEMS)[number];

interface NavBarProps {
  current: string;
  onNavigate: (name: NavItemName) => void;
}

function NavBar({ current, onNavigate }: NavBarProps) {
  return (
    <View style={[styles.bar, styles.barTV]}>
      {NAV_ITEMS.map(item => {
        const active = item === current;
        return (
          <Pressable
            key={item}
            accessibilityRole="button"
            accessibilityState={{ selected: active }}
            onPress={() => onNavigate(item)}
            style={({ focused, pressed }) => [
              styles.item,
              active && styles.itemActive,
              (focused || pressed) && styles.itemFocused,
            ]}>
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
    // No background: the glass pill around this supplies it.
  },
  barPhone: {
    borderTopWidth: 1,
    borderTopColor: colors.border,
  },
  barTV: {},
  item: {
    flex: 1,
    alignItems: 'center',
    gap: 2,
    paddingVertical: spacing.lg,
    borderRadius: radius.sm,
  },
  itemActive: {
    backgroundColor: colors.surface2,
  },
  itemFocused: {
    outlineWidth: 3,
    outlineColor: colors.text,
  },
  icon: { fontSize: 26, lineHeight: 30, color: colors.text3 },
  iconActive: { color: colors.accent },
  label: {
    fontSize: typeScale.label,
    color: colors.text2,
    fontWeight: '600',
  },
  labelActive: {
    color: colors.accent,
  },
});

export default NavBar;
