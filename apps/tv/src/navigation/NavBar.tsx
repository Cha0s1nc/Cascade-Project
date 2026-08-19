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

import { Icon, type IconName } from '@cascade/app';
import { colors, radius, spacing, type as typeScale } from '../theme';

export const NAV_ITEMS = ['Home', 'Library', 'Search', 'Settings'] as const;

const ICON_SIZE = 28;

/** Contents of the solid white focused capsule. Near-black rather than pure,
 *  matching how tvOS fills a focused control. */
const FILLED_FG = '#1c1c1e';

/** The desktop app's own icons - see packages/app's Icon. */
const ICONS: Record<NavItemName, IconName> = {
  Home: 'home',
  Library: 'library',
  Search: 'search',
  Settings: 'settings',
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
              active && (vertical ? styles.itemActiveVertical : styles.itemActive),
              (focused || pressed) && (vertical ? styles.itemFocusedVertical : styles.itemFocused),
            ]}>
            {({ focused, pressed }) => {
              // On the horizontal bar the focused tab is a solid white capsule
              // with dark contents, so its icon and label have to invert. That
              // needs the focus state down here rather than only in the style
              // callback, which is what the render-prop child is for.
              const filled = !vertical && (focused || pressed);
              const tint = filled ? FILLED_FG : active ? colors.text : colors.text2;
              return (
                <>
                  {/* The desktop sidenav's accent bar, rendered always and
                      hidden by opacity rather than conditionally - a bar that
                      appears and disappears shifts every label by its width as
                      focus moves. */}
                  {vertical && <View style={[styles.accentBar, active && styles.accentBarActive]} />}
                  <Icon name={ICONS[item]} size={ICON_SIZE} color={tint} />
                  <Text style={[styles.label, { color: tint }]}>{item}</Text>
                </>
              );
            }}
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
  // The current tab while focus is somewhere else: present but quiet. It only
  // has to say "you are here", because the moment focus lands the white
  // capsule below takes over.
  itemActive: {
    backgroundColor: 'rgba(255,255,255,0.16)',
  },
  itemActiveVertical: {
    backgroundColor: 'rgba(255,255,255,0.10)',
  },
  // A solid white capsule, which is what tvOS Apple Music actually does - not
  // the translucent tint with a scale bump that was here before. The scale is
  // gone with it: Apple fills the tab rather than growing it, and growing a
  // capsule inside another capsule pushed it against the outline.
  itemFocused: {
    backgroundColor: '#fff',
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
  // No fixed-width icon column any more. That existed because ⌂, ♫ and ⚙ have
  // very different advance widths, which left every label in the rail starting
  // at a different x. Every icon is now the same ICON_SIZE box, so the labels
  // line up on their own.
  // No colour here: every caller passes one, because it depends on focus as
  // well as on which tab is current.
  label: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },

});

export default NavBar;
