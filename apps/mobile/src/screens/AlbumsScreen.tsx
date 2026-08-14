/**
 * Albums grid - same query as apps/desktop/renderer.js's loadAlbums (~806),
 * reissued here because the desktop code is DOM-bound, not because the query
 * differs.
 *
 * @format
 */
import { useMemo } from 'react';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';

import type { JfItem } from '@cascade/core';

import { getJellyfinClient } from '../api/client';
import { useJellyfin } from '../api/hooks';
import type { StoredSession } from '../auth/session';
import MediaGrid from '../components/MediaGrid';
import type { MediaRowItem } from '../components/MediaRow';
import type { RootStackParamList } from '../navigation/RootNavigator';

interface AlbumsScreenProps {
  session: StoredSession;
}

function AlbumsScreen({ session }: AlbumsScreenProps) {
  const client = getJellyfinClient();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();

  const albums = useJellyfin<JfItem[]>(async () => {
    const data = await client.getMerged(`/Users/${session.userId}/Items`, {
      SortBy: 'SortName',
      SortOrder: 'Ascending',
      IncludeItemTypes: 'MusicAlbum',
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio',
      Limit: 200,
    });
    return data.Items || [];
  }, [session.userId]);

  const items: MediaRowItem[] = useMemo(
    () =>
      (albums.data || []).map(item => ({
        id: item.Id,
        title: item.Name || '',
        subtitle: item.AlbumArtist || '',
        artUrl: client.artUrl(item.Id, item.ImageTags?.Primary),
      })),
    [albums.data, client],
  );

  return (
    <MediaGrid
      items={items}
      loading={albums.loading}
      error={albums.error}
      emptyLabel="No albums yet"
      errorLabel="Could not load albums"
      onPressItem={item => navigation.navigate('AlbumDetail', { albumId: item.id })}
    />
  );
}

export default AlbumsScreen;
