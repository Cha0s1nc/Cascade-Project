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

import { getJellyfinClient } from '@cascade/app';
import { playbackService, usePlaybackSnapshot } from '@cascade/app';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

// Bigger on TV for the same reason every other thumb/target in this app is -
// see TrackRow's THUMB_SIZE and NavBar's paddingVertical.
const ART_SIZE = spacing.xxl * 1.5;

interface NowPlayingBarProps {
  /** True while NowPlayingScreen is up. Chrome hides; <Video> stays mounted. */
  hidden?: boolean;
  /** Sits in the TV top row beside the nav: narrower, and no separate
   *  play/pause button, since the whole chip has to stay one focus stop. */
  compact?: boolean;
  onOpen?: () => void;
}

function NowPlayingBar({ hidden, compact, onOpen }: NowPlayingBarProps) {
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

  if (compact) {
    return (
      <View style={styles.chipWrap}>
        {player}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={`Now playing: ${snapshot.item.Name}. Open player.`}
          onPress={onOpen}
          style={({ focused, pressed }) => [styles.chip, (focused || pressed) && styles.openFocused]}>
          <View style={styles.chipArt}>
            {artUrl ? (
              <Image source={{ uri: artUrl }} style={styles.artImage} />
            ) : (
              <Text style={styles.artFallback}>♪</Text>
            )}
          </View>
          <View style={styles.info}>
            <Text style={styles.chipTitle} numberOfLines={1}>
              {snapshot.item.Name}
            </Text>
            <Text style={styles.chipSubtitle} numberOfLines={1}>
              {snapshot.isLoading ? 'Loading…' : artist}
            </Text>
          </View>
        </Pressable>
      </View>
    );
  }

  return (
    <View style={styles.bar}>
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
        style={({ focused, pressed }) => [styles.playButton, (focused || pressed) && styles.playButtonFocused]}>
        <Text style={styles.playIcon}>{snapshot.isPaused ? '\u25B6\uFE0E' : '\u23F8\uFE0E'}</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.sm,
    paddingHorizontal: gutter,
    backgroundColor: colors.surface,
    borderTopWidth: 1,
    borderTopColor: colors.border,
  },
  hiddenPlayer: {
    width: 0,
    height: 0,
  },
  chipWrap: {
    // A reserved width, not a max: the nav items beside this are all flex:1 and
    // will otherwise take every spare point and squeeze the chip to its art.
    width: 300,
    justifyContent: 'center',
    backgroundColor: colors.surface,
    borderBottomWidth: 1,
    borderBottomColor: colors.border,
    paddingRight: gutter,
    paddingLeft: spacing.md,
  },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    borderRadius: radius.sm,
    padding: spacing.xs,
  },
  chipArt: {
    width: spacing.xxl,
    height: spacing.xxl,
    borderRadius: radius.sm,
    backgroundColor: colors.surface2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  chipTitle: {
    fontSize: typeScale.hint,
    color: colors.text,
    fontWeight: '600',
  },
  chipSubtitle: {
    fontSize: typeScale.hint * 0.85,
    color: colors.text3,
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
    borderRadius: radius.pill,
    backgroundColor: colors.surface2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  playButtonFocused: {
    outlineWidth: 3,
    outlineColor: colors.text,
  },
  playIcon: {
    fontSize: typeScale.button,
    color: colors.text,
  },
});

export default NowPlayingBar;
