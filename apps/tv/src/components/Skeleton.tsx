/**
 * Placeholder cards and rows shown while a view fetches.
 *
 * Ports apps/desktop/renderer.js's SKELETON_TEMPLATES (~line 98) - same three
 * shapes, same idea: show the layout that is coming so the screen has structure
 * instead of being empty.
 *
 * This is not decoration. Songs takes about six seconds on a real library, and a
 * lone ActivityIndicator at the top of a 3840-wide screen is indistinguishable
 * from a screen that failed - which is exactly how it got reported.
 *
 * @format
 */
import { useEffect, useRef } from 'react';
import { Animated, Platform, StyleSheet, View, useWindowDimensions } from 'react-native';

import { ART_SIZE } from './MediaRow';
import { colors, gutter, radius, spacing } from '../theme';

/** One shimmering block. Everything below is built out of these. */
function Bone({ width, height, style }: { width: number | string; height: number; style?: object }) {
  const pulse = useRef(new Animated.Value(0.4)).current;

  useEffect(() => {
    // A loop rather than a one-shot: the point is to look alive for as long as
    // the fetch takes, and that is unbounded.
    const anim = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, { toValue: 0.9, duration: 700, useNativeDriver: true }),
        Animated.timing(pulse, { toValue: 0.4, duration: 700, useNativeDriver: true }),
      ]),
    );
    anim.start();
    return () => anim.stop();
  }, [pulse]);

  return (
    <Animated.View
      style={[
        { width: width as number, height, opacity: pulse, backgroundColor: colors.surface2, borderRadius: radius.sm },
        style,
      ]}
    />
  );
}

/** Track row: index, art thumb, title/artist stack, duration. Mirrors TrackRow. */
export function TrackSkeleton() {
  const thumb = Platform.isTV ? 56 : 40;
  return (
    <View style={styles.trackRow}>
      <Bone width={thumb} height={thumb} />
      <View style={styles.trackText}>
        <Bone width="55%" height={Platform.isTV ? 18 : 13} />
        <Bone width="32%" height={Platform.isTV ? 14 : 10} style={{ marginTop: spacing.sm }} />
      </View>
      <Bone width={Platform.isTV ? 48 : 34} height={Platform.isTV ? 14 : 10} />
    </View>
  );
}

/** Grid/shelf card: square art over two lines. Mirrors MediaCard. */
export function CardSkeleton() {
  return (
    <View style={[styles.card, { width: ART_SIZE }]}>
      <Bone width={ART_SIZE} height={ART_SIZE} style={{ borderRadius: radius.md }} />
      <Bone width="80%" height={Platform.isTV ? 18 : 13} style={{ marginTop: spacing.sm }} />
      <Bone width="50%" height={Platform.isTV ? 14 : 10} style={{ marginTop: spacing.xs }} />
    </View>
  );
}

/** A screenful of track rows. Count is derived from height so it fills the
 *  viewport rather than guessing - a TV shows far more rows than a phone. */
export function TrackListSkeleton() {
  const { height } = useWindowDimensions();
  const rowHeight = Platform.isTV ? 88 : 64;
  const count = Math.max(4, Math.ceil(height / rowHeight));
  return (
    <View>
      {Array.from({ length: count }, (_, i) => <TrackSkeleton key={i} />)}
    </View>
  );
}

/** A grid of card placeholders, wrapping the same way the real grid does. */
export function CardGridSkeleton({ count }: { count?: number }) {
  const { width, height } = useWindowDimensions();
  const perRow = Math.max(2, Math.floor(width / (ART_SIZE + spacing.md)));
  const rows = Math.max(2, Math.ceil(height / (ART_SIZE + 80)));
  const n = count ?? perRow * rows;
  return (
    <View style={styles.grid}>
      {Array.from({ length: n }, (_, i) => <CardSkeleton key={i} />)}
    </View>
  );
}

/** A horizontal shelf, for Home's rows. */
export function CardRowSkeleton({ count = 8 }: { count?: number }) {
  return (
    <View style={styles.row}>
      {Array.from({ length: count }, (_, i) => <CardSkeleton key={i} />)}
    </View>
  );
}

const styles = StyleSheet.create({
  trackRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingHorizontal: gutter,
    paddingVertical: spacing.md,
  },
  trackText: { flex: 1 },
  card: { marginRight: spacing.md, marginBottom: spacing.lg },
  // No horizontal padding: this renders as MediaGrid's ListEmptyComponent,
  // inside a content container that already applies the gutter. CardRowSkeleton
  // below is a plain sibling of MediaRow's list, so it does need its own.
  grid: { flexDirection: 'row', flexWrap: 'wrap' },
  row: { flexDirection: 'row', paddingHorizontal: gutter },
});
