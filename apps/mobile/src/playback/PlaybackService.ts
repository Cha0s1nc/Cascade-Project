/**
 * One place react-native-video's surface is wired to Jellyfin's playback API.
 * No screen touches react-native-video directly - only NowPlayingBar.tsx
 * renders the actual <Video>, and it does that as a dumb reflection of this
 * service's state: the mounted element's props come straight from the
 * snapshot, and its events feed straight back into the handlers below.
 *
 * Modelled on apps/desktop/renderer.js's playback section (playCurrentTrack,
 * restartStreamAt, reportPlaybackStart/Progress/Stopped, abandonCurrentEncoding)
 * but shaped for react-native-video's controlled component instead of one
 * long-lived <audio> element: pause/resume are the `paused` prop, not
 * player.pause()/play() calls - only seek needs the native ref at all.
 *
 * @format
 */
import { useSyncExternalStore } from 'react';
import { Platform } from 'react-native';
import type {
  OnLoadData,
  OnPlaybackStateChangedData,
  OnProgressData,
  OnVideoErrorData,
  ReactVideoSource,
  VideoRef,
} from 'react-native-video';

import {
  ANDROID_PROFILE,
  APPLE_PROFILE,
  DEFAULT_MAX_BITRATE,
  PROGRESS_INTERVAL_MS,
  advanceOnEnd,
  manualNextIndex,
  manualPreviousIndex,
  nextRepeatMode,
  setShuffle,
  reportProgress,
  reportStart,
  reportStopped,
  resolveStream,
  resumeTicks,
  stopActiveEncoding,
} from '@cascade/core';
import type { JfItem, PlaybackState, PlayMethod, RepeatMode, ResolvedStream } from '@cascade/core';

import { getJellyfinClient, getServerConfig } from '../api/client';

const TICKS_PER_SEC = 10_000_000;

/** 'ios' covers tvOS and visionOS too - react-native-tvos still reports
 *  Platform.OS as 'ios' on a tvOS build (Platform.isTV is what tells the two
 *  apart), and AVPlayer backs all three. Only Android needs its own profile. */
const DEVICE_PROFILE = Platform.OS === 'android' ? ANDROID_PROFILE : APPLE_PROFILE;
const MAX_BITRATE = DEVICE_PROFILE.MaxStreamingBitrate ?? DEFAULT_MAX_BITRATE;

export interface PlaybackSnapshot {
  item: JfItem | null;
  queue: JfItem[];
  index: number;
  /** null until PlaybackInfo resolves - the gate NowPlayingBar uses to decide
   *  whether there is anything for <Video> to mount. Kept out of the getter
   *  pattern on purpose: a fresh object every render would look like a new
   *  source to react-native-video and reload the stream on every tick. */
  source: ReactVideoSource | null;
  isPaused: boolean;
  /** Between a play()/next()/previous() call landing and its stream actually
   *  resolving - so the bar can show "loading", not a stale track. */
  isLoading: boolean;
  positionSec: number;
  durationSec: number;
  error: string | null;
  repeat: RepeatMode;
  shuffle: boolean;
}

const EMPTY_SNAPSHOT: PlaybackSnapshot = {
  item: null,
  queue: [],
  index: -1,
  source: null,
  isPaused: true,
  isLoading: false,
  positionSec: 0,
  durationSec: 0,
  error: null,
  repeat: 'none',
  shuffle: false,
};

type Listener = () => void;

class PlaybackServiceImpl {
  private snapshot: PlaybackSnapshot = EMPTY_SNAPSHOT;
  private listeners = new Set<Listener>();
  private playerRef: VideoRef | null = null;
  private progressTimer: ReturnType<typeof setInterval> | null = null;

  // The active resolved stream - kept so seeking, reporting and abandoning an
  // encode all know what they're dealing with without re-resolving.
  private resolved: ResolvedStream | null = null;
  private playMethod: PlayMethod = 'DirectPlay';
  // Ticks the current *stream* begins at - non-zero only for a transcode
  // asked to start partway in (ResolvedStream.startTicks). Added to the
  // player's own currentTime to get a real position, same as renderer.js.
  private streamStartTicks = 0;
  // Bumped on every load/seek/stop so a resolution already in flight can tell
  // it has been superseded and drop its own result - the same guard
  // playCurrentTrack does by re-checking `queue[queueIndex]?.Id` afterwards.
  private loadToken = 0;

  // The pre-shuffle order, held while shuffle is on so turning it off can put
  // the queue back. Lives here rather than in the snapshot because no view
  // renders it - it is bookkeeping, not state anyone draws.
  private unshuffled: JfItem[] | null = null;

  getSnapshot = (): PlaybackSnapshot => this.snapshot;

  subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  private set(patch: Partial<PlaybackSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    this.listeners.forEach(l => l());
  }

  /** Registered by NowPlayingBar's <Video ref={...}>. The only thing that
   *  needs the native ref at all - play/pause is the controlled prop. */
  attachPlayer = (ref: VideoRef | null): void => {
    this.playerRef = ref;
  };

  // ── Transport ────────────────────────────────────────────────────────────

  play = async (items: JfItem[], startIndex: number): Promise<void> => {
    if (startIndex < 0 || startIndex >= items.length) return;
    this.set({ queue: items });
    await this.loadIndex(startIndex);
  };

  pause = (): void => {
    if (!this.snapshot.item) return;
    this.set({ isPaused: true });
    this.reportNow();
  };

  resume = (): void => {
    if (!this.snapshot.item) return;
    this.set({ isPaused: false });
    this.reportNow();
  };

  /** Seeks to an absolute position in the current track, in seconds. */
  seek = async (sec: number): Promise<void> => {
    const item = this.snapshot.item;
    if (!item || !this.resolved) return;

    if (this.resolved.direct) {
      // The whole file is already local to the player - no server round trip.
      this.playerRef?.seek(sec);
      this.set({ positionSec: sec });
      this.reportNow();
      return;
    }

    // A transcode only ever exposes what has already been encoded, so seeking
    // it means asking for a fresh stream starting at the new offset - see
    // withStartTicks() in @cascade/core's playback.ts.
    //
    // ponytail: always a fresh PlaybackInfo round trip, unlike renderer.js's
    // restartStreamAt fast path (which reuses the cached transcode URL and
    // only re-negotiates for an audio-track change). Add the cached-URL path
    // if a seek's ~1s round trip turns out to matter on a real connection.
    const token = ++this.loadToken;
    this.abandonEncode();
    const resolved = await resolveStream(
      getJellyfinClient(), getServerConfig(), item.Id, DEVICE_PROFILE, MAX_BITRATE, 'Audio',
      { startTicks: Math.round(sec * TICKS_PER_SEC) },
    );
    if (token !== this.loadToken) return; // superseded by a later seek/skip

    this.adopt(resolved);
    this.set({ positionSec: sec });
    this.reportNow();
  };

  next = (): void => {
    const i = manualNextIndex(this.snapshot.queue.length, this.snapshot.index, this.snapshot.repeat);
    if (i < 0) {
      this.stop();
      return;
    }
    void this.loadIndex(i);
  };

  previous = (): void => {
    const i = manualPreviousIndex(this.snapshot.queue.length, this.snapshot.index, this.snapshot.repeat);
    if (i < 0) return;
    void this.loadIndex(i);
  };

  /** Steps the repeat button: none -> all -> one -> none. */
  cycleRepeat = (): void => {
    this.set({ repeat: nextRepeatMode(this.snapshot.repeat) });
  };

  /** Reorders the queue around whatever is playing. */
  toggleShuffle = (): void => {
    const on = !this.snapshot.shuffle;
    const next = setShuffle(
      { items: this.snapshot.queue, index: this.snapshot.index, unshuffled: this.unshuffled },
      on,
    );
    this.unshuffled = next.unshuffled;
    // Only the ordering changes - the track keeps playing untouched, which is
    // the whole point of core moving it to the front on shuffle-on.
    this.set({ queue: next.items, index: next.index, shuffle: on });
  };

  stop = (): void => {
    if (this.snapshot.item) this.reportStoppedNow();
    this.abandonEncode();
    this.stopReporting();
    this.resolved = null;
    this.playerRef = null;
    this.loadToken++; // invalidates anything still resolving behind this
    this.unshuffled = null;
    // Repeat and shuffle survive: they are the user's settings, not part of
    // what happens to be playing, and a queue ending should not silently turn
    // them off.
    this.set({ ...EMPTY_SNAPSHOT, repeat: this.snapshot.repeat, shuffle: this.snapshot.shuffle });
  };

  // ── react-native-video event handlers, bound once by NowPlayingBar ───────

  handleLoad = (e: OnLoadData): void => {
    this.set({ durationSec: e.duration });
    // Direct play ignores startTicks server-side (the whole file comes back,
    // not a stream cut to start partway through), so a resume position has to
    // be seeked locally - and only once the player has metadata to seek into,
    // same ordering renderer.js gets from waiting on 'loadedmetadata'.
    const item = this.snapshot.item;
    const resume = item ? resumeTicks(item) : 0;
    if (this.resolved?.direct && resume > 0) {
      this.playerRef?.seek(resume / TICKS_PER_SEC);
    }
  };

  handleProgress = (e: OnProgressData): void => {
    this.set({ positionSec: (this.streamStartTicks + e.currentTime * TICKS_PER_SEC) / TICKS_PER_SEC });
  };

  handleEnd = (): void => {
    // Not this.next(): ending a track and pressing next differ under
    // repeat-one, which replays on end but must still skip on a press.
    const what = advanceOnEnd(this.snapshot.queue.length, this.snapshot.index, this.snapshot.repeat);
    if (what.action === 'stop') {
      this.stop();
      return;
    }
    if (what.action === 'restart') {
      void this.seek(0);
      return;
    }
    void this.loadIndex(what.index);
  };

  handleError = (e: OnVideoErrorData): void => {
    this.set({
      isLoading: false,
      error: e.error?.errorString || e.error?.localizedDescription || 'Playback error',
    });
  };

  // react-native-video's own isPlaying/isSeeking - unused. `paused` in the
  // snapshot is this service's own source of truth, not something to read
  // back from the player, so there is nothing for this handler to do but
  // exist for the prop type.
  handlePlaybackStateChanged = (_e: OnPlaybackStateChangedData): void => {};

  // ── internals ────────────────────────────────────────────────────────────

  private async loadIndex(index: number): Promise<void> {
    const item = this.snapshot.queue[index];
    if (!item) return;

    if (this.snapshot.item) this.reportStoppedNow();
    this.abandonEncode();
    this.resolved = null;
    this.playMethod = 'DirectPlay';
    this.streamStartTicks = 0;

    const token = ++this.loadToken;
    this.set({
      index, item, isPaused: false, isLoading: true, source: null,
      positionSec: 0, durationSec: 0, error: null,
    });

    const startTicks = resumeTicks(item);
    let resolved: ResolvedStream;
    try {
      resolved = await resolveStream(
        getJellyfinClient(), getServerConfig(), item.Id, DEVICE_PROFILE, MAX_BITRATE, 'Audio', { startTicks });
    } catch (err) {
      if (token === this.loadToken) {
        this.set({ isLoading: false, error: err instanceof Error ? err.message : String(err) });
      }
      return;
    }
    if (token !== this.loadToken) return; // a later play/next/previous won the race

    this.adopt(resolved);
    void reportStart(getJellyfinClient(), this.snapshotState());
    this.startReporting();
  }

  private adopt(resolved: ResolvedStream): void {
    this.resolved = resolved;
    this.playMethod = resolved.direct ? 'DirectPlay' : 'Transcode';
    this.streamStartTicks = resolved.startTicks;
    const item = this.snapshot.item;
    this.set({ isLoading: false, source: item ? this.buildSource(item, resolved.url) : null });
  }

  private buildSource(item: JfItem, url: string): ReactVideoSource {
    const client = getJellyfinClient();
    return {
      uri: url,
      metadata: {
        title: item.Name,
        artist: item.AlbumArtist || item.Artists?.[0],
        imageUri: client.artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary) ?? undefined,
      },
    };
  }

  /** Tells the server to give up on the transcode we're about to abandon -
   *  added after abandoned encoders pinned a real server at load 8.89. Every
   *  path that repoints or drops the player (loadIndex, seek, stop) calls
   *  this before it does. Best-effort and never awaited, matching
   *  stopActiveEncoding's own contract: a seek should feel instant, and a
   *  server that never hears about it only wastes CPU, not correctness. */
  private abandonEncode(): void {
    if (this.playMethod !== 'Transcode' || !this.resolved?.playSessionId) return;
    void stopActiveEncoding(getJellyfinClient(), getServerConfig(), this.resolved.playSessionId);
  }

  private snapshotState(positionTicks?: number): PlaybackState {
    const s = this.snapshot;
    return {
      itemId: s.item?.Id ?? '',
      positionTicks: positionTicks ?? Math.round(s.positionSec * TICKS_PER_SEC),
      isPaused: s.isPaused,
      isMuted: false,
      volumeLevel: 100,
      playSessionId: this.resolved?.playSessionId ?? null,
      mediaSourceId: this.resolved?.mediaSourceId ?? null,
      playMethod: this.playMethod,
      mediaType: 'Audio',
    };
  }

  private reportNow(): void {
    if (!this.snapshot.item) return;
    void reportProgress(getJellyfinClient(), this.snapshotState());
  }

  private reportStoppedNow(): void {
    void reportStopped(getJellyfinClient(), this.snapshotState());
  }

  private startReporting(): void {
    this.stopReporting();
    this.progressTimer = setInterval(() => this.reportNow(), PROGRESS_INTERVAL_MS);
  }

  private stopReporting(): void {
    if (this.progressTimer) clearInterval(this.progressTimer);
    this.progressTimer = null;
  }
}

/** One instance for the whole signed-in session, same shape as
 *  getJellyfinClient() - screens reach it through this, never by
 *  constructing their own. */
export const playbackService = new PlaybackServiceImpl();

/** Subscribes a component to playback state. useSyncExternalStore rather than
 *  a useEffect+useState pair because the store lives outside React and can
 *  change from a timer or a native event, not just from a render. */
export function usePlaybackSnapshot(): PlaybackSnapshot {
  return useSyncExternalStore(playbackService.subscribe, playbackService.getSnapshot);
}
