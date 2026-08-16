/**
 * The floating capsule at the bottom of the phone: the now-playing bar stacked
 * above the four tabs, all on one piece of glass, over the content.
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
      <GlassSurface
        style={[styles.capsule, hidden && styles.capsuleHidden]}
        fallbackColor={colors.surface}
        radius={radius.lg}
        pointerEvents={hidden ? 'none' : 'auto'}>
        {/* Always mounted, even while hidden: this owns the app's only <Video>,
            so unmounting it stops playback outright. */}
        <NowPlayingBar hidden={hidden} onOpen={onOpenPlayer} floating />
        {!hidden && <NavBar current={current} onNavigate={onNavigate} />}
      </GlassSurface>
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
  },
  capsule: {
    overflow: 'hidden',
    // A hairline edge. Glass has no border of its own, and without one the
    // capsule dissolves into a light album cover behind it.
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.14)',
  },
  capsuleHidden: { opacity: 0, height: 0, borderWidth: 0 },
});
