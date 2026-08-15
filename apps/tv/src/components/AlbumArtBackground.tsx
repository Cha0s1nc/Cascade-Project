/**
 * The drifting album-art background - the thing that makes Cascade look like
 * Cascade rather than a generic Jellyfin client.
 *
 * Ports the three desktop effects that together make up the look
 * (apps/desktop/renderer.js: extractTopColors ~5547, buildBlobBackground ~5632,
 * the drift half of startBeatLoop ~3320). All of the maths lives in
 * @cascade/core so both apps produce the same picture from the same cover; this
 * file is only the React around it.
 *
 * No Skia, Reanimated or Worklets, which the plan had budgeted three native
 * dependencies for. React Native 0.83 parses radial-gradient itself
 * (React/Fabric/Utils/RCTRadialGradient.mm), so the exact CSS string the
 * desktop assigns to style.backgroundImage goes straight into
 * experimental_backgroundImage here.
 *
 * Mounted by NowPlayingScreen only, matching the desktop, where this lives on
 * the now-playing overlay and nowhere else. It briefly rendered behind every
 * screen instead, and a dense album grid over full-strength blobs was exactly as
 * bad as it sounds.
 *
 * @format
 */
import { useEffect, useRef, useState } from 'react';
import { Animated, AppState, StyleSheet, useAnimatedValue, View } from 'react-native';

import {
  BLOB_BASE_COLOR,
  BLOB_FRAME_MS,
  blobBackgroundCss,
  driftedBlobs,
  randomizeDrift,
} from '@cascade/core';
import type { BlobColor, DriftParams } from '@cascade/core';

import { paletteFor } from '../art/palette';
import { playbackService } from '../playback/PlaybackService';

/** Long enough to read as a fade rather than a cut, short enough that the
 *  screen does not feel slow to open. */
const FADE_MS = 700;

export default function AlbumArtBackground() {
  const [colors, setColors] = useState<BlobColor[]>([]);
  const [css, setCss] = useState('');
  const drift = useRef<DriftParams[]>([]);
  const fade = useAnimatedValue(0);

  // Re-derive the palette whenever the track changes. Keyed on the art tag as
  // well as the id: two tracks off one album share a cover, and re-running the
  // extraction for each of them would be pure waste.
  useEffect(() => {
    let live = true;
    let key = '';

    const sync = async () => {
      const item = playbackService.getSnapshot().item;
      const id = item?.AlbumId || item?.Id;
      const tag = item?.AlbumPrimaryImageTag || item?.ImageTags?.Primary;
      const next = id ? `${id}:${tag ?? ''}` : '';
      if (next === key) return;
      key = next;

      if (!id) {
        if (live) setColors([]);
        return;
      }
      const found = await paletteFor(id, tag);
      if (!live) return;
      // Fresh drift per cover, so two tracks in a row do not trace the same
      // path across the screen.
      drift.current = randomizeDrift(Math.max(1, found.length));
      setColors(found);
    };

    void sync();
    const unsubscribe = playbackService.subscribe(() => {
      void sync();
    });
    return () => {
      live = false;
      unsubscribe();
    };
  }, []);

  // Fade in when the screen opens, and again on each new cover. Going straight
  // to full strength is a jolt: these are large, saturated shapes and they
  // arrive a moment after the screen does, so the change lands after the eye has
  // already settled.
  useEffect(() => {
    if (colors.length === 0) {
      fade.setValue(0);
      return;
    }
    fade.setValue(0);
    Animated.timing(fade, {
      toValue: 1,
      duration: FADE_MS,
      useNativeDriver: true,
    }).start();
  }, [colors, fade]);

  // Drive the drift. setInterval rather than requestAnimationFrame because the
  // motion has periods measured in tens of seconds - the desktop throttles to
  // the same ~15fps and it is visually indistinguishable, and on a TV this is
  // the background, so it must not eat the frame budget of the content in front
  // of it.
  useEffect(() => {
    if (colors.length === 0) {
      setCss('');
      return undefined;
    }

    const tick = () => {
      setCss(blobBackgroundCss(driftedBlobs(colors, drift.current, Date.now() / 1000)));
    };
    tick();

    let timer: ReturnType<typeof setInterval> | null = setInterval(tick, BLOB_FRAME_MS);

    // Backgrounding the app should stop the timer outright. iOS suspends the
    // process anyway, but Android does not, and a 15fps re-render behind a
    // locked screen is battery spent on something nobody can see.
    const stop = () => {
      if (timer) { clearInterval(timer); timer = null; }
    };
    const start = () => {
      if (!timer) timer = setInterval(tick, BLOB_FRAME_MS);
    };
    const sub = AppState.addEventListener('change', s => (s === 'active' ? start() : stop()));

    return () => {
      stop();
      sub.remove();
    };
  }, [colors]);

  return (
    <View
      style={[styles.fill, { backgroundColor: BLOB_BASE_COLOR }]}
      // Decoration only - it must never take a tap on phone or a focus stop on
      // a TV remote.
      pointerEvents="none"
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants">
      {!!css && (
        <Animated.View style={[styles.fill, { opacity: fade, experimental_backgroundImage: css }]} />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  fill: StyleSheet.absoluteFillObject,
});
