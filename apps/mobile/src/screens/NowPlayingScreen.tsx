/**
 * The full-screen player, matching the desktop's #np-overlay
 * (apps/desktop/index.html:1494) rather than inventing a mobile one: a header,
 * then a body split into art + info + transport on the left and the queue on
 * the right.
 *
 * This is also the only screen that mounts AlbumArtBackground, which is where
 * the desktop puts it too - the blobs are large and saturated, and they read as
 * atmosphere behind a near-empty surface and as noise behind anything else.
 *
 * What the desktop overlay has that this does not, and why:
 *   - like / sleep timer / auto-mix: not ported yet.
 *
 * @format
 */
import { useEffect, useState } from 'react';
import {
  FlatList,
  Image,
  Pressable,
  StyleSheet,
  Text,
  TVFocusGuideView,
  View,
  useWindowDimensions,
} from 'react-native';
import { useNavigation } from '@react-navigation/native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import type { JfItem } from '@cascade/core';

import { GlassSurface, Icon, getJellyfinClient } from '@cascade/app';
import type { IconName } from '@cascade/app';
import AlbumArtBackground from '../components/AlbumArtBackground';
import LyricsPanel from '../components/LyricsPanel';
import { playbackService, usePlaybackSnapshot } from '@cascade/app';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

/** Seconds a skip button moves. Matches the desktop's back10/fwd10. */
const SKIP_SEC = 10;

// Transport glyphs, each with a U+FE0E variation selector.
//
// These code points are emoji-presentation-eligible, so without it Apple

/** Icon box inside a Ctrl button, which is 48pt. */
const ICON_SIZE = 24;

/** One VolumeUp/VolumeDown press, matching the desktop and the remote. */
const VOLUME_STEP = 0.1;

function clock(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return '0:00';
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

/** A round transport button. `primary` is the play/pause one in the middle. */
function Ctrl({
  label,
  icon,
  onPress,
  primary,
  active,
  badge,
  hasTVPreferredFocus,
}: {
  label: string;
  icon: IconName;
  onPress: () => void;
  primary?: boolean;
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
        primary && styles.ctrlPrimary,
        active && styles.ctrlActive,
        (focused || pressed) && styles.ctrlFocused,
      ]}>
      <Icon
        name={icon}
        size={primary ? ICON_SIZE * 1.15 : ICON_SIZE}
        color={primary ? '#fff' : active ? colors.text : colors.text2}
      />
      {!!badge && <Text style={styles.ctrlBadge}>{badge}</Text>}
    </Pressable>
  );
}

function QueueRow({ item, active, onPress }: { item: JfItem; active: boolean; onPress: () => void }) {
  const client = getJellyfinClient();
  const artUrl = client.artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary);

  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
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
  const { width, height } = useWindowDimensions();
  // A fullScreenModal is presented over App.tsx's SafeAreaView rather than
  // inside it, so the notch and home indicator are this screen's problem.
  // Without this the header sits on top of the status bar clock.
  const insets = useSafeAreaInsets();

  // The desktop overlay is two columns. A phone held upright has no room for
  // that, so it stacks - the same content, one column.
  // Two columns only where there is genuinely room for them - an iPad in
  // landscape. A phone stacks.
  const twoUp = width >= 900;

  // The art is whatever is left after the controls, capped so it does not
  // dominate a large phone. A fixed size overflowed short screens, which is
  // what pushed the progress bar under the queue.
  const art = Math.max(140, Math.min(ART_MAX, Math.min(width - gutter * 2, height * 0.34)));

  // Local scrub position, so dragging the bar does not fight the 1s progress
  // events still arriving from the player.
  const [scrubbing, setScrubbing] = useState<number | null>(null);
  const [barWidth, setBarWidth] = useState(0);
  // The right column shows one or the other, the way the desktop's lyrics pane
  // slides over its queue rather than sitting beside it.
  const [showLyrics, setShowLyrics] = useState(false);

  const item = snapshot.item;
  useEffect(() => {
    // Nothing playing means nothing to show. Bounce rather than render an empty
    // shell the remote can get stuck in.
    if (!item) navigation.goBack();
  }, [item, navigation]);

  if (!item) return null;

  const artUrl = client.artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary);
  const artist = item.AlbumArtist || item.Artists?.[0] || '';
  const album = item.Album || '';

  const position = scrubbing ?? snapshot.positionSec;
  const duration = snapshot.durationSec || 0;
  const progress = duration > 0 ? Math.min(1, Math.max(0, position / duration)) : 0;

  const seekBy = (delta: number) => {
    const target = Math.min(duration || Infinity, Math.max(0, snapshot.positionSec + delta));
    void playbackService.seek(target);
  };

  return (
    <View style={styles.root}>
      <AlbumArtBackground />

      <View style={[styles.header, { paddingTop: insets.top + spacing.sm }]}>
        <Text style={styles.headerTitle}>Now Playing</Text>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Close"
          onPress={() => navigation.goBack()}
          style={({ focused, pressed }) => [styles.close, (focused || pressed) && styles.closeFocused]}>
          <Text style={styles.closeGlyph}>×</Text>
        </Pressable>
      </View>

      <View style={[styles.body, twoUp && styles.bodyTwoUp]}>
        <View style={[styles.left, !twoUp && styles.leftStacked]}>
          <View style={[styles.art, { width: art, height: art }]}>
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

          {/* Transport, volume and progress ride on one glass card. This is
              the surface Liquid Glass is actually for: there is real, moving,
              colourful content behind it (the album-art background), which is
              what the effect refracts. A glass panel over a flat colour looks
              like a flat colour. */}
          <GlassSurface
            style={styles.controls}
            fallbackColor="rgba(0,0,0,0.28)"
            glassStyle="clear"
            radius={radius.lg}>
          {/* Secondary row, above the transport - the same placement as the
              desktop overlay's shuffle/repeat group.
              
              Wrapped in a focus guide because tvOS moves focus by geometry:
              these two buttons sit above the middle of a five-button transport,
              so pressing Up on Previous or Next found nothing above them and
              focus simply did not move. The guide spans the full width and
              autoFocus hands focus to a child, so Up works from anywhere in the
              row. Renders as a plain View off tvOS. */}
          <TVFocusGuideView autoFocus style={styles.secondaryGuide}>
          <View style={styles.secondary}>
            <Ctrl
              label="Shuffle"
              icon="shuffle"
              active={snapshot.shuffle}
              onPress={playbackService.toggleShuffle}
            />
            <Ctrl
              label={snapshot.repeat === 'one' ? 'Repeat one' : snapshot.repeat === 'all' ? 'Repeat all' : 'Repeat'}
              icon="repeat"
              // "one" needs to be distinguishable from "all" at a glance and
              // from across a room; the desktop swaps in an icon with a 1 in it,
              // and a superscript reads the same way without a second glyph.
              badge={snapshot.repeat === 'one' ? '1' : undefined}
              active={snapshot.repeat !== 'none'}
              onPress={playbackService.cycleRepeat}
            />
            <Ctrl
              label={showLyrics ? 'Show queue' : 'Show lyrics'}
              icon="lyrics"
              active={showLyrics}
              onPress={() => setShowLyrics(v => !v)}
            />
          </View>
          </TVFocusGuideView>

          <View style={styles.transport}>
            <Ctrl label="Previous" icon="previous" onPress={playbackService.previous} />
            {/* The desktop shows these only for video, where the arrow keys
                imply them. On a TV remote they are the only way to seek at all,
                so they are always here. */}
            <Ctrl label={`Back ${SKIP_SEC} seconds`} icon="rewind" onPress={() => seekBy(-SKIP_SEC)} />
            <Ctrl
              label={snapshot.isPaused ? 'Play' : 'Pause'}
              icon={snapshot.isPaused ? 'play' : 'pause'}
              primary
              hasTVPreferredFocus
              onPress={() => (snapshot.isPaused ? playbackService.resume() : playbackService.pause())}
            />
            <Ctrl label={`Forward ${SKIP_SEC} seconds`} icon="fastForward" onPress={() => seekBy(SKIP_SEC)} />
            <Ctrl label="Next" icon="next" onPress={playbackService.next} />
          </View>

          {/* The desktop has a slider here. Buttons instead, because the same
              row has to work under a thumb and under a D-pad, and a slider is
              only good at one of those. */}
          <View style={styles.volume}>
            <Ctrl
              label={snapshot.muted ? 'Unmute' : 'Mute'}
              icon={snapshot.muted ? 'volumeOff' : 'volume'}
              active={snapshot.muted}
              onPress={playbackService.toggleMuted}
            />
            <Ctrl
              label="Volume down"
              icon="minus"
              onPress={() => playbackService.setVolume(snapshot.volume - VOLUME_STEP)}
            />
            <View style={styles.volBar}>
              <View style={[styles.volFill, { width: `${(snapshot.muted ? 0 : snapshot.volume) * 100}%` }]} />
            </View>
            <Ctrl
              label="Volume up"
              icon="plus"
              onPress={() => playbackService.setVolume(snapshot.volume + VOLUME_STEP)}
            />
          </View>

          <View style={styles.prog}>
            <Text style={styles.time}>{clock(position)}</Text>
            <Pressable
              // Tap-to-seek is a phone gesture. A TV remote has no pointer, so
              // there the bar is a readout and the skip buttons do the seeking.
              disabled={duration <= 0}
              accessibilityRole="adjustable"
              accessibilityLabel="Seek"
              onLayout={e => setBarWidth(e.nativeEvent.layout.width)}
              onPress={e => {
                if (barWidth <= 0 || duration <= 0) return;
                const ratio = Math.min(1, Math.max(0, e.nativeEvent.locationX / barWidth));
                const target = ratio * duration;
                setScrubbing(target);
                void playbackService.seek(target).finally(() => setScrubbing(null));
              }}
              style={styles.progBar}>
              <View style={[styles.progFill, { width: `${progress * 100}%` }]} />
            </Pressable>
            <Text style={[styles.time, styles.timeRight]}>{clock(duration)}</Text>
          </View>
          </GlassSurface>
        </View>

        <View style={[styles.right, twoUp && styles.rightTwoUp]}>
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
                onPress={() => void playbackService.play(snapshot.queue, index)}
              />
            )}
            contentContainerStyle={[styles.queueContent, { paddingBottom: insets.bottom + spacing.xl }]}
          />
            </>
          )}
        </View>
      </View>
    </View>
  );
}

const ART_MAX = 260;

const styles = StyleSheet.create({
  root: { flex: 1 },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: gutter,
    paddingTop: spacing.md,
    paddingBottom: spacing.sm,
  },
  headerTitle: {
    fontSize: typeScale.label,
    fontWeight: '600',
    color: colors.text2,
    textTransform: 'uppercase',
    letterSpacing: 1,
  },
  close: {
    width: 40,
    height: 40,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
  },
  closeFocused: { outlineWidth: 3, outlineColor: colors.text },
  closeGlyph: { fontSize: typeScale.heading, color: colors.text2, lineHeight: typeScale.heading * 1.2 },

  body: { flex: 1, paddingHorizontal: gutter, gap: spacing.xl },
  bodyTwoUp: { flexDirection: 'row' },

  left: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: spacing.lg },
  // Stacked, the player takes the height it needs and the queue gets the rest.
  // Both at flex:1 split the screen evenly, which left the controls ~350pt to
  // draw ~500pt in - the progress bar and the queue ended up on top of each
  // other.
  leftStacked: { flex: 0, gap: spacing.md },
  controls: {
    alignItems: 'center',
    gap: spacing.md,
    alignSelf: 'stretch',
    paddingVertical: spacing.lg,
    paddingHorizontal: spacing.md,
    overflow: 'hidden',
  },
  art: {
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

  secondaryGuide: { width: '100%', alignItems: 'center' },
  secondary: { flexDirection: 'row', alignItems: 'center', gap: spacing.lg },
  transport: { flexDirection: 'row', alignItems: 'center', gap: spacing.lg },
  ctrl: {
    width: 48,
    height: 48,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
  },
  ctrlPrimary: {
    width: 64,
    height: 64,
    backgroundColor: colors.accent,
  },
  ctrlFocused: { outlineWidth: 3, outlineColor: colors.text },
  // An "on" toggle has to read as on without focus sitting on it, since on a TV
  // the focus ring is somewhere else entirely most of the time.
  ctrlActive: { backgroundColor: 'rgba(255,255,255,0.16)' },
  ctrlBadge: {
    position: 'absolute',
    top: 4,
    right: 8,
    fontSize: typeScale.hint * 0.8,
    fontWeight: '700',
    color: colors.text,
  },

  volume: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    width: '100%',
    maxWidth: 420,
  },
  volBar: {
    flex: 1,
    height: 4,
    borderRadius: radius.pill,
    backgroundColor: 'rgba(255,255,255,0.18)',
    overflow: 'hidden',
  },
  volFill: { height: '100%', backgroundColor: colors.text3, borderRadius: radius.pill },
  prog: { flexDirection: 'row', alignItems: 'center', gap: spacing.md, width: '100%', maxWidth: 640 },
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
    height: 6,
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
  queueContentInset: {},

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
    width: 40,
    height: 40,
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
