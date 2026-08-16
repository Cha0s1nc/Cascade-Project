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
    alignItems: 'center',
    gap: spacing.xs,
    // No background: the glass pill around this supplies it.
  },
  barPhone: {
    borderTopWidth: 1,
    borderTopColor: colors.border,
  },
  barTV: {},
  // Hugs its label instead of flex:1. Stretching four items across a 900pt
  // slab is what made this read as a toolbar rather than a tab bar; tvOS sizes
  // a tab bar to its content and lets it sit in the space around it.
  item: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    // Roomy on purpose. This is read from across a room, and a tab bar sized
    // like a phone's looks like a mistake on a 1920-wide panel.
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.xl,
    borderRadius: radius.pill,
  },
  itemActive: {
    backgroundColor: 'rgba(255,255,255,0.10)',
  },
  // Focus is a filled capsule and a small lift, not a hard ring. The ring was
  // a rectangle with square corners drawn over a rounded capsule, which is the
  // single clunkiest thing on this screen - tvOS moves focus by growing and
  // brightening the thing you are on.
  itemFocused: {
    backgroundColor: 'rgba(255,255,255,0.22)',
    transform: [{ scale: 1.06 }],
  },
  icon: { fontSize: 28, lineHeight: 32, color: colors.text2 },
  iconActive: { color: colors.text },
  label: {
    fontSize: typeScale.body,
    color: colors.text2,
    fontWeight: '600',
  },
  labelActive: {
    color: colors.text,
  },
});

export default NavBar;
