/**
 * Artist detail: art, name, their albums as a grid - the albums half of
 * apps/desktop/renderer.js's openArtist (~914). openArtist also loads and
 * plays the artist's songs; that's a playback surface and out of scope here
 * (Phase 4), so only the albums query is reissued.
 *
 * Reuses MediaGrid's `header` slot for the art/name/meta block, same as
 * AlbumDetailScreen reuses FlatList's ListHeaderComponent - one scroller, not
 * a ScrollView wrapping a grid.
 *
 * @format
 */
import { useMemo, useState } from 'react';
import { Image, StyleSheet, Text, View } from 'react-native';
import { useNavigation, useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';

import type { JfItem } from '@cascade/core';

import { getJellyfinClient } from '../api/client';
import { useJellyfin } from '../api/hooks';
import type { StoredSession } from '../auth/session';
import MediaGrid from '../components/MediaGrid';
import type { MediaRowItem } from '../components/MediaRow';
import type { RootStackParamList } from '../navigation/RootNavigator';
import { colors, radius, spacing, type as typeScale } from '../theme';

interface ArtistDetailScreenProps {
  session: StoredSession;
}

function ArtistAvatar({ artistId }: { artistId: string }) {
  const client = getJellyfinClient();
  const [broken, setBroken] = useState(false);
  // artistArtUrl always returns a URL (see its comment in packages/core) -
  // whether the server actually has art is only known once the request lands,
  // hence the same broken-image fallback MediaCard uses.
  const artUrl = client.artistArtUrl(artistId);

  return (
    <View style={styles.avatar}>
      {broken ? (
        <Text style={styles.avatarFallback}>♪</Text>
      ) : (
        <Image source={{ uri: artUrl }} style={styles.avatarImage} onError={() => setBroken(true)} />
      )}
    </View>
  );
}

function ArtistDetailScreen({ session }: ArtistDetailScreenProps) {
  const client = getJellyfinClient();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  const { params } = useRoute<RouteProp<RootStackParamList, 'ArtistDetail'>>();

  const albums = useJellyfin<JfItem[]>(async () => {
    const data = await client.get(`/Users/${session.userId}/Items`, {
      ArtistIds: params.artistId,
      IncludeItemTypes: 'MusicAlbum',
      Recursive: true,
      SortBy: 'ProductionYear,SortName',
      SortOrder: 'Descending',
      Fields: 'PrimaryImageAspectRatio',
    });
    return data.Items || [];
  }, [params.artistId, session.userId]);

  const items: MediaRowItem[] = useMemo(
    () =>
      (albums.data || []).map(item => ({
        id: item.Id,
        title: item.Name || '',
        subtitle: item.ProductionYear ? String(item.ProductionYear) : '',
        artUrl: client.artUrl(item.Id, item.ImageTags?.Primary),
      })),
    [albums.data, client],
  );

  const count = albums.data?.length ?? 0;

  const header = (
    <View style={styles.header}>
      <ArtistAvatar artistId={params.artistId} />
      <Text style={styles.name} numberOfLines={2}>
        {params.artistName || ''}
      </Text>
      {!albums.loading && !albums.error && (
        <Text style={styles.meta}>{`${count} album${count !== 1 ? 's' : ''}`}</Text>
      )}
    </View>
  );

  return (
    <MediaGrid
      items={items}
      loading={albums.loading}
      error={albums.error}
      emptyLabel="No albums"
      errorLabel="Could not load artist"
      onPressItem={item => navigation.navigate('AlbumDetail', { albumId: item.id })}
      header={header}
    />
  );
}

const styles = StyleSheet.create({
  header: {
    alignItems: 'center',
    paddingTop: spacing.xl,
  },
  avatar: {
    width: spacing.xxl * 4,
    height: spacing.xxl * 4,
    borderRadius: radius.pill,
    backgroundColor: colors.surface2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
    marginBottom: spacing.lg,
  },
  avatarImage: {
    width: '100%',
    height: '100%',
  },
  avatarFallback: {
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
});

export default ArtistDetailScreen;
