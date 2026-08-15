/**
 * The top-level destinations, laid out differently per platform but navigating
 * identically. Phone: a bottom row, touched. TV: a focusable top row, D-pad
 * driven - `focused` from Pressable's state callback is the same pattern
 * SignInScreen's buttons already use for a TV focus ring.
 *
 * @format
 */
import { Platform, Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing, type as typeScale } from '../theme';

export const NAV_ITEMS = ['Home', 'Albums', 'Artists', 'Songs', 'Search', 'NowPlaying'] as const;
export type NavItemName = (typeof NAV_ITEMS)[number];

const LABELS: Record<NavItemName, string> = {
  Home: 'Home',
  Albums: 'Albums',
  Artists: 'Artists',
  Songs: 'Songs',
  Search: 'Search',
  NowPlaying: 'Playing',
};

interface NavBarProps {
  current: string;
  onNavigate: (name: NavItemName) => void;
  /** Hides the Now Playing entry when there is nothing to show. */
  hasTrack?: boolean;
}

function NavBar({ current, onNavigate, hasTrack }: NavBarProps) {
  // Now Playing is reachable from the now-playing bar on a phone, where a
  // finger can just touch it. On a TV it is not: focus moves geometrically, and
  // from a row in a 1400-track list the only way down is through the other 1399
  // rows. So it earns a nav entry there, and only while something is playing.
  const items = NAV_ITEMS.filter(i => i !== 'NowPlaying' || (Platform.isTV && hasTrack));

  return (
    <View style={[styles.bar, Platform.isTV ? styles.barTV : styles.barPhone]}>
      {items.map(item => {
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
            <Text style={[styles.label, active && styles.labelActive]}>{LABELS[item]}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    backgroundColor: colors.surface,
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
    paddingVertical: Platform.isTV ? spacing.lg : spacing.sm,
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
