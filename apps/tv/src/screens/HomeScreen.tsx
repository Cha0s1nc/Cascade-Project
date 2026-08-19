/**
 * Home: a greeting, then "Recently played" and "Recently added" - same two
 * queries as apps/desktop/renderer.js's loadHome()/loadRecentlyPlayed()/
 * loadRecentlyAdded(), reissued here because the desktop code is DOM-bound,
 * not because the queries differ.
 *
 * @format
 */
import { useMemo } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, TVFocusGuideView, View } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';

import type { JfItem } from '@cascade/core';

import { getJellyfinClient } from '@cascade/app';
import { useJellyfin } from '@cascade/app';
import type { StoredSession } from '@cascade/app';
import MediaRow, { type MediaRowItem } from '../components/MediaRow';
import type { RootStackParamList } from '../navigation/RootNavigator';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

interface HomeScreenProps {
  session: StoredSession;
  onSignOut: () => void;
}

function greeting(): string {
  const hour = new Date().getHours();
  if (hour < 12) return 'Good morning';
  if (hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/** getMerged concatenates per-library results, so the server's DatePlayed
 *  ordering only holds within one library - re-sort across the merge, same
 *  fix renderer.js's loadRecentlyPlayed applies. */
function sortByLastPlayed(items: JfItem[]): JfItem[] {
  return [...items].sort((a, b) => {
    const at = a.UserData?.LastPlayedDate ? new Date(a.UserData.LastPlayedDate).getTime() : 0;
    const bt = b.UserData?.LastPlayedDate ? new Date(b.UserData.LastPlayedDate).getTime() : 0;
    return bt - at;
  });
}

function HomeScreen({ session, onSignOut }: HomeScreenProps) {
  const client = getJellyfinClient();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();

  const recentlyPlayed = useJellyfin<JfItem[]>(async () => {
    const data = await client.getMerged(`/Users/${session.userId}/Items`, {
      SortBy: 'DatePlayed',
      SortOrder: 'Descending',
      IncludeItemTypes: 'Audio',
      Filters: 'IsPlayed',
      Limit: 8,
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData',
    });
    return sortByLastPlayed(data.Items || []).slice(0, 8);
  }, [session.userId]);

  const recentlyAdded = useJellyfin<JfItem[]>(async () => {
    const data = await client.getMerged(`/Users/${session.userId}/Items`, {
      SortBy: 'DateCreated',
      SortOrder: 'Descending',
      IncludeItemTypes: 'MusicAlbum',
      Limit: 8,
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio',
    });
    return data.Items || [];
  }, [session.userId]);

  const playedRowItems: MediaRowItem[] = useMemo(
    () =>
      (recentlyPlayed.data || []).map(item => ({
        id: item.Id,
        title: item.Name || '',
        subtitle: item.AlbumArtist || item.Artists?.[0] || '',
        artUrl: client.artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary),
      })),
    [recentlyPlayed.data, client],
  );

  const addedRowItems: MediaRowItem[] = useMemo(
    () =>
      (recentlyAdded.data || []).map(item => ({
        id: item.Id,
        title: item.Name || '',
        subtitle: item.AlbumArtist || '',
        artUrl: client.artUrl(item.Id, item.ImageTags?.Primary),
      })),
    [recentlyAdded.data, client],
  );

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      {/* Focus guide for the same reason the player's secondary row has one:
          tvOS moves focus geometrically, and these buttons are right-aligned
          above a left-aligned grid, so pressing Up from most cards found
          nothing and focus simply did not move. */}
      <Text style={styles.greeting}>
        {greeting()}, {session.username || 'there'}
      </Text>

      <MediaRow
        title="Recently played"
        items={playedRowItems}
        loading={recentlyPlayed.loading}
        error={recentlyPlayed.error}
        emptyLabel="No play history yet"
        errorLabel="Could not load history"
      />

      <MediaRow
        title="Recently added"
        items={addedRowItems}
        loading={recentlyAdded.loading}
        error={recentlyAdded.error}
        emptyLabel="No albums yet"
        errorLabel="Could not load albums"
        onPressItem={item => navigation.navigate('AlbumDetail', { albumId: item.id })}
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  // No `flex: 1` - see the comment on MediaGrid's `container`. This screen
  // looked fine with it because a 1pt ScrollView still paints its overflow,
  // but it could not actually scroll, so content past the first screenful was
  // unreachable.
  container: {
    // Transparent so RootNavigator's album-art wash shows through. tvOS Apple
    // Music never shows a flat near-black screen; the artwork tints everything.
    backgroundColor: 'transparent',
  },
  content: {
    paddingTop: spacing.lg,
    paddingBottom: spacing.xxl,
    flexGrow: 1,
  },
  headerGuide: { width: '100%' },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.md,
    paddingHorizontal: gutter,
    marginBottom: spacing.xl,
  },
  greeting: {
    paddingHorizontal: gutter,
    marginBottom: spacing.xl,
    fontSize: typeScale.heading,
    fontWeight: '600',
    color: colors.text,
    flexShrink: 1,
  },
  signOut: {
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs,
    borderWidth: 1,
    borderColor: colors.border,
  },
  signOutFocused: {
    outlineWidth: 3,
    outlineColor: colors.text,
  },
  signOutText: {
    fontSize: typeScale.hint,
    color: colors.text2,
    fontWeight: '600',
  },
});

export default HomeScreen;
