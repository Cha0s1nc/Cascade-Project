/**
 * Being a Jellyfin cast target: the phone or TV shows up in another client's
 * "Play On" list and obeys it.
 *
 * The protocol is core's RemoteControl, unchanged. This is only the handler
 * table, which is the part that is genuinely per-platform - the desktop's
 * equivalent pokes an <audio> element and clicks DOM buttons; here every command
 * lands on PlaybackService.
 *
 * This is what replaces the desktop's local control server on 127.0.0.1
 * (main.js:90-146). That is dropped rather than ported: React Native has no
 * http.createServer, iOS kills background loopback listeners, and its job was
 * always covered by this anyway.
 *
 * @format
 */
import { RemoteControl, acceptsRemoteCommand } from '@cascade/core';
import type { JfItem } from '@cascade/core';

import { getJellyfinClient, getServerConfig } from '../api/client';
import { playbackService } from '../playback/PlaybackService';
import { waterfallService } from '../waterfall/WaterfallService';

const TICKS_PER_SEC = 10_000_000;

/** How much one VolumeUp/VolumeDown press moves things, matching the desktop. */
const VOLUME_STEP = 0.1;

let remote: RemoteControl | null = null;

/**
 * Start advertising this device. Safe to call again; it replaces any previous
 * registration.
 *
 * `userId` is needed because the command carries item ids and nothing else, so
 * the items have to be fetched before anything can play.
 */
export function startRemoteControl(userId: string): void {
  stopRemoteControl();

  const client = getJellyfinClient();

  remote = new RemoteControl(
    client,
    getServerConfig,
    {
      async play(itemIds, startIndex) {
        if (!itemIds.length) return;
        const res = await client
          .get<{ Items?: JfItem[] }>(`/Users/${userId}/Items`, {
            Ids: itemIds.join(','),
            Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData',
          })
          .catch(() => null);

        const items = res?.Items || [];
        if (!items.length) return;

        // Jellyfin answers in its own order, so restore the order the
        // controller actually sent - otherwise "play these five, starting at
        // the third" starts on the wrong track.
        const byId = new Map(items.map(i => [i.Id, i]));
        const ordered = itemIds.map(id => byId.get(id)).filter((i): i is JfItem => !!i);

        await playbackService.play(ordered.length ? ordered : items, startIndex);
      },
      playPause() {
        if (playbackService.getSnapshot().isPaused) playbackService.resume();
        else playbackService.pause();
      },
      pause: playbackService.pause,
      unpause: playbackService.resume,
      stop: playbackService.stop,
      nextTrack: playbackService.next,
      previousTrack: playbackService.previous,
      seek(positionTicks) {
        void playbackService.seek(positionTicks / TICKS_PER_SEC);
      },
      setVolume(percent) {
        playbackService.setVolume(percent / 100);
      },
      volumeUp() {
        playbackService.setVolume(playbackService.getSnapshot().volume + VOLUME_STEP);
      },
      volumeDown() {
        playbackService.setVolume(playbackService.getSnapshot().volume - VOLUME_STEP);
      },
      toggleMute: playbackService.toggleMuted,
      setMute: playbackService.setMuted,
    },
    // Refuse commands while a Waterfall host owns playback: two things driving
    // the same player fight, and those bugs are miserable because each side
    // looks correct on its own.
    () => {
      const room = waterfallService.getSnapshot();
      return acceptsRemoteCommand({
        waterfallActive: room.status === 'connected',
        waterfallIsHost: room.role === 'host',
        waterfallApplying: false,
      });
    },
  );

  // Not fatal - playback works without it - but it must be visible. Swallowing
  // this on the desktop once hid a malformed capabilities payload that left
  // Cascade invisible as a cast target with no symptom to chase.
  remote.start().catch(err => {
    console.warn('[cascade] remote control unavailable:', err?.message || err);
  });
}

export function stopRemoteControl(): void {
  remote?.stop();
  remote = null;
}
