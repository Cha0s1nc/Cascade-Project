/**
 * The top-level destinations, laid out differently per platform but navigating
 * identically. Phone: a bottom row, touched. TV: a focusable top row, D-pad
 * driven - `focused` from Pressable's state callback is the same pattern
 * SignInScreen's buttons already use for a TV focus ring.
 *
 * @format
 */
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { GlassSurface } from '@cascade/app';

import { colors, radius, spacing, type as typeScale } from '../theme';

export const NAV_ITEMS = ['Home', 'Albums', 'Artists', 'Songs', 'Search'] as const;
export type NavItemName = (typeof NAV_ITEMS)[number];

interface NavBarProps {
  current: string;
  onNavigate: (name: NavItemName) => void;
}

function NavBar({ current, onNavigate }: NavBarProps) {
  return (
    <GlassSurface style={[styles.bar, styles.barPhone]} fallbackColor={colors.surface}>
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
            <Text style={[styles.label, active && styles.labelActive]}>{item}</Text>
          </Pressable>
        );
      })}
    </GlassSurface>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    // No backgroundColor: GlassSurface supplies it, either as real glass or as
    // the fallback fill. Painting it here would sit a solid layer in front of
    // the glass and defeat the effect.
  },
  barPhone: {
    borderTopWidth: 1,
    borderTopColor: colors.border,
  },
  barTV: {
    borderBottomWidth: 1,
    borderBottomColor: colors.border,
  },
  item: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: spacing.sm,
    borderRadius: radius.sm,
  },
  itemActive: {
    backgroundColor: colors.surface2,
  },
  itemFocused: {
    outlineWidth: 3,
    outlineColor: colors.text,
  },
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
