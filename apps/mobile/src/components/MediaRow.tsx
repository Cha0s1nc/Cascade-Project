/**
 * A titled shelf of cards - used for Home's "Recently played" / "Recently
 * added" rows. MediaCard and ART_SIZE are exported so MediaGrid (Albums/
 * Artists/Search/Artist detail's grids) reuses the same card instead of a
 * second implementation.
 *
 * No Platform.isTV branch here: FlatList already gives touch scrolling on
 * phone, and Pressable's focus state (same pattern as SignInScreen's buttons)
 * already makes each card D-pad navigable on tvOS/Android TV. Splitting this
 * into two implementations would be the duplication the plan warns against -
 * one presentation genuinely covers both.
 */
import { useState } from 'react';
import { ActivityIndicator, FlatList, Image, Platform, Pressable, StyleSheet, Text, View } from 'react-native';

import { CardRowSkeleton } from './Skeleton';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

export interface MediaRowItem {
  id: string;
  title: string;
  subtitle?: string;
  /** Null means "no art" (see JellyfinClient.artUrl) - rendered as a fallback glyph, not a broken image. */
  artUrl: string | null;
}

interface MediaRowProps {
  title: string;
  items: MediaRowItem[];
  loading: boolean;
  error: Error | null;
  emptyLabel: string;
  errorLabel: string;
  onPressItem?: (item: MediaRowItem) => void;
}

// A horizontal FlatList needs a stable card width up front. Derived from the
// shared spacing scale (not platform-split) rather than a bare number, with an
// explicit TV bump - a 10-foot screen needs a bigger target than theme.spacing
// alone encodes. Exported: MediaGrid's column-count math needs the same width
// the card actually renders at.
export const ART_SIZE = spacing.xxl * 3;

/**
 * `size` overrides the card width. A grid passes the width that divides its row
 * exactly, so cards reach both edges instead of leaving a ragged strip on the
 * right; a shelf omits it and gets ART_SIZE, since a horizontal list has no row
 * width to divide.
 */
export function MediaCard({ item, onPress, size }: { item: MediaRowItem; onPress?: () => void; size?: number }) {
  const [broken, setBroken] = useState(false);
  const showArt = !!item.artUrl && !broken;
  const box = size == null ? null : { width: size, height: size };

  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={({ focused, pressed }) => [
        styles.card,
        size != null && { width: size },
        (focused || pressed) && styles.cardFocused,
      ]}>
      <View style={[styles.art, box]}>
        {showArt ? (
          <Image source={{ uri: item.artUrl as string }} style={styles.artImage} onError={() => setBroken(true)} />
        ) : (
          <Text style={styles.artFallback}>♪</Text>
        )}
      </View>
      <Text style={styles.cardTitle} numberOfLines={1}>{item.title}</Text>
      {!!item.subtitle && (
        <Text style={styles.cardSubtitle} numberOfLines={1}>{item.subtitle}</Text>
      )}
    </Pressable>
  );
}

function MediaRow({ title, items, loading, error, emptyLabel, errorLabel, onPressItem }: MediaRowProps) {
  return (
    <View style={styles.row}>
      <Text style={styles.rowTitle}>{title}</Text>

      {/* Placeholder cards rather than a spinner - same reasoning as MediaGrid. */}
      {loading && <CardRowSkeleton />}

      {!loading && error && <Text style={styles.statusText}>{errorLabel}</Text>}

      {!loading && !error && items.length === 0 && <Text style={styles.statusText}>{emptyLabel}</Text>}

      {!loading && !error && items.length > 0 && (
        <FlatList
          horizontal
          data={items}
          keyExtractor={i => i.id}
          showsHorizontalScrollIndicator={false}
          renderItem={({ item }) => <MediaCard item={item} onPress={() => onPressItem?.(item)} />}
          contentContainerStyle={styles.rowContent}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    marginBottom: spacing.xl,
  },
  rowTitle: {
    fontSize: typeScale.label,
    fontWeight: '600',
    color: colors.text2,
    marginBottom: spacing.md,
    paddingHorizontal: gutter,
  },
  statusBox: {
    paddingHorizontal: gutter,
    alignItems: 'flex-start',
  },
  statusText: {
    fontSize: typeScale.body,
    color: colors.text3,
    paddingHorizontal: gutter,
  },
  rowContent: {
    paddingHorizontal: gutter,
    gap: spacing.md,
  },
  card: {
    width: ART_SIZE,
    borderRadius: radius.md,
  },
  cardFocused: {
    outlineWidth: 3,
    outlineColor: colors.text,
  },
  art: {
    width: ART_SIZE,
    height: ART_SIZE,
    borderRadius: radius.md,
    backgroundColor: colors.surface2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
    marginBottom: spacing.xs,
  },
  artImage: {
    width: '100%',
    height: '100%',
  },
  artFallback: {
    fontSize: typeScale.heading,
    color: colors.text3,
  },
  cardTitle: {
    fontSize: typeScale.body,
    color: colors.text,
    fontWeight: '600',
  },
  cardSubtitle: {
    fontSize: typeScale.hint,
    color: colors.text3,
  },
});

export default MediaRow;
