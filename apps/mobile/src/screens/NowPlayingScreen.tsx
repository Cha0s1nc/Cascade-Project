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
 *   - shuffle / repeat: PlaybackService has no such state yet. The state machine
 *     is renderer.js:2414-2536 and the plan has it moving into core; a button
 *     that does nothing is worse than no button.
 *   - volume: there is no volume in PlaybackService either, and on a TV it is
 *     the television's job.
 *   - lyrics: Phase 6.
 *   - like / sleep timer / auto-mix: not ported yet.
 *
 * @format
 */
import { useEffect, useState } from 'react';
import {
  FlatList,
  Image,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
  useWindowDimensions,
} from 'react-native';
import { useNavigation } from '@react-navigation/native';

import type { JfItem } from '@cascade/core';

import { getJellyfinClient } from '../api/client';
import AlbumArtBackground from '../components/AlbumArtBackground';
import { playbackService, usePlaybackSnapshot } from '../playback/PlaybackService';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

/** Seconds a skip button moves. Matches the desktop's back10/fwd10. */
const SKIP_SEC = 10;

// Transport glyphs, each with a U+FE0E variation selector.
//
// These code points are emoji-presentation-eligible, so without it Apple
// renders them as full-colour emoji - the controls came out as blue rounded
// squares instead of the monochrome icons the desktop draws in SVG. FE0E asks
// for the text presentation.
const GLYPH = {
  prev: '\u23EE\uFE0E',
  back: '\u23EA\uFE0E',
  play: '\u25B6\uFE0E',
  pause: '\u23F8\uFE0E',
  forward: '\u23E9\uFE0E',
  next: '\u23ED\uFE0E',
} as const;

function clock(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return '0:00';
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

/** A round transport button. `primary` is the play/pause one in the middle. */
function Ctrl({
  label,
  glyph,
  onPress,
  primary,
  hasTVPreferredFocus,
}: {
  label: string;
  glyph: string;
  onPress: () => void;
  primary?: boolean;
  hasTVPreferredFocus?: boolean;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      hasTVPreferredFocus={hasTVPreferredFocus}
      style={({ focused, pressed }) => [
        styles.ctrl,
        primary && styles.ctrlPrimary,
        (focused || pressed) && styles.ctrlFocused,
      ]}>
      <Text style={[styles.ctrlGlyph, primary && styles.ctrlGlyphPrimary]}>{glyph}</Text>
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
  const { width } = useWindowDimensions();

  // The desktop overlay is two columns. A phone held upright has no room for
  // that, so it stacks - the same content, one column.
  const twoUp = width >= 900;

  // Local scrub position, so dragging the bar does not fight the 1s progress
  // events still arriving from the player.
  const [scrubbing, setScrubbing] = useState<number | null>(null);
  const [barWidth, setBarWidth] = useState(0);

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

      <View style={styles.header}>
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
        <View style={styles.left}>
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

          <View style={styles.transport}>
            <Ctrl label="Previous" glyph={GLYPH.prev} onPress={playbackService.previous} />
            {/* The desktop shows these only for video, where the arrow keys
                imply them. On a TV remote they are the only way to seek at all,
                so they are always here. */}
            <Ctrl label={`Back ${SKIP_SEC} seconds`} glyph={GLYPH.back} onPress={() => seekBy(-SKIP_SEC)} />
            <Ctrl
              label={snapshot.isPaused ? 'Play' : 'Pause'}
              glyph={snapshot.isPaused ? GLYPH.play : GLYPH.pause}
              primary
              hasTVPreferredFocus
              onPress={() => (snapshot.isPaused ? playbackService.resume() : playbackService.pause())}
            />
            <Ctrl label={`Forward ${SKIP_SEC} seconds`} glyph={GLYPH.forward} onPress={() => seekBy(SKIP_SEC)} />
            <Ctrl label="Next" glyph={GLYPH.next} onPress={playbackService.next} />
          </View>

          <View style={styles.prog}>
            <Text style={styles.time}>{clock(position)}</Text>
            <Pressable
              // Tap-to-seek is a phone gesture. A TV remote has no pointer, so
              // there the bar is a readout and the skip buttons do the seeking.
              disabled={Platform.isTV || duration <= 0}
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
        </View>

        <View style={[styles.right, twoUp && styles.rightTwoUp]}>
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
            contentContainerStyle={styles.queueContent}
          />
        </View>
      </View>
    </View>
  );
}

const ART = Platform.isTV ? 320 : 240;

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
    width: Platform.isTV ? 56 : 40,
    height: Platform.isTV ? 56 : 40,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
  },
  closeFocused: { outlineWidth: 3, outlineColor: colors.text },
  closeGlyph: { fontSize: typeScale.heading, color: colors.text2, lineHeight: typeScale.heading * 1.2 },

  body: { flex: 1, paddingHorizontal: gutter, gap: spacing.xl },
  bodyTwoUp: { flexDirection: 'row' },

  left: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: spacing.lg },
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

  transport: { flexDirection: 'row', alignItems: 'center', gap: Platform.isTV ? spacing.xl : spacing.lg },
  ctrl: {
    width: Platform.isTV ? 64 : 48,
    height: Platform.isTV ? 64 : 48,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
  },
  ctrlPrimary: {
    width: Platform.isTV ? 84 : 64,
    height: Platform.isTV ? 84 : 64,
    backgroundColor: colors.accent,
  },
  ctrlFocused: { outlineWidth: 3, outlineColor: colors.text },
  ctrlGlyph: { fontSize: typeScale.button, color: colors.text },
  ctrlGlyphPrimary: { fontSize: typeScale.button * 1.15, color: '#fff' },

  prog: { flexDirection: 'row', alignItems: 'center', gap: spacing.md, width: '100%', maxWidth: 640 },
  time: {
    fontSize: typeScale.hint,
    color: colors.text3,
    minWidth: 48,
    fontVariant: ['tabular-nums'],
  },
  timeRight: { textAlign: 'right' },
  progBar: {
    flex: 1,
    height: Platform.isTV ? 8 : 6,
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
    width: Platform.isTV ? 56 : 40,
    height: Platform.isTV ? 56 : 40,
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
