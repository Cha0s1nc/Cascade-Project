/**
 * The top-level destinations, laid out differently per platform but navigating
 * identically.
 *
 * tvOS gets a horizontal row inside a floating glass pill, which is what the
 * platform's own apps do. Android TV gets `vertical`, a left rail modelled on
 * the desktop app's sidenav - same accent bar on the active item, same
 * icon-then-label reading order. That is not a cosmetic split: Android TV has
 * no liquid glass, so a floating pill there is just a grey slab, and the
 * platform's own launcher and Leanback apps put navigation down the left edge.
 *
 * `focused` from Pressable's state callback is the same pattern SignInScreen's
 * buttons already use for a TV focus ring.
 *
 * @format
 */
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { SearchGlyph } from '@cascade/app';
import { colors, radius, spacing, type as typeScale } from '../theme';

export const NAV_ITEMS = ['Home', 'Library', 'Search', 'Settings'] as const;

const ICON_SIZE = 28;

/**
 * Text-presentation glyphs. U+FE0E where the code point is emoji-eligible, or
 * Apple renders these as full-colour emoji beside monochrome text. Search is
 * absent on purpose - see SearchGlyph for why it is drawn instead.
 */
const ICONS: Record<Exclude<NavItemName, 'Search'>, string> = {
  Home: '⌂',
  Library: '♫',
  Settings: '⚙︎',
};
export type NavItemName = (typeof NAV_ITEMS)[number];

interface NavBarProps {
  current: string;
  onNavigate: (name: NavItemName) => void;
  /** Left rail instead of a horizontal row - Android TV. */
  vertical?: boolean;
}

function NavBar({ current, onNavigate, vertical }: NavBarProps) {
  return (
    <View style={vertical ? styles.rail : styles.bar}>
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
              vertical && styles.itemVertical,
              active && styles.itemActive,
              (focused || pressed) && (vertical ? styles.itemFocusedVertical : styles.itemFocused),
            ]}>
            {/* The desktop sidenav's accent bar, rendered always and hidden by
                opacity rather than conditionally - a bar that appears and
                disappears shifts every label by its width as focus moves. */}
            {vertical && <View style={[styles.accentBar, active && styles.accentBarActive]} />}
            {item === 'Search' ? (
              <SearchGlyph size={ICON_SIZE} color={active ? colors.text : colors.text2} style={styles.glyph} />
            ) : (
              <Text style={[styles.icon, active && styles.iconActive]}>{ICONS[item]}</Text>
            )}
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
  rail: {
    flexDirection: 'column',
    alignItems: 'stretch',
    gap: spacing.xs,
  },
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
  // In the rail every item is the rail's width, so a rounded rectangle reads
  // better than a pill and the left padding is tightened to make room for the
  // accent bar.
  itemVertical: {
    paddingHorizontal: spacing.md,
    borderRadius: radius.md,
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
  // No scale in the rail: an item as wide as the rail grows past its edge and
  // clips. Brightness alone carries focus here.
  itemFocusedVertical: {
    backgroundColor: 'rgba(255,255,255,0.22)',
  },
  accentBar: {
    width: 4,
    alignSelf: 'stretch',
    marginRight: spacing.xs,
    borderRadius: 2,
    backgroundColor: colors.accent,
    opacity: 0,
  },
  accentBarActive: {
    opacity: 1,
  },
  icon: { fontSize: ICON_SIZE, lineHeight: 32, color: colors.text2 },
  iconActive: { color: colors.text },
  // The drawn glyph is a box, not a line of text, so it needs the baseline
  // nudge the font metrics give the others.
  glyph: { marginVertical: 2 },
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
