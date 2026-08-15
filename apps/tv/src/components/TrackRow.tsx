/**
 * One row in a track list - number, thumb, title/artist, optional album
 * column, duration. Shared by Songs (thousands of rows, FlatList-virtualized),
 * Album detail (disc/track order) and Search's song group, same as
 * apps/desktop/renderer.js's trackRowHtml serves all three there.
 *
 * onPress is optional because not every list can act on a press yet. Where it
 * is passed, the caller hands the whole visible list to the player so the queue
 * continues past the row that was picked. Pressable regardless, so a row is
 * D-pad reachable on tvOS rather than a dead View that swallows focus.
 */
import { useState } from 'react';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';

import type { JfItem } from '@cascade/core';

import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

// Bigger on TV for the same reason MediaRow's ART_SIZE is - a target read
// from a couch needs to be larger than one held at arm's length.
const THUMB_SIZE = spacing.xxl * 2;
const INDEX_WIDTH = spacing.xxl;

/** RunTimeTicks is 100ns units; renderer.js's fmtTime takes seconds, so ticks
 *  are converted first. Duplicated here rather than added to core: this is
 *  display formatting, not shared domain logic. */
function fmtDuration(ticks?: number): string {
  const totalSec = Math.floor((ticks || 0) / 10_000_000);
  if (!totalSec) return '0:00';
  const m = Math.floor(totalSec / 60);
  const s = totalSec % 60;
  return `${m}:${s.toString().padStart(2, '0')}`;
}

interface TrackRowProps {
  item: JfItem;
  /** Display position (i+1), matching trackRowHtml - not IndexNumber, which
   *  resets per disc while this is the row's position in the list as sorted. */
  index: number;
  artUrl: string | null;
  /** Songs and Search show which album a track is from; Album detail omits
   *  it - every row there is already the same album. */
  showAlbum?: boolean;
  onPress?: () => void;
}

function TrackRow({ item, index, artUrl, showAlbum, onPress }: TrackRowProps) {
  const [broken, setBroken] = useState(false);
  const showArt = !!artUrl && !broken;

  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={({ focused, pressed }) => [styles.row, (focused || pressed) && styles.rowFocused]}>
      <Text style={styles.index}>{index + 1}</Text>
      <View style={styles.thumb}>
        {showArt ? (
          <Image source={{ uri: artUrl as string }} style={styles.thumbImage} onError={() => setBroken(true)} />
        ) : (
          <Text style={styles.thumbFallback}>♪</Text>
        )}
      </View>
      <View style={styles.body}>
        <Text style={styles.title} numberOfLines={1}>
          {item.Name}
        </Text>
        <Text style={styles.subtitle} numberOfLines={1}>
          {item.AlbumArtist || item.Artists?.[0] || ''}
        </Text>
      </View>
      {showAlbum && (
        <Text style={styles.album} numberOfLines={1}>
          {item.Album || ''}
        </Text>
      )}
      <Text style={styles.duration}>{fmtDuration(item.RunTimeTicks)}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.sm,
    paddingHorizontal: gutter,
    borderRadius: radius.sm,
  },
  rowFocused: {
    outlineWidth: 3,
    outlineColor: colors.text,
  },
  index: {
    width: INDEX_WIDTH,
    fontSize: typeScale.hint,
    color: colors.text3,
    textAlign: 'right',
  },
  thumb: {
    width: THUMB_SIZE,
    height: THUMB_SIZE,
    borderRadius: radius.sm,
    backgroundColor: colors.surface2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  thumbImage: {
    width: '100%',
    height: '100%',
  },
  thumbFallback: {
    fontSize: typeScale.hint,
    color: colors.text3,
  },
  body: {
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
  album: {
    flex: 1,
    minWidth: 0,
    fontSize: typeScale.hint,
    color: colors.text3,
  },
  duration: {
    fontSize: typeScale.hint,
    color: colors.text3,
  },
});

export default TrackRow;
