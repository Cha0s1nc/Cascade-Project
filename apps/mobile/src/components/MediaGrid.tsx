/**
 * The grid counterpart to MediaRow: same MediaCard, wrapped instead of
 * scrolled sideways - used by Albums, Artists, and Artist detail's album
 * grid. Search reuses MediaRow itself (a horizontal shelf reads better for a
 * few results); this is for a screen whose whole job is the grid.
 *
 * `header` renders above the grid via FlatList's ListHeaderComponent so a
 * screen like Artist detail (art + name + album grid) stays one FlatList
 * instead of nesting a second scroller inside a ScrollView.
 */
import { useMemo } from 'react';
import { ActivityIndicator, FlatList, Platform, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import type { ReactNode } from 'react';

import { CardGridSkeleton } from './Skeleton';
import { colors, spacing, type as typeScale } from '../theme';
import { ART_SIZE, MediaCard, type MediaRowItem } from './MediaRow';

interface MediaGridProps {
  items: MediaRowItem[];
  loading: boolean;
  error: Error | null;
  emptyLabel: string;
  errorLabel: string;
  onPressItem?: (item: MediaRowItem) => void;
  /** Extra content above the grid - Artist detail's art/name/meta block. */
  header?: ReactNode;
}

// However many ART_SIZE cards (plus their gap) actually fit the current
// width, floored at a platform minimum so a very narrow phone split-view
// still gets a real grid rather than one column. This is the "derived from
// platform and width" the plan asks for: width comes from the window, and
// platform already shaped ART_SIZE itself (bigger on TV), so a TV's larger
// absolute width plus its larger card still nets more columns than a phone.
const MIN_COLUMNS = Platform.isTV ? 4 : 2;
const CELL = ART_SIZE + spacing.md;

function useGridColumns(): number {
  const { width } = useWindowDimensions();
  return Math.max(MIN_COLUMNS, Math.floor(width / CELL));
}

function MediaGrid({ items, loading, error, emptyLabel, errorLabel, onPressItem, header }: MediaGridProps) {
  const columns = useGridColumns();

  const statusLabel = useMemo(() => {
    if (loading) return null;
    if (error) return errorLabel;
    if (items.length === 0) return emptyLabel;
    return null;
  }, [loading, error, items.length, errorLabel, emptyLabel]);

  return (
    <FlatList
      // numColumns can't change on a live FlatList - remounting on a column
      // change (e.g. a phone rotation) is the documented way around that.
      key={columns}
      style={styles.container}
      data={items}
      numColumns={columns}
      keyExtractor={i => i.id}
      renderItem={({ item }) => <MediaCard item={item} onPress={() => onPressItem?.(item)} />}
      columnWrapperStyle={styles.row}
      contentContainerStyle={styles.content}
      ListHeaderComponent={header ? <View style={styles.header}>{header}</View> : undefined}
      ListEmptyComponent={
        loading ? (
          // A grid of placeholders rather than a spinner: it shows the shape of
          // what is coming, and on a TV-sized screen a lone spinner is easy to
          // mistake for a screen that failed to load.
          <CardGridSkeleton />
        ) : statusLabel ? (
          <Text style={styles.statusText}>{statusLabel}</Text>
        ) : null
      }
    />
  );
}

const styles = StyleSheet.create({
  // No `flex: 1` here, and that is load-bearing rather than an oversight.
  //
  // ScrollView already composes its own baseVertical (flexGrow: 1,
  // flexShrink: 1, flexBasis: auto) under whatever style you pass, so it
  // fills its parent on its own. Adding `flex: 1` overrides flexBasis to 0,
  // and on tvOS that lands the scroll view at a 1pt frame - measured, not
  // guessed: onLayout reported 1760x1 inside a 1760x901 parent while the
  // content container measured a correct 1760x3280.
  //
  // A ScrollView survives that, because its children overflow a 1pt frame and
  // still paint - which is why Home and Search looked fine (they were also
  // silently unscrollable). A FlatList does not: it finds no room for a single
  // row and renders nothing at all, not even ListEmptyComponent. That is the
  // whole reason Albums, Artists and Songs were blank, and why it read as
  // "the data never loaded" when the data was always there.
  container: {
    backgroundColor: colors.bg,
  },
  content: {
    padding: spacing.lg,
    paddingBottom: spacing.xxl,
    // Keeps the empty/skeleton state filling the viewport now that the list
    // itself is sized by its content rather than by flex.
    flexGrow: 1,
  },
  header: {
    marginBottom: spacing.lg,
  },
  row: {
    gap: spacing.md,
    marginBottom: spacing.md,
  },
  statusBox: {
    alignItems: 'flex-start',
  },
  statusText: {
    fontSize: typeScale.body,
    color: colors.text3,
  },
});

export default MediaGrid;
