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
 * Two chrome layouts, chosen by platform. tvOS floats two glass pills across
 * the top, which is what tvOS's own apps do. Android TV gets the desktop app's
 * left sidenav instead: there is no liquid glass on Android, so a floating
 * pill there is a grey slab with nothing behind it, and Android TV's own
 * launcher and every Leanback app put navigation down the left edge. Same
 * NavBar, same navigation, different shell.
 *
 * @format
 */
import { useState } from 'react';
import { Platform, StyleSheet, TVFocusGuideView, View } from 'react-native';
import { DarkTheme, NavigationContainer, createNavigationContainerRef } from '@react-navigation/native';
import type { Theme } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';

import type { StoredSession } from '@cascade/app';
import NowPlayingBar from '../components/NowPlayingBar';
import AlbumDetailScreen from '../screens/AlbumDetailScreen';
import ArtistDetailScreen from '../screens/ArtistDetailScreen';
import HomeScreen from '../screens/HomeScreen';
import LibraryScreen from '../screens/LibraryScreen';
import SettingsScreen from '../screens/SettingsScreen';
import NowPlayingScreen from '../screens/NowPlayingScreen';
import SearchScreen from '../screens/SearchScreen';
import WaterfallScreen from '../screens/WaterfallScreen';
import { GlassSurface, usePlaybackSnapshot } from '@cascade/app';
import { bgTint, colors, gutter, radius, spacing } from '../theme';
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
    // Transparent, not colors.bg: the album-art wash is painted once at the
    // root and every screen sits on it. A solid colour here would cover it.
    background: 'transparent',
    card: colors.surface,
    text: colors.text,
    border: colors.border,
    primary: colors.accent,
  },
};

interface RootNavigatorProps {
  session: StoredSession;
  appVersion: string;
  onSignOut: () => void;
}

function RootNavigator({ session, appVersion, onSignOut }: RootNavigatorProps) {
  const [routeName, setRouteName] = useState<string>('Home');
  // A callback ref rather than useRef: the guide below needs the actual node as
  // a destination, and a useRef would still be null on the render that mounts
  // the guide. Setting state re-renders once the node exists.
  const [tabsNode, setTabsNode] = useState<View | null>(null);
  const onNowPlaying = routeName === 'NowPlaying';
  // An empty pill is still a pill: without this the chip's glass and its
  // reserved width sit there as a blank slab whenever nothing is playing.
  const hasTrack = !!usePlaybackSnapshot().item;

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

  const navBar = (vertical: boolean) => (
    <NavBar
      current={routeName}
      vertical={vertical}
      onNavigate={(name: NavItemName) => {
        if (navigationRef.isReady()) navigationRef.navigate(name as never);
      }}
    />
  );

  // Wrapped in a focus guide, and this is the fix for the whole class of "the
  // remote just stops responding" bugs rather than one screen's.
  //
  // tvOS moves focus purely by geometry: press Down and it looks for something
  // focusable directly below what you are on, and if there is nothing there it
  // does not move at all. The tabs pill sits at the far right of a 1920 screen
  // while Home's card row starts at the left gutter and does not reach that
  // far, so Down out of the tab bar found empty space and died. Android TV has
  // the same engine and the same problem going right from the rail's bottom
  // chip.
  //
  // autoFocus on a guide covering the whole content area means focus entering
  // that region from any direction gets handed to a child instead of being
  // dropped. One guide here fixes every screen, which beats a guide per screen.
  const stack = (
      <TVFocusGuideView autoFocus style={styles.stackFill}>
        <Stack.Navigator screenOptions={{ headerShown: false }}>
          <Stack.Screen name="Home">{() => <HomeScreen session={session} onSignOut={onSignOut} />}</Stack.Screen>
          <Stack.Screen name="Library">{() => <LibraryScreen session={session} />}</Stack.Screen>
          <Stack.Screen name="Search">{() => <SearchScreen session={session} />}</Stack.Screen>
          <Stack.Screen name="Settings">
            {() => <SettingsScreen session={session} appVersion={appVersion} onSignOut={onSignOut} />}
          </Stack.Screen>
          <Stack.Screen name="AlbumDetail">{() => <AlbumDetailScreen session={session} />}</Stack.Screen>
          <Stack.Screen name="ArtistDetail">{() => <ArtistDetailScreen session={session} />}</Stack.Screen>
          {/* Presented over the stack rather than beside it: it is the
              desktop's overlay, and the nav bar and the now-playing bar have
              no business showing through it. */}
          <Stack.Screen name="NowPlaying" component={NowPlayingScreen} options={{ presentation: 'fullScreenModal' }} />
          <Stack.Screen name="Waterfall" component={WaterfallScreen} />
        </Stack.Navigator>
      </TVFocusGuideView>
  );

  const tvOSChrome = (
    <View style={styles.root}>
      {/* Chip on the left, tabs on the right, each its own glass pill. Both
          live up here because focus moves geometrically on a TV: from a row in
          a 1400-track list, up-then-across always reaches them, while anything
          docked at the bottom sits behind 1399 rows. */}
      <View style={styles.topRow} pointerEvents="box-none">
        {hasTrack ? (
          <GlassSurface style={styles.chipPill} fallbackColor={colors.surface} radius={radius.pill}>
            {playbackBar}
          </GlassSurface>
        ) : (
          // The player itself must stay mounted even with the pill gone - it
          // owns the app's only <Video>.
          <View>{playbackBar}</View>
        )}
        {/* An empty guide filling the gap between the two pills, and it is
            empty on purpose.
            
            Pressing Up from a card is the mirror of the Down problem: the tabs
            pill is right-aligned and the content under it is left-aligned, so
            Up found nothing above it. The obvious fix - autoFocus on the whole
            top row - deadlocked focus outright, because autoFocus on a
            container holding the real targets makes that container fight the
            stack's guide for every move, and nothing responded at all. A guide
            with no focusable children of its own does not compete: it only
            catches focus landing in dead space and forwards it. */}
        <TVFocusGuideView style={styles.topGap} destinations={tabsNode ? [tabsNode] : []} />
        <View ref={setTabsNode} collapsable={false}>
          <GlassSurface style={styles.tabsPill} fallbackColor={colors.surface} radius={radius.pill}>
            {navBar(false)}
          </GlassSurface>
        </View>
      </View>
      <View style={styles.stackArea}>{stack}</View>
    </View>
  );

  const androidChrome = (
    <View style={styles.rootRow}>
      {/* autoFocus so a left-press from anywhere in the content lands on the
          rail rather than falling through to whatever happens to be nearest.
          Same reason NowPlayingScreen guards its secondary controls. */}
      <TVFocusGuideView autoFocus style={styles.sidebar}>
        {navBar(true)}
        <View style={styles.railSpacer} />
        {/* Bottom of the rail, where the desktop app's nav-spacer puts it.
            Reachable by left-then-down from any row, and the player stays
            mounted with nothing playing for the same reason as above. */}
        <View style={hasTrack ? styles.railChip : undefined}>{playbackBar}</View>
      </TVFocusGuideView>
      <View style={[styles.stackArea, styles.stackAreaRail]}>{stack}</View>
    </View>
  );

  return (
    <NavigationContainer ref={navigationRef} theme={navTheme} onReady={syncRouteName} onStateChange={syncRouteName}>
      {Platform.OS === 'android' ? androidChrome : tvOSChrome}
    </NavigationContainer>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: bgTint,
  },
  rootRow: {
    flex: 1,
    flexDirection: 'row',
    backgroundColor: bgTint,
  },
  stackArea: {
    flex: 1,
  },
  stackFill: {
    flex: 1,
  },
  // Replaces the inset the tvOS top row used to give every screen. A real
  // panel overscans, so content still must not start at y=0.
  stackAreaRail: {
    paddingTop: spacing.xl,
  },
  // Wide enough for the longest label at TV type plus the now-playing chip
  // below it. The desktop rail collapses to 48px and expands on hover; there
  // is no hover on a remote, and expanding on focus would reflow every grid
  // beside it every time focus crossed the edge.
  sidebar: {
    width: 300,
    paddingVertical: spacing.xl,
    paddingHorizontal: spacing.md,
    backgroundColor: colors.surface,
    borderRightWidth: 1,
    borderRightColor: colors.border,
  },
  railSpacer: {
    flex: 1,
  },
  railChip: {
    borderRadius: radius.md,
    backgroundColor: colors.surface2,
    overflow: 'hidden',
  },
  topRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.lg,
    paddingHorizontal: gutter,
    paddingTop: spacing.md,
    paddingBottom: spacing.sm,
  },
  // No border on either pill. Glass is not an outlined box - drawing a hairline
  // around it is what made these read as panels sitting on the screen rather
  // than as part of it.
  chipPill: {
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.22)',
    // A floor and a ceiling, not a fixed width. Without the floor the title
    // block inside is flex:1 against a content-sized parent, which resolves to
    // zero and collapses the chip to just its album art. Without the ceiling a
    // long title pushes the pill across the screen.
    minWidth: 300,
    maxWidth: 440,
  },
  topGap: {
    flex: 1,
  },
  // The hairline is back, and this reverses an earlier call of mine. I removed
  // borders from these pills on the reasoning that glass is not an outlined
  // box. tvOS Apple Music's own tab bar is exactly that: a thin stroked capsule
  // holding the tabs, with only the focused one filled. The reference wins.
  tabsPill: {
    overflow: 'hidden',
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.22)',
  },
});

export default RootNavigator;
