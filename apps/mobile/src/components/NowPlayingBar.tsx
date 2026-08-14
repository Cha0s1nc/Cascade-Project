/**
 * Minimal now-playing chrome: art, title/artist, play/pause. Mounted once by
 * RootNavigator as a sibling of the stack (same reasoning as NavBar - it has
 * to survive every screen push, not re-mount as a screen would), and it is
 * the only place in the app that renders <Video>. Every screen reaches
 * playback through PlaybackService instead.
 *
 * No full-screen player, no queue/shuffle/repeat, no scrubber - that is 4b.
 * This is deliberately just enough to prove sound comes out of the phone.
 *
 * @format
 */
import Video from 'react-native-video';
import { Image, Platform, Pressable, StyleSheet, Text, View } from 'react-native';

import { getJellyfinClient } from '../api/client';
import { playbackService, usePlaybackSnapshot } from '../playback/PlaybackService';
import { colors, radius, spacing, type as typeScale } from '../theme';

// Bigger on TV for the same reason every other thumb/target in this app is -
// see TrackRow's THUMB_SIZE and NavBar's paddingVertical.
const ART_SIZE = Platform.isTV ? spacing.xxl * 1.5 : spacing.xxl;

function NowPlayingBar() {
  const snapshot = usePlaybackSnapshot();
  const client = getJellyfinClient();

  if (!snapshot.item) return null;

  const artUrl = client.artUrl(
    snapshot.item.AlbumId || snapshot.item.Id,
    snapshot.item.AlbumPrimaryImageTag || snapshot.item.ImageTags?.Primary,
  );
  const artist = snapshot.item.AlbumArtist || snapshot.item.Artists?.[0] || '';

  return (
    <View style={styles.bar}>
      {/* Zero-size and non-visual: this is the only <Video> mount in the app,
          and Phase 4a is audio-only, so there is nothing for it to render. */}
      {snapshot.source && (
        <Video
          style={styles.hiddenPlayer}
          source={snapshot.source}
          paused={snapshot.isPaused}
          playInBackground
          // Music has to keep playing with the phone's silent switch flipped,
          // the same expectation every music app sets - unlike video, where
          // that switch is usually meant to be obeyed.
          ignoreSilentSwitch="ignore"
          showNotificationControls
          progressUpdateInterval={1000}
          ref={playbackService.attachPlayer}
          onLoad={playbackService.handleLoad}
          onProgress={playbackService.handleProgress}
          onEnd={playbackService.handleEnd}
          onError={playbackService.handleError}
          onPlaybackStateChanged={playbackService.handlePlaybackStateChanged}
        />
      )}

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

      <Pressable
        accessibilityRole="button"
        accessibilityLabel={snapshot.isPaused ? 'Play' : 'Pause'}
        onPress={() => (snapshot.isPaused ? playbackService.resume() : playbackService.pause())}
        style={({ focused, pressed }) => [styles.playButton, (focused || pressed) && styles.playButtonFocused]}>
        <Text style={styles.playIcon}>{snapshot.isPaused ? '▶' : '⏸'}</Text>
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
    paddingHorizontal: spacing.lg,
    backgroundColor: colors.surface,
    borderTopWidth: 1,
    borderTopColor: colors.border,
  },
  hiddenPlayer: {
    width: 0,
    height: 0,
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
