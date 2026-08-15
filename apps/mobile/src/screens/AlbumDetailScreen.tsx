/**
 * Album detail: art, name, artist/year/track-count, and the track list in
 * disc/track order - same two queries (run in parallel) as
 * apps/desktop/renderer.js's openAlbum (~846).
 *
 * One FlatList rather than a ScrollView-plus-list: the header (art/name/meta)
 * rides in as ListHeaderComponent so the track list still gets real
 * virtualisation instead of being mapped into a ScrollView.
 *
 * @format
 */
import { useState } from 'react';
import { ActivityIndicator, FlatList, Image, StyleSheet, Text, View } from 'react-native';
import { useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';

import type { JfItem } from '@cascade/core';

import { getJellyfinClient } from '../api/client';
import { useJellyfin } from '../api/hooks';
import type { StoredSession } from '../auth/session';
import TrackRow from '../components/TrackRow';
import { playbackService } from '../playback/PlaybackService';
import type { RootStackParamList } from '../navigation/RootNavigator';
import { colors, radius, spacing, type as typeScale } from '../theme';

interface AlbumDetailScreenProps {
  session: StoredSession;
}

interface AlbumDetailData {
  album: JfItem;
  tracks: JfItem[];
}

function AlbumArt({ album }: { album: JfItem | undefined }) {
  const client = getJellyfinClient();
  const [broken, setBroken] = useState(false);
  const artUrl = album ? client.artUrl(album.Id, album.ImageTags?.Primary) : null;
  const showArt = !!artUrl && !broken;

  return (
    <View style={styles.art}>
      {showArt ? (
        <Image source={{ uri: artUrl as string }} style={styles.artImage} onError={() => setBroken(true)} />
      ) : (
        <Text style={styles.artFallback}>♪</Text>
      )}
    </View>
  );
}

function AlbumDetailScreen({ session }: AlbumDetailScreenProps) {
  const client = getJellyfinClient();
  const { params } = useRoute<RouteProp<RootStackParamList, 'AlbumDetail'>>();

  const result = useJellyfin<AlbumDetailData>(async () => {
    const [album, tracksData] = await Promise.all([
      client.get<JfItem>(`/Users/${session.userId}/Items/${params.albumId}`),
      client.get(`/Users/${session.userId}/Items`, {
        ParentId: params.albumId,
        SortBy: 'ParentIndexNumber,IndexNumber,SortName',
        IncludeItemTypes: 'Audio',
        Recursive: true,
        Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag',
      }),
    ]);
    return { album, tracks: tracksData.Items || [] };
  }, [params.albumId, session.userId]);

  const album = result.data?.album;
  const tracks = result.data?.tracks || [];

  const meta = [album?.AlbumArtist, album?.ProductionYear, tracks.length ? `${tracks.length} song${tracks.length !== 1 ? 's' : ''}` : null]
    .filter(Boolean)
    .join(' · ');

  let status: string | null = null;
  if (!result.loading && result.error) status = 'Could not load album';
  else if (!result.loading && !result.error && tracks.length === 0) status = 'No tracks';

  const header = (
    <View style={styles.header}>
      <AlbumArt album={album} />
      <Text style={styles.name} numberOfLines={2}>
        {album?.Name || ''}
      </Text>
      {!!meta && <Text style={styles.meta}>{meta}</Text>}
    </View>
  );

  return (
    <FlatList
      style={styles.container}
      data={tracks}
      keyExtractor={t => t.Id}
      ListHeaderComponent={header}
      renderItem={({ item, index }) => (
        <TrackRow
          item={item}
          index={index}
          artUrl={client.artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)}
          onPress={() => playbackService.play(tracks, index)}
        />
      )}
      contentContainerStyle={styles.content}
      ListEmptyComponent={
        result.loading ? (
          <ActivityIndicator color={colors.accent} style={styles.statusBox} />
        ) : status ? (
          <Text style={styles.statusText}>{status}</Text>
        ) : null
      }
    />
  );
}

const styles = StyleSheet.create({
  // No `flex: 1` - see the comment on MediaGrid's `container`.
  container: {
    backgroundColor: colors.bg,
  },
  content: {
    paddingBottom: spacing.xxl,
    flexGrow: 1,
  },
  header: {
    alignItems: 'center',
    padding: spacing.xl,
  },
  art: {
    width: spacing.xxl * 4,
    height: spacing.xxl * 4,
    borderRadius: radius.lg,
    backgroundColor: colors.surface2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
    marginBottom: spacing.lg,
  },
  artImage: {
    width: '100%',
    height: '100%',
  },
  artFallback: {
    fontSize: typeScale.heading,
    color: colors.text3,
  },
  name: {
    fontSize: typeScale.heading,
    fontWeight: '600',
    color: colors.text,
    textAlign: 'center',
  },
  meta: {
    fontSize: typeScale.hint,
    color: colors.text3,
    marginTop: spacing.xs,
  },
  statusBox: {
    marginTop: spacing.xl,
  },
  statusText: {
    fontSize: typeScale.body,
    color: colors.text3,
    textAlign: 'center',
    marginTop: spacing.xl,
    paddingHorizontal: spacing.lg,
  },
});

export default AlbumDetailScreen;
