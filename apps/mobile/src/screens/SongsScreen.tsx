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
import { useState } from 'react';

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

  // Rendered from partial results on purpose. This library is 1439 tracks -
  // three pages, about six seconds - and awaiting the whole thing left the
  // screen empty for all of it, which reads as "Songs doesn't load". The first
  // page already fills a viewport, so it goes up as soon as it lands and the
  // rest arrive underneath.
  const [partial, setPartial] = useState<JfItem[]>([]);

  const songs = useJellyfin<JfItem[]>(async () => {
    const data = await client.getAllPaged(
      `/Users/${session.userId}/Items`,
      {
        SortBy: 'SortName',
        SortOrder: 'Ascending',
        IncludeItemTypes: 'Audio',
        Recursive: true,
        Fields: 'AlbumId,AlbumPrimaryImageTag',
        Limit: 500,
      },
      undefined,
      // getAllPaged merges each library's own pages, so SortBy only holds
      // within one library - every emit is re-sorted for the same reason
      // HomeScreen re-sorts getMerged's recently-played list.
      items => setPartial(sortSongs([...items], 'name', 'asc')),
    );
    return sortSongs(data.Items || [], 'name', 'asc');
  }, [session.userId]);

  const items = songs.data || partial;
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
            <ActivityIndicator color={colors.accent} size="large" />
            <Text style={styles.statusText}>Loading songs…</Text>
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
    paddingVertical: spacing.xxl,
    alignItems: 'center',
    gap: spacing.md,
  },
  statusText: {
    fontSize: typeScale.body,
    color: colors.text3,
    paddingHorizontal: spacing.lg,
  },
});

export default SongsScreen;
