/**
 * Songs: a flat, potentially-thousands-long list - same query as
 * apps/desktop/renderer.js's loadSongs (~1007). getAllPaged rather than
 * getMerged so a library over the page size isn't silently truncated (same
 * reason renderer.js uses it there), and FlatList (not .map) so React only
 * ever mounts the rows on screen.
 *
 * @format
 */
import { ActivityIndicator, FlatList, StyleSheet, Text, View } from 'react-native';

import { sortSongs } from '@cascade/core';
import type { JfItem } from '@cascade/core';

import { getJellyfinClient } from '../api/client';
import { useJellyfin } from '../api/hooks';
import type { StoredSession } from '../auth/session';
import TrackRow from '../components/TrackRow';
import { playbackService } from '../playback/PlaybackService';
import { colors, spacing, type as typeScale } from '../theme';

interface SongsScreenProps {
  session: StoredSession;
}

function SongsScreen({ session }: SongsScreenProps) {
  const client = getJellyfinClient();

  const songs = useJellyfin<JfItem[]>(async () => {
    const data = await client.getAllPaged(`/Users/${session.userId}/Items`, {
      SortBy: 'SortName',
      SortOrder: 'Ascending',
      IncludeItemTypes: 'Audio',
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData,DateCreated',
      Limit: 500,
    });
    const items = data.Items || [];
    // getAllPaged merges each library's own pages, so SortBy only holds within
    // one library - re-sort the merge, same fix HomeScreen applies to
    // getMerged's recently-played list. sortSongs/songSortValue come from
    // core precisely so this comparator isn't written twice.
    return sortSongs(items, 'name', 'asc');
  }, [session.userId]);

  const items = songs.data || [];
  let status: string | null = null;
  if (!songs.loading && songs.error) status = 'Could not load songs';
  else if (!songs.loading && !songs.error && items.length === 0) status = 'No songs yet';

  return (
    <FlatList
      style={styles.container}
      data={items}
      keyExtractor={i => i.Id}
      renderItem={({ item, index }) => (
        <TrackRow
          item={item}
          index={index}
          artUrl={client.artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)}
          showAlbum
          onPress={() => playbackService.play(items, index)}
        />
      )}
      contentContainerStyle={styles.content}
      ListEmptyComponent={
        songs.loading ? (
          <View style={styles.statusBox}>
            <ActivityIndicator color={colors.accent} />
          </View>
        ) : status ? (
          <Text style={styles.statusText}>{status}</Text>
        ) : null
      }
    />
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.bg,
  },
  content: {
    paddingVertical: spacing.lg,
    flexGrow: 1,
  },
  statusBox: {
    paddingHorizontal: spacing.lg,
  },
  statusText: {
    fontSize: typeScale.body,
    color: colors.text3,
    paddingHorizontal: spacing.lg,
  },
});

export default SongsScreen;
