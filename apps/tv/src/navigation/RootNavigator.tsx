/**
 * The navigation shell: NavBar plus a native-stack for whatever a nav item
 * (or a card inside a screen) drills into.
 *
 * NavBar lives as a sibling of the stack, not one of its screens, so it
 * survives every push the way a tab bar would - without pulling in
 * bottom-tabs, which is the wrong shape for a TV. It talks to the stack
 * through a navigationRef rather than the usual screen-received `navigation`
 * prop, since it sits outside every screen.
 *
 * @format
 */
import { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { DarkTheme, NavigationContainer, createNavigationContainerRef } from '@react-navigation/native';
import type { Theme } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';

import type { StoredSession } from '@cascade/app';
import NowPlayingBar from '../components/NowPlayingBar';
import AlbumDetailScreen from '../screens/AlbumDetailScreen';
import AlbumsScreen from '../screens/AlbumsScreen';
import ArtistDetailScreen from '../screens/ArtistDetailScreen';
import ArtistsScreen from '../screens/ArtistsScreen';
import HomeScreen from '../screens/HomeScreen';
import NowPlayingScreen from '../screens/NowPlayingScreen';
import SearchScreen from '../screens/SearchScreen';
import SongsScreen from '../screens/SongsScreen';
import WaterfallScreen from '../screens/WaterfallScreen';
import { colors } from '../theme';
import NavBar, { NAV_ITEMS } from './NavBar';
import type { NavItemName } from './NavBar';

// The five nav destinations (no params) plus the two detail screens any card
// among them can push to. Not part of NAV_ITEMS - the nav bar itself never
// links to a detail screen directly, only a card does.
export type RootStackParamList = Record<(typeof NAV_ITEMS)[number], undefined> & {
  AlbumDetail: { albumId: string };
  ArtistDetail: { artistId: string; artistName?: string };
  NowPlaying: undefined;
  Waterfall: undefined;
};

const Stack = createNativeStackNavigator<RootStackParamList>();
const navigationRef = createNavigationContainerRef<RootStackParamList>();

// Reuses the app palette instead of React Navigation's default light theme,
// so the stack's default screen background doesn't flash white behind our
// dark screens.
const navTheme: Theme = {
  ...DarkTheme,
  colors: {
    ...DarkTheme.colors,
    background: colors.bg,
    card: colors.surface,
    text: colors.text,
    border: colors.border,
    primary: colors.accent,
  },
};

interface RootNavigatorProps {
  session: StoredSession;
  onSignOut: () => void;
}

function RootNavigator({ session, onSignOut }: RootNavigatorProps) {
  const [routeName, setRouteName] = useState<string>('Home');
  const onNowPlaying = routeName === 'NowPlaying';

  function syncRouteName() {
    setRouteName(navigationRef.getCurrentRoute()?.name ?? 'Home');
  }

  // Rendered once, in a different place per platform. Two instances would mean
  // two <Video> elements and two players.
  const playbackBar = (
    <NowPlayingBar
      compact
      hidden={onNowPlaying}
      onOpen={() => {
        if (navigationRef.isReady()) navigationRef.navigate('NowPlaying' as never);
      }}
    />
  );

  const navBar = (
    <NavBar
      current={routeName}
      onNavigate={(name: NavItemName) => {
        if (navigationRef.isReady()) navigationRef.navigate(name as never);
      }}
    />
  );

  return (
    <NavigationContainer ref={navigationRef} theme={navTheme} onReady={syncRouteName} onStateChange={syncRouteName}>
      <View style={styles.root}>
        {/* The now-playing bar rides in the top row beside the nav, because at
            the bottom it would be unreachable: focus moves geometrically, so
            from a row in a 1400-track list the only way down to it is through
            the other 1399 rows. Up-then-right always gets here. The phone app
            keeps it at the bottom, where a thumb can just touch it. */}
        <View style={styles.topRow}>
          <View style={styles.topRowNav}>{navBar}</View>
          {playbackBar}
        </View>
        <View style={styles.stackArea}>
          <Stack.Navigator screenOptions={{ headerShown: false }}>
            <Stack.Screen name="Home">{() => <HomeScreen session={session} onSignOut={onSignOut} />}</Stack.Screen>
            <Stack.Screen name="Albums">{() => <AlbumsScreen session={session} />}</Stack.Screen>
            <Stack.Screen name="Artists">{() => <ArtistsScreen session={session} />}</Stack.Screen>
            <Stack.Screen name="Songs">{() => <SongsScreen session={session} />}</Stack.Screen>
            <Stack.Screen name="Search">{() => <SearchScreen session={session} />}</Stack.Screen>
            <Stack.Screen name="AlbumDetail">{() => <AlbumDetailScreen session={session} />}</Stack.Screen>
            <Stack.Screen name="ArtistDetail">{() => <ArtistDetailScreen session={session} />}</Stack.Screen>
            {/* Presented over the stack rather than beside it: it is the
                desktop's overlay, and the nav bar and the now-playing bar have
                no business showing through it. */}
            <Stack.Screen name="NowPlaying" component={NowPlayingScreen} options={{ presentation: 'fullScreenModal' }} />
            <Stack.Screen name="Waterfall" component={WaterfallScreen} />
          </Stack.Navigator>
        </View>
      </View>
    </NavigationContainer>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: colors.bg,
  },
  stackArea: {
    flex: 1,
  },
  topRow: {
    flexDirection: 'row',
    alignItems: 'stretch',
  },
  topRowNav: {
    flex: 1,
    minWidth: 0,
  },
});

export default RootNavigator;
