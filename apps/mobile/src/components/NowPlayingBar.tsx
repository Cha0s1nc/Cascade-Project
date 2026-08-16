/**
 * Minimal now-playing chrome: art, title/artist, play/pause. Mounted once by
 * RootNavigator as a sibling of the stack (same reasoning as NavBar - it has
 * to survive every screen push, not re-mount as a screen would), and it is
 * the only place in the app that renders <Video>. Every screen reaches
 * playback through PlaybackService instead.
 *
 * Tapping it opens NowPlayingScreen, which is the full player.
 *
 * `hidden` keeps this mounted while that screen is up instead of unmounting it.
 * That is not cosmetic: this component owns the app's only <Video>, so removing
 * it from the tree stops playback outright. Hidden means the chrome goes and the
 * player stays.
 *
 * @format
 */
import Video from 'react-native-video';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';

import { GlassSurface, getJellyfinClient } from '@cascade/app';
import { playbackService, usePlaybackSnapshot } from '@cascade/app';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

// Bigger on TV for the same reason every other thumb/target in this app is -
// see TrackRow's THUMB_SIZE and NavBar's paddingVertical.
const ART_SIZE = spacing.xxl;

interface NowPlayingBarProps {
  /** Inside FloatingChrome's capsule: no background or border of its own, and
   *  it collapses to nothing when there is no track rather than leaving a gap
   *  above the tabs. */
  floating?: boolean;
  /** True while NowPlayingScreen is up. Chrome hides; <Video> stays mounted. */
  hidden?: boolean;
  onOpen?: () => void;
}

function NowPlayingBar({ hidden, onOpen, floating }: NowPlayingBarProps) {
  const snapshot = usePlaybackSnapshot();
  const client = getJellyfinClient();

  if (!snapshot.item) return null;

  const artUrl = client.artUrl(
    snapshot.item.AlbumId || snapshot.item.Id,
    snapshot.item.AlbumPrimaryImageTag || snapshot.item.ImageTags?.Primary,
  );
  const artist = snapshot.item.AlbumArtist || snapshot.item.Artists?.[0] || '';

  // One instance, rendered by both branches below - a second <Video> would be a
  // second player.
  const player = snapshot.source && (
    <Video
          style={styles.hiddenPlayer}
          source={snapshot.source}
          paused={snapshot.isPaused}
          volume={snapshot.volume}
          muted={snapshot.muted}
          playInBackground
          // Music has to keep playing with the phone's silent switch flipped,
          // the same expectation every music app sets - unlike video, where
          // that switch is usually meant to be obeyed.
          ignoreSilentSwitch="ignore"
          showNotificationControls
          // 250ms, not the 1s a progress bar would need: synced lyrics move
          // line to line and a 1s clock makes every change land up to a second
          // late, which is exactly what the lookahead constant exists to avoid.
          progressUpdateInterval={250}
          ref={playbackService.attachPlayer}
          onLoad={playbackService.handleLoad}
          onProgress={playbackService.handleProgress}
          onEnd={playbackService.handleEnd}
          onError={playbackService.handleError}
          onPlaybackStateChanged={playbackService.handlePlaybackStateChanged}
    />
  );

  if (hidden) return <View style={styles.hiddenPlayer}>{player}</View>;

  const body = (
    <>
      {player}

      <Pressable
        accessibilityRole="button"
        accessibilityLabel={`Now playing: ${snapshot.item.Name}. Open player.`}
        onPress={onOpen}
        style={({ focused, pressed }) => [styles.open, (focused || pressed) && styles.openFocused]}>
        <View style={styles.art}>
          {artUrl ? (
            <Image source={{ uri: artUrl }} style={styles.artImage} />
          ) : (
            <Text style={styles.artFallback}>♪</Text>
          )}
        </View>

        <View style={styles.info}>
          <Text style={styles.title} numberOfLines={1}>
            {snapshot.item.Name}
          </Text>
          <Text style={styles.subtitle} numberOfLines={1}>
            {snapshot.isLoading ? 'Loading…' : artist}
          </Text>
        </View>
      </Pressable>

      <Pressable
        accessibilityRole="button"
        accessibilityLabel={snapshot.isPaused ? 'Play' : 'Pause'}
        onPress={() => (snapshot.isPaused ? playbackService.resume() : playbackService.pause())}
        style={({ focused, pressed }) => [styles.playButton, pressed && styles.playButtonPressed]}>
        <Text style={styles.playIcon}>{snapshot.isPaused ? '\u25B6\uFE0E' : '\u23F8\uFE0E'}</Text>
      </Pressable>

      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Next track"
        onPress={playbackService.next}
        style={({ pressed }) => [styles.playButton, pressed && styles.playButtonPressed]}>
        <Text style={styles.playIcon}>{'\u23ED\uFE0E'}</Text>
      </Pressable>
    </>
  );

  // Inside FloatingChrome's capsule the glass is already there; a second glass
  // layer on top of it just muddies both.
  return floating ? (
    <View style={styles.barFloating}>{body}</View>
  ) : (
    <GlassSurface style={styles.bar} fallbackColor={colors.surface}>
      {body}
    </GlassSurface>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.sm,
    paddingHorizontal: gutter,
    // No backgroundColor: GlassSurface supplies it, either as real glass or as
    // the fallback fill. Painting it here would put a solid layer in front of
    // the glass and defeat the whole effect.
    borderTopWidth: 1,
    borderTopColor: colors.border,
  },
  hiddenPlayer: {
    width: 0,
    height: 0,
  },
  barFloating: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.xs,
    paddingHorizontal: spacing.sm,
  },
  open: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    borderRadius: radius.sm,
  },
  openFocused: {
    outlineWidth: 3,
    outlineColor: colors.text,
  },
  art: {
    width: ART_SIZE,
    height: ART_SIZE,
    borderRadius: radius.sm,
    backgroundColor: colors.surface2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  artImage: {
    width: '100%',
    height: '100%',
  },
  artFallback: {
    fontSize: typeScale.hint,
    color: colors.text3,
  },
  info: {
    flex: 1,
    minWidth: 0,
  },
  title: {
    fontSize: typeScale.body,
    color: colors.text,
    fontWeight: '600',
  },
  subtitle: {
    fontSize: typeScale.hint,
    color: colors.text3,
  },
  playButton: {
    width: ART_SIZE,
    height: ART_SIZE,
    alignItems: 'center',
    justifyContent: 'center',
  },
  playButtonPressed: { opacity: 0.5 },
  playIcon: {
    fontSize: typeScale.button,
    color: colors.text,
  },
});

export default NowPlayingBar;
