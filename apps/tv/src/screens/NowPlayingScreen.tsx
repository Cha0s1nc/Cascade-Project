/**
 * The full-screen player. Remote-driven, after tvOS Apple Music, rather than a
 * copy of the desktop's #np-overlay.
 *
 * The screen rests with no chrome at all: artwork, track, and lyrics or queue.
 * Playback is the remote's job, which is the whole point -
 *
 *   Right / Left      next / previous track
 *   Select            play/pause
 *   Play/Pause key    play/pause, whether the controls are up or not
 *   Menu              first press reveals the controls, second leaves
 *   Up                back to the artwork, which also dismisses the controls
 *
 * and the controls that do appear carry only what a button press cannot say:
 * shuffle, repeat, and which panel you are looking at. There is no on-screen
 * transport. Walking a D-pad across five buttons to skip a track, when the
 * remote has skip built into it, was the clunky thing this replaces.
 *
 * They time out on their own after CHROME_HIDE_MS so the screen returns to
 * artwork without being asked.
 *
 * This is also the only screen that mounts AlbumArtBackground at full strength,
 * which is where the desktop puts it too - the blobs are large and saturated,
 * and they read as atmosphere behind a near-empty surface and as noise behind
 * anything else. The rest of the app gets the flat tint from theme's bgTint.
 *
 * What the desktop overlay has that this does not, and why:
 *   - like / sleep timer / auto-mix: not ported yet.
 *   - a seek bar: the scrubber here is a readout. Seeking by D-pad on a bar is
 *     miserable; the remote's own scrub gesture is the right tool and this does
 *     not fight it.
 *
 * @format
 */
import { useCallback, useEffect, useState } from 'react';
import {
  FlatList,
  Image,
  Pressable,
  StyleSheet,
  Text,
  TVEventControl,
  TVFocusGuideView,
  useTVEventHandler,
  View,
  useWindowDimensions,
} from 'react-native';
import { useNavigation } from '@react-navigation/native';

import type { JfItem } from '@cascade/core';

import { GlassSurface, Icon, getJellyfinClient } from '@cascade/app';
import type { IconName } from '@cascade/app';
import AlbumArtBackground from '../components/AlbumArtBackground';
import LyricsPanel from '../components/LyricsPanel';
import { playbackService, usePlaybackSnapshot } from '@cascade/app';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

/**
 * How long the controls stay up after the last remote event.
 *
 * Eight seconds, not the four this started at. Four was measured behaving
 * exactly as written and still felt broken - the controls appeared and were
 * gone again before you had finished reading the scrubber, which reads as a
 * glitch rather than as a timeout. Any remote event restarts the countdown
 * (see the handler's `chrome` branch), so moving between the buttons keeps
 * them up and the timer only really applies to walking away.
 */
const CHROME_HIDE_MS = 8000;

/** Icon box inside a Ctrl button. The button itself is 64pt; 32 leaves the
 *  circle room to read as a circle rather than as a frame around a glyph. */
const ICON_SIZE = 32;

function clock(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return '0:00';
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

/** A round control button. */
function Ctrl({
  label,
  icon,
  onPress,
  active,
  badge,
  hasTVPreferredFocus,
}: {
  label: string;
  icon: IconName;
  onPress: () => void;
  /** A toggle that is currently on - shuffle, or repeat in any mode but none. */
  active?: boolean;
  /** Superscript on the icon. Only repeat-one uses it. */
  badge?: string;
  hasTVPreferredFocus?: boolean;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ selected: !!active }}
      onPress={onPress}
      hasTVPreferredFocus={hasTVPreferredFocus}
      style={({ focused, pressed }) => [
        styles.ctrl,
        active && styles.ctrlActive,
        (focused || pressed) && styles.ctrlFocused,
      ]}>
      <Icon name={icon} size={ICON_SIZE} color={active ? colors.text : colors.text2} />
      {!!badge && <Text style={styles.ctrlBadge}>{badge}</Text>}
    </Pressable>
  );
}

function QueueRow({
  item,
  active,
  interactive,
  onPress,
}: {
  item: JfItem;
  active: boolean;
  /** False while the controls are down - see the call site. */
  interactive: boolean;
  onPress: () => void;
}) {
  const client = getJellyfinClient();
  const artUrl = client.artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary);

  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      focusable={interactive}
      style={({ focused, pressed }) => [
        styles.qRow,
        active && styles.qRowActive,
        (focused || pressed) && styles.qRowFocused,
      ]}>
      <View style={styles.qArt}>
        {artUrl ? <Image source={{ uri: artUrl }} style={styles.qArtImage} /> : <Text style={styles.qArtFallback}>♪</Text>}
      </View>
      <View style={styles.qText}>
        <Text style={[styles.qTitle, active && styles.qTitleActive]} numberOfLines={1}>
          {item.Name}
        </Text>
        <Text style={styles.qArtist} numberOfLines={1}>
          {item.AlbumArtist || item.Artists?.[0] || ''}
        </Text>
      </View>
    </Pressable>
  );
}

function NowPlayingScreen() {
  const snapshot = usePlaybackSnapshot();
  const navigation = useNavigation();
  const client = getJellyfinClient();
  const { width } = useWindowDimensions();

  const twoUp = width >= 900;

  // The right column shows one or the other, the way the desktop's lyrics pane
  // slides over its queue rather than sitting beside it.
  const [showLyrics, setShowLyrics] = useState(false);
  // Chrome hidden is the resting state, not a mode you switch into. This is the
  // whole point of the rewrite: tvOS Apple Music shows artwork and lyrics with
  // nothing on top of them, and the remote does the playing.
  const [chrome, setChrome] = useState(false);
  // Bumped on every interaction to restart the auto-hide countdown.
  const [activity, setActivity] = useState(0);

  const item = snapshot.item;

  // Take the menu key away from the system so one press can reveal the controls
  // instead of leaving the screen. This MUST be undone on the way out or the
  // button stops working everywhere else in the app, which is a far worse bug
  // than the one it fixes.
  useEffect(() => {
    TVEventControl.enableTVMenuKey();
    return () => TVEventControl.disableTVMenuKey();
  }, []);

  const reveal = useCallback(() => {
    setChrome(true);
    setActivity(n => n + 1);
  }, []);

  // Auto-hide. Keyed on `activity` as well as `chrome` so any press while the
  // controls are up restarts the countdown rather than letting them vanish
  // mid-use.
  useEffect(() => {
    if (!chrome) return undefined;
    const t = setTimeout(() => setChrome(false), CHROME_HIDE_MS);
    return () => clearTimeout(t);
  }, [chrome, activity]);

  const togglePlay = useCallback(() => {
    if (playbackService.getSnapshot().isPaused) playbackService.resume();
    else playbackService.pause();
  }, []);

  useTVEventHandler(
    useCallback(
      (evt: { eventType: string }) => {
        switch (evt.eventType) {
          // The dedicated play/pause key always means play/pause, controls up
          // or not.
          case 'playPause':
            togglePlay();
            return;
          case 'menu':
            // One press reveals; a second leaves. Without the first step the
            // controls would be unreachable, since nothing on screen hints at
            // them.
            if (chrome) navigation.goBack();
            else reveal();
            return;
          case 'up':
            // Going up is going back to the artwork and lyrics, which is the
            // same gesture as dismissing the controls.
            setChrome(false);
            return;
          case 'down':
            reveal();
            return;
          default:
            break;
        }

        // Once the controls are up the D-pad belongs to them - otherwise moving
        // focus from shuffle to repeat would also skip a track.
        if (chrome) {
          setActivity(n => n + 1);
          return;
        }

        switch (evt.eventType) {
          case 'right':
            playbackService.next();
            break;
          case 'left':
            playbackService.previous();
            break;
          case 'select':
            togglePlay();
            break;
          default:
            break;
        }
      },
      [chrome, navigation, reveal, togglePlay],
    ),
  );

  useEffect(() => {
    // Nothing playing means nothing to show. Bounce rather than render an empty
    // shell the remote can get stuck in.
    if (!item) navigation.goBack();
  }, [item, navigation]);

  if (!item) return null;

  const artUrl = client.artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary);
  const artist = item.AlbumArtist || item.Artists?.[0] || '';
  const album = item.Album || '';

  const position = snapshot.positionSec;
  const duration = snapshot.durationSec || 0;
  const progress = duration > 0 ? Math.min(1, Math.max(0, position / duration)) : 0;

  return (
    <View style={styles.root}>
      <AlbumArtBackground />

      <View style={[styles.body, twoUp && styles.bodyTwoUp]}>
        {/* The artwork is a focus target, and it has to be one even though it
            looks like decoration.
            
            tvOS routes remote button events through the focus engine: with
            nothing on screen focusable, the app receives no presses at all and
            every one of the handlers above is dead. Making the art focusable is
            also what Apple does - the artwork is what focus rests on while the
            controls are down - and it gives Select somewhere honest to land. */}
        <View style={styles.left}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={snapshot.isPaused ? 'Play' : 'Pause'}
            hasTVPreferredFocus
            onPress={togglePlay}
            style={styles.artPress}>
            <View style={styles.art}>
              {artUrl ? <Image source={{ uri: artUrl }} style={styles.artImage} /> : <Text style={styles.artFallback}>♪</Text>}
            </View>

            <View style={styles.info}>
              <Text style={styles.track} numberOfLines={2}>
                {item.Name}
              </Text>
              <Text style={styles.artist} numberOfLines={1}>
                {[artist, album].filter(Boolean).join(' · ')}
              </Text>
            </View>
          </Pressable>

          {/* The reveal target, and it has to be a sibling directly under the
              artwork rather than a strip pinned to the bottom of the screen.
              The first attempt was pinned, and it never got focus: the artwork
              Pressable is flex:1, so its frame already covered the bottom of
              this column and the focus engine found nothing below it to move
              to. Down from the artwork now lands here, deterministically. */}
          {!chrome && (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Show controls"
              onFocus={reveal}
              onPress={reveal}
              style={styles.revealZone}
            />
          )}
        </View>

        {/* A focus guide for the same reason the nav shell is one: tvOS only
            moves focus to something directly in the direction you press, and
            this column starts at the top while the controls sit at the bottom. */}
        <TVFocusGuideView autoFocus style={[styles.right, twoUp && styles.rightTwoUp]}>
          {showLyrics ? (
            <LyricsPanel item={item} />
          ) : (
            <>
              <Text style={styles.queueLabel}>Queue</Text>
              <FlatList
                style={styles.queue}
                data={snapshot.queue}
                keyExtractor={(t, i) => `${t.Id}:${i}`}
                renderItem={({ item: t, index }) => (
                  <QueueRow
                    item={t}
                    active={index === snapshot.index}
                    // Nothing here may take focus while the controls are down,
                    // or a queue row would swallow the Left/Right that are
                    // supposed to be skipping tracks.
                    interactive={chrome}
                    onPress={() => void playbackService.play(snapshot.queue, index)}
                  />
                )}
                contentContainerStyle={styles.queueContent}
              />
            </>
          )}
        </TVFocusGuideView>
      </View>

      {/* The controls layer. Absent entirely rather than hidden, so it holds no
          focus and costs nothing while it is down. No transport in it: skip and
          play live on the remote, where Apple puts them, and a five-button
          transport you had to walk a D-pad across was the clunky thing this
          replaces. What is left is the state you cannot express with a button
          press - shuffle, repeat, and which panel you are looking at. */}
      {/* autoFocus so focus lands in here the moment it appears, rather than
          being left on the invisible strip that summoned it. */}
      {chrome && (
        <TVFocusGuideView autoFocus style={styles.chromeGuide}>
        <GlassSurface
          style={styles.chrome}
          fallbackColor="rgba(0,0,0,0.42)"
          glassStyle="clear"
          radius={radius.lg}>
          <View style={styles.prog}>
            <Text style={styles.time}>{clock(position)}</Text>
            <View style={styles.progBar}>
              <View style={[styles.progFill, { width: `${progress * 100}%` }]} />
            </View>
            <Text style={[styles.time, styles.timeRight]}>{clock(duration)}</Text>
          </View>

          <View style={styles.chromeButtons}>
            <Ctrl
              label="Shuffle"
              icon="shuffle"
              active={snapshot.shuffle}
              hasTVPreferredFocus
              onPress={() => {
                playbackService.toggleShuffle();
                setActivity(n => n + 1);
              }}
            />
            <Ctrl
              label={snapshot.repeat === 'one' ? 'Repeat one' : snapshot.repeat === 'all' ? 'Repeat all' : 'Repeat'}
              icon="repeat"
              badge={snapshot.repeat === 'one' ? '1' : undefined}
              active={snapshot.repeat !== 'none'}
              onPress={() => {
                playbackService.cycleRepeat();
                setActivity(n => n + 1);
              }}
            />
            <Ctrl
              label={showLyrics ? 'Show queue' : 'Show lyrics'}
              icon="lyrics"
              active={showLyrics}
              onPress={() => {
                setShowLyrics(v => !v);
                setActivity(n => n + 1);
              }}
            />
          </View>
        </GlassSurface>
        </TVFocusGuideView>
      )}
    </View>
  );
}

const ART = 320;

const styles = StyleSheet.create({
  root: { flex: 1 },
  closeGlyph: { fontSize: typeScale.heading, color: colors.text2, lineHeight: typeScale.heading * 1.2 },

  body: { flex: 1, paddingHorizontal: gutter, gap: spacing.xl },
  bodyTwoUp: { flexDirection: 'row' },

  left: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  artPress: { alignItems: 'center', gap: spacing.lg },
  art: {
    width: ART,
    height: ART,
    borderRadius: radius.lg,
    backgroundColor: 'rgba(255,255,255,0.06)',
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  artImage: { width: '100%', height: '100%' },
  artFallback: { fontSize: typeScale.heading, color: colors.text3 },

  info: { alignItems: 'center', gap: spacing.xs, maxWidth: 560 },
  track: { fontSize: typeScale.heading, fontWeight: '700', color: colors.text, textAlign: 'center' },
  artist: { fontSize: typeScale.body, color: colors.text2, textAlign: 'center' },

  ctrl: {
    width: 64,
    height: 64,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
  },
  ctrlFocused: { outlineWidth: 3, outlineColor: colors.text },
  // An "on" toggle has to read as on without focus sitting on it, since on a TV
  // the focus ring is somewhere else entirely most of the time.
  ctrlActive: { backgroundColor: 'rgba(255,255,255,0.16)' },
  ctrlBadge: {
    position: 'absolute',
    top: 8,
    right: 12,
    fontSize: typeScale.hint * 0.8,
    fontWeight: '700',
    color: colors.text,
  },

  // Docked to the bottom over the artwork, not a panel the layout makes room
  // for. It appears and disappears, so anything that reflowed around it would
  // make the whole screen jump every time the controls timed out.
  chromeGuide: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
  },
  chrome: {
    marginHorizontal: gutter,
    marginBottom: spacing.xl,
    paddingHorizontal: spacing.xl,
    paddingVertical: spacing.lg,
    gap: spacing.md,
    overflow: 'hidden',
  },
  // Deliberately invisible: a focus destination, not a control. tvOS Apple
  // Music shows nothing here either - you swipe down and the controls appear.
  revealZone: {
    height: 72,
    alignSelf: 'stretch',
  },
  chromeButtons: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.md,
  },
  prog: { flexDirection: 'row', alignItems: 'center', gap: spacing.md, width: '100%' },
  time: {
    fontSize: typeScale.hint,
    // text2, not text3: these sit on the glass card, and the dim tone that
    // reads fine on the flat app background disappears against a bright cover
    // showing through.
    color: colors.text2,
    minWidth: 48,
    fontVariant: ['tabular-nums'],
  },
  timeRight: { textAlign: 'right' },
  progBar: {
    flex: 1,
    height: 8,
    borderRadius: radius.pill,
    backgroundColor: 'rgba(255,255,255,0.18)',
    overflow: 'hidden',
  },
  progFill: { height: '100%', backgroundColor: colors.text, borderRadius: radius.pill },

  right: { flex: 1, minHeight: 0 },
  rightTwoUp: { maxWidth: 460 },
  queueLabel: {
    fontSize: typeScale.hint,
    fontWeight: '600',
    color: colors.text3,
    textTransform: 'uppercase',
    letterSpacing: 1,
    marginBottom: spacing.sm,
  },
  // No `flex: 1` - see the comment on MediaGrid's `container`.
  queue: { backgroundColor: 'transparent' },
  queueContent: { paddingBottom: spacing.xl },

  qRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.sm,
    borderRadius: radius.sm,
  },
  qRowActive: { backgroundColor: 'rgba(255,255,255,0.10)' },
  qRowFocused: { outlineWidth: 3, outlineColor: colors.text },
  qArt: {
    width: 56,
    height: 56,
    borderRadius: radius.sm,
    backgroundColor: 'rgba(255,255,255,0.06)',
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  qArtImage: { width: '100%', height: '100%' },
  qArtFallback: { fontSize: typeScale.hint, color: colors.text3 },
  qText: { flex: 1, minWidth: 0 },
  qTitle: { fontSize: typeScale.body, color: colors.text2, fontWeight: '600' },
  qTitleActive: { color: colors.text },
  // text2 rather than text3: this sits over the blobs, and the dimmer tone
  // that reads fine on the flat app background disappears against them.
  qArtist: { fontSize: typeScale.hint, color: colors.text2 },
});

export default NowPlayingScreen;
