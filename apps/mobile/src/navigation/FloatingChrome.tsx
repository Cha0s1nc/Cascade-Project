/**
 * The floating chrome at the bottom of the phone: a mini player capsule above a
 * tab bar capsule, both glass, both over the content.
 *
 * Two capsules with a gap, not one merged block. That is what Apple Music does,
 * and the difference is not decorative: separate capsules read as two
 * independent controls, while one tall block reads as a single slab of chrome
 * and makes the player look welded to the navigation.
 *
 * Floating is what makes the glass mean anything. Docked at the bottom of a
 * column there is nothing behind it but the flat app background, so the effect
 * had nothing to refract and read as a slightly lighter bar. Over a scrolling
 * list of album art it behaves like glass because there is finally something
 * behind it.
 *
 * The cost is that content can now slide underneath, so every scrolling screen
 * has to reserve CHROME_INSET at the bottom or its last row is unreachable.
 *
 * @format
 */
import { StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { GlassSurface } from '@cascade/app';

import NavBar from './NavBar';
import type { NavItemName } from './NavBar';
import NowPlayingBar from '../components/NowPlayingBar';
import { colors, radius, spacing } from '../theme';

/**
 * Bottom padding a scrolling screen must reserve so its last row clears the
 * capsule. Deliberately generous: it covers the capsule with a track showing,
 * because the bar appears the moment something plays and a list that was
 * scrollable a second ago must not swallow its last row.
 */
export const CHROME_INSET = 168;

interface FloatingChromeProps {
  current: string;
  onNavigate: (name: NavItemName) => void;
  onOpenPlayer: () => void;
  /** True while the full player is up: the capsule hides, the player stays. */
  hidden?: boolean;
}

export default function FloatingChrome({ current, onNavigate, onOpenPlayer, hidden }: FloatingChromeProps) {
  const insets = useSafeAreaInsets();

  return (
    <View
      style={[styles.dock, { paddingBottom: Math.max(insets.bottom, spacing.md) }]}
      // The dock spans the width but only its capsule is real; taps either side
      // must reach the list underneath.
      pointerEvents="box-none">
      {/* Mini player. Always mounted, even while hidden: it owns the app's only
          <Video>, so unmounting it stops playback outright. */}
      <GlassSurface
        style={[styles.player, hidden && styles.collapsed]}
        fallbackColor={colors.surface}
        radius={radius.lg}
        pointerEvents={hidden ? 'none' : 'auto'}>
        <NowPlayingBar hidden={hidden} onOpen={onOpenPlayer} floating />
      </GlassSurface>

      {!hidden && (
        <GlassSurface style={styles.tabs} fallbackColor={colors.surface} radius={radius.lg}>
          <NavBar current={current} onNavigate={onNavigate} />
        </GlassSurface>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  dock: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    paddingHorizontal: spacing.md,
    // The gap between the two capsules. Small enough that they read as a pair,
    // large enough that they are clearly not one control.
    gap: spacing.sm,
  },
  // No border on either. Glass is not an outlined box - the same thing that
  // made the TV pills look stuck on the screen rather than in it.
  player: { overflow: 'hidden' },
  tabs: { overflow: 'hidden' },
  collapsed: { opacity: 0, height: 0 },
});
