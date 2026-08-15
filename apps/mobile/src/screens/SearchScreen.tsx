/**
 * Search - one input, results grouped by type, same shape and debounce as
 * apps/desktop/renderer.js's runSearch (~4855): songs/albums/artists queried
 * in parallel with Promise.allSettled so one failing group doesn't blank the
 * others, each capped the same as the desktop client (10/8/8).
 *
 * Stale-result protection: useJellyfin already cancels a superseded fetch (see
 * its `cancelled` flag) whenever its deps array changes before that fetch's
 * .then runs. Debounced query is the dep, so a fast retype - which changes
 * `debounced` again before the previous request lands - discards the older
 * response instead of letting it clobber the newer one. Nothing extra needed
 * here.
 *
 * @format
 */
import { useEffect, useMemo, useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';

import type { JfItem } from '@cascade/core';

import { getJellyfinClient } from '@cascade/app';
import { useJellyfin } from '@cascade/app';
import type { StoredSession } from '@cascade/app';
import MediaRow, { type MediaRowItem } from '../components/MediaRow';
import { playbackService } from '@cascade/app';
import TrackRow from '../components/TrackRow';
import type { RootStackParamList } from '../navigation/RootNavigator';
import { colors, gutter, radius, spacing, type as typeScale } from '../theme';

interface SearchScreenProps {
  session: StoredSession;
}

interface SearchResults {
  songs: JfItem[];
  albums: JfItem[];
  artists: JfItem[];
}

const EMPTY_RESULTS: SearchResults = { songs: [], albums: [], artists: [] };

// Same debounce window as renderer.js's search input.
const DEBOUNCE_MS = 300;

function SearchScreen({ session }: SearchScreenProps) {
  const client = getJellyfinClient();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();

  const [query, setQuery] = useState('');
  const [debounced, setDebounced] = useState('');

  useEffect(() => {
    const t = setTimeout(() => setDebounced(query.trim()), DEBOUNCE_MS);
    return () => clearTimeout(t);
  }, [query]);

  const search = useJellyfin<SearchResults>(async () => {
    if (!debounced) return EMPTY_RESULTS;

    const [songsRes, albumsRes, artistsRes] = await Promise.allSettled([
      client.getMerged(`/Users/${session.userId}/Items`, {
        SearchTerm: debounced,
        Recursive: true,
        Limit: 10,
        IncludeItemTypes: 'Audio',
        Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag',
      }),
      client.getMerged(`/Users/${session.userId}/Items`, {
        SearchTerm: debounced,
        Recursive: true,
        Limit: 8,
        IncludeItemTypes: 'MusicAlbum',
        Fields: 'PrimaryImageAspectRatio',
      }),
      client.getMerged('/Artists', { SearchTerm: debounced, UserId: session.userId, Limit: 8 }),
    ]);

    // Mirrors runSearch's `take`: getMerged returns up to Limit per library,
    // so trim back to the intended cap after the merge.
    const take = (res: PromiseSettledResult<{ Items?: JfItem[] }>, n: number) =>
      (res.status === 'fulfilled' ? res.value.Items || [] : []).slice(0, n);

    return { songs: take(songsRes, 10), albums: take(albumsRes, 8), artists: take(artistsRes, 8) };
  }, [debounced, session.userId]);

  const results = search.data || EMPTY_RESULTS;

  const albumItems: MediaRowItem[] = useMemo(
    () =>
      results.albums.map(item => ({
        id: item.Id,
        title: item.Name || '',
        subtitle: item.AlbumArtist || '',
        artUrl: client.artUrl(item.Id, item.ImageTags?.Primary),
      })),
    [results.albums, client],
  );

  const artistItems: MediaRowItem[] = useMemo(
    () =>
      results.artists.map(item => ({
        id: item.Id,
        title: item.Name || '',
        artUrl: client.artistArtUrl(item.Id),
      })),
    [results.artists, client],
  );

  const hasAny = results.songs.length > 0 || results.albums.length > 0 || results.artists.length > 0;

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      <TextInput
        value={query}
        onChangeText={setQuery}
        placeholder="Search songs, albums, artists"
        placeholderTextColor={colors.text3}
        style={styles.input}
        autoCapitalize="none"
        autoCorrect={false}
        returnKeyType="search"
      />

      {!debounced && <Text style={styles.hint}>Search your library</Text>}

      {!!debounced && search.loading && (
        <View style={styles.statusBox}>
          <ActivityIndicator color={colors.accent} />
        </View>
      )}

      {!!debounced && !search.loading && search.error && <Text style={styles.statusText}>Search failed</Text>}

      {!!debounced && !search.loading && !search.error && !hasAny && (
        <Text style={styles.statusText}>{`No results for "${debounced}"`}</Text>
      )}

      {!!debounced && !search.loading && !search.error && hasAny && (
        <View>
          {results.songs.length > 0 && (
            <View style={styles.section}>
              <Text style={styles.sectionTitle}>Songs</Text>
              {results.songs.map((item, i) => (
                <TrackRow
                  key={item.Id}
                  item={item}
                  index={i}
                  artUrl={client.artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)}
                  showAlbum
                  // The whole result set becomes the queue, so playing the
                  // third hit still lets you continue through the rest.
                  onPress={() => playbackService.play(results.songs, i)}
                />
              ))}
            </View>
          )}

          {albumItems.length > 0 && (
            <MediaRow
              title="Albums"
              items={albumItems}
              loading={false}
              error={null}
              emptyLabel=""
              errorLabel=""
              onPressItem={item => navigation.navigate('AlbumDetail', { albumId: item.id })}
            />
          )}

          {artistItems.length > 0 && (
            <MediaRow
              title="Artists"
              items={artistItems}
              loading={false}
              error={null}
              emptyLabel=""
              errorLabel=""
              onPressItem={item => navigation.navigate('ArtistDetail', { artistId: item.id, artistName: item.title })}
            />
          )}
        </View>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  // No `flex: 1` - see the comment on MediaGrid's `container`. Same as Home:
  // this looked fine but was not actually scrollable.
  container: {
    backgroundColor: colors.bg,
  },
  content: {
    paddingTop: spacing.lg,
    paddingBottom: spacing.xxl,
    flexGrow: 1,
  },
  input: {
    marginHorizontal: spacing.lg,
    marginBottom: spacing.lg,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
    color: colors.text,
    fontSize: typeScale.body,
  },
  hint: {
    fontSize: typeScale.body,
    color: colors.text3,
    paddingHorizontal: gutter,
  },
  statusBox: {
    paddingHorizontal: gutter,
    alignItems: 'flex-start',
  },
  statusText: {
    fontSize: typeScale.body,
    color: colors.text3,
    paddingHorizontal: gutter,
  },
  section: {
    marginBottom: spacing.xl,
  },
  sectionTitle: {
    fontSize: typeScale.label,
    fontWeight: '600',
    color: colors.text2,
    marginBottom: spacing.md,
    paddingHorizontal: gutter,
  },
});

export default SearchScreen;
