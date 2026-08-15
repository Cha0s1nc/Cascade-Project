/**
 * Artists grid - same query as apps/desktop/renderer.js's loadArtists (~899).
 * Art comes from artistArtUrl, not artUrl: Jellyfin's /Artists endpoint
 * doesn't carry an image tag to gate on the way album/song items do (see
 * JellyfinClient.artistArtUrl's comment in packages/core).
 *
 * @format
 */
import { useMemo } from 'react';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';

import type { JfItem } from '@cascade/core';

import { getJellyfinClient } from '@cascade/app';
import { useJellyfin } from '@cascade/app';
import type { StoredSession } from '@cascade/app';
import MediaGrid from '../components/MediaGrid';
import type { MediaRowItem } from '../components/MediaRow';
import type { RootStackParamList } from '../navigation/RootNavigator';

interface ArtistsScreenProps {
  session: StoredSession;
}

function ArtistsScreen({ session }: ArtistsScreenProps) {
  const client = getJellyfinClient();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();

  const artists = useJellyfin<JfItem[]>(async () => {
    const data = await client.getMerged('/Artists', {
      UserId: session.userId,
      SortBy: 'SortName',
      SortOrder: 'Ascending',
      Limit: 200,
    });
    return data.Items || [];
  }, [session.userId]);

  const items: MediaRowItem[] = useMemo(
    () =>
      (artists.data || []).map(item => ({
        id: item.Id,
        title: item.Name || '',
        artUrl: client.artistArtUrl(item.Id),
      })),
    [artists.data, client],
  );

  return (
    <MediaGrid
      items={items}
      loading={artists.loading}
      error={artists.error}
      emptyLabel="No artists yet"
      errorLabel="Could not load artists"
      onPressItem={item =>
        navigation.navigate('ArtistDetail', { artistId: item.id, artistName: item.title })
      }
    />
  );
}

export default ArtistsScreen;
