/**
 * Library: Albums, Artists and Songs behind one segmented control.
 *
 * Three separate tabs spent three of five top-level slots on what is really one
 * idea - "my music, sliced differently" - and left no room for Settings. The
 * three screens are unchanged and still self-contained; this only chooses which
 * one is on screen.
 *
 * @format
 */
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { StoredSession } from '@cascade/app';

import AlbumsScreen from './AlbumsScreen';
import ArtistsScreen from './ArtistsScreen';
import SongsScreen from './SongsScreen';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

const SECTIONS = ['Albums', 'Artists', 'Songs'] as const;
type Section = (typeof SECTIONS)[number];

function LibraryScreen({ session }: { session: StoredSession }) {
  const [section, setSection] = useState<Section>('Albums');

  return (
    <View style={styles.root}>
      <View style={styles.segments}>
        {SECTIONS.map(name => {
          const active = name === section;
          return (
            <Pressable
              key={name}
              accessibilityRole="tab"
              accessibilityState={{ selected: active }}
              onPress={() => setSection(name)}
              style={({ focused, pressed }) => [
                styles.segment,
                active && styles.segmentActive,
                (focused || pressed) && styles.segmentFocused,
              ]}>
              <Text style={[styles.segmentLabel, active && styles.segmentLabelActive]}>{name}</Text>
            </Pressable>
          );
        })}
      </View>

      {/* Mounted one at a time on purpose. Keeping all three alive would hold
          three copies of a 1400-track list in memory to save a refetch that the
          hook already caches. */}
      <View style={styles.body}>
        {section === 'Albums' && <AlbumsScreen session={session} />}
        {section === 'Artists' && <ArtistsScreen session={session} />}
        {section === 'Songs' && <SongsScreen session={session} />}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.bg },
  segments: {
    flexDirection: 'row',
    gap: spacing.xs,
    paddingHorizontal: gutter,
    paddingTop: spacing.sm,
    paddingBottom: spacing.sm,
  },
  segment: {
    paddingVertical: spacing.xs,
    paddingHorizontal: spacing.md,
    borderRadius: radius.pill,
  },
  segmentActive: { backgroundColor: colors.surface2 },
  // A ring, not an opacity change: on a TV the only cue for where the remote is
  // has to read from across a room.
  segmentFocused: { outlineWidth: 3, outlineColor: colors.text },
  segmentLabel: { fontSize: typeScale.body, color: colors.text3, fontWeight: '600' },
  segmentLabelActive: { color: colors.text },
  body: { flex: 1, minHeight: 0 },
});

export default LibraryScreen;
