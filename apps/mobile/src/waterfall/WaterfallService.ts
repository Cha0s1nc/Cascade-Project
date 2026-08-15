/**
 * Waterfall: listening to the same thing, in sync, on different machines.
 *
 * The protocol is entirely in @cascade/core (waterfall-protocol.ts) and is
 * reused verbatim. What is *not* reused is apps/desktop/waterfall.js, which
 * reaches straight into renderer.js's `queue` and `queueIndex` globals across a
 * script boundary. Here everything goes through PlaybackService, which is the
 * whole reason that interface exists.
 *
 * One concern the desktop never had: a phone's socket dies when the app
 * backgrounds or the network switches from Wi-Fi to cellular, and neither of
 * those produces a clean close. AppState drives a reconnect-and-resync.
 *
 * @format
 */
import { AppState } from 'react-native';
import { useSyncExternalStore } from 'react';

import {
  WF_DEFAULT_RELAY,
  WF_HEARTBEAT_MS,
  buildControlMessage,
  buildStateMessage,
  expectedPositionMs,
  isForeignServer,
  roomSocketUrl,
  shouldReseek,
} from '@cascade/core';
import type { WfControlAction, WfStateMessage } from '@cascade/core';

import { getJellyfinClient } from '../api/client';
import { playbackService } from '../playback/PlaybackService';

export type WaterfallRole = 'host' | 'guest';

export interface RosterMember {
  id: string;
  name: string;
}

export interface WaterfallSnapshot {
  status: 'idle' | 'connecting' | 'connected' | 'error';
  role: WaterfallRole | null;
  code: string | null;
  roster: RosterMember[];
  error: string | null;
}

const IDLE: WaterfallSnapshot = {
  status: 'idle',
  role: null,
  code: null,
  roster: [],
  error: null,
};

type Listener = () => void;

class WaterfallServiceImpl {
  private snapshot: WaterfallSnapshot = IDLE;
  private listeners = new Set<Listener>();

  private ws: WebSocket | null = null;
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private serverId: string | null = null;
  private memberId: string | null = null;
  private appStateSub: { remove: () => void } | null = null;

  /** The track the guest has already loaded, so a heartbeat does not reload it
   *  four times a second. */
  private loadedTrackId: string | null = null;

  /** Shown to the room. Set once at sign-in; the socket URL carries it. */
  displayName = '';

  getSnapshot = (): WaterfallSnapshot => this.snapshot;

  subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  private set(patch: Partial<WaterfallSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const l of this.listeners) l();
  }

  // -------------------------------------------------------------------------

  /**
   * Create a room and host it. Returns the code to read out.
   *
   * The code comes from the relay, not from here. Rooms only exist once the
   * relay has minted one, so a locally invented code just 404s the socket -
   * which is exactly the failure this hit first time round.
   */
  host = async (): Promise<string> => {
    const res = await fetch(`${WF_DEFAULT_RELAY}/create`, { method: 'POST' });
    if (!res.ok) throw new Error('Could not create a room.');
    const { code } = (await res.json()) as { code?: string };
    if (!code) throw new Error('Could not create a room.');
    await this.connect(code, 'host');
    return code;
  };

  join = (code: string): Promise<void> => this.connect(code, 'guest');

  leave = (): void => {
    this.teardown(null);
  };

  /** Guest -> host. Ignored while hosting, where the controls act locally. */
  sendControl = (action: WfControlAction, positionMs?: number): void => {
    if (this.snapshot.role !== 'guest') return;
    this.send(buildControlMessage(action, positionMs));
  };

  // -------------------------------------------------------------------------

  private async connect(code: string, role: WaterfallRole): Promise<void> {
    this.teardown(null);
    this.set({ status: 'connecting', role, code, error: null });

    try {
      await this.resolveServerId();
      const name = this.displayName || 'Listener';
      const url = roomSocketUrl(WF_DEFAULT_RELAY, code, name);

      await new Promise<void>((resolve, reject) => {
        const ws = new WebSocket(url);
        let settled = false;

        ws.onmessage = ev => {
          let msg: Record<string, unknown>;
          try {
            msg = JSON.parse(String((ev as { data: unknown }).data));
          } catch {
            return;
          }

          if (msg.type === 'join-denied') {
            settled = true;
            ws.close();
            reject(new Error(msg.reason === 'room-full' ? 'That room is full.' : 'No room with that code.'));
            return;
          }

          if (msg.type === 'joined') {
            settled = true;
            this.ws = ws;
            this.memberId = String(msg.memberId ?? '');
            this.set({
              status: 'connected',
              roster: (msg.roster as RosterMember[]) ?? [],
              error: null,
            });
            // A joining guest asks whoever is hosting for the current state,
            // rather than sitting silent until the next heartbeat.
            if (role === 'guest') this.send({ k: 'hello', serverId: this.serverId });
            resolve();
            return;
          }

          if (msg.type === 'roster') {
            this.set({ roster: (msg.members as RosterMember[]) ?? [] });
            return;
          }

          if (msg.type === 'relay') this.onRelay(msg.payload as Record<string, unknown>);
        };

        ws.onerror = () => {
          if (!settled) {
            settled = true;
            reject(new Error('Could not reach the room server.'));
          }
        };

        ws.onclose = () => {
          if (settled) this.teardown('The room closed.');
        };
      });

      if (role === 'host') {
        this.heartbeat = setInterval(() => this.broadcastState(), WF_HEARTBEAT_MS);
        this.broadcastState();
      }

      // Backgrounding kills the socket without a clean close on both platforms,
      // and a Wi-Fi to cellular handover does the same. Coming back to the
      // foreground with a dead socket has to reconnect, not sit there looking
      // connected.
      this.appStateSub = AppState.addEventListener('change', state => {
        if (state !== 'active') return;
        if (this.ws && this.ws.readyState === WebSocket.OPEN) return;
        const { code: c, role: r } = this.snapshot;
        if (c && r) void this.connect(c, r);
      });
    } catch (err) {
      this.teardown(err instanceof Error ? err.message : String(err));
      throw err;
    }
  }

  private teardown(error: string | null): void {
    if (this.heartbeat) {
      clearInterval(this.heartbeat);
      this.heartbeat = null;
    }
    this.appStateSub?.remove();
    this.appStateSub = null;

    if (this.ws) {
      // Drop the handlers first: closing fires onclose, which would call back
      // into here and report "the room closed" over a deliberate leave.
      this.ws.onmessage = null;
      this.ws.onerror = null;
      this.ws.onclose = null;
      try {
        this.ws.close();
      } catch {
        /* already gone */
      }
      this.ws = null;
    }

    this.memberId = null;
    this.loadedTrackId = null;
    this.set({ ...IDLE, status: error ? 'error' : 'idle', error });
  }

  private send(payload: unknown, to?: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify({ type: 'relay', to, payload }));
  }

  private async resolveServerId(): Promise<void> {
    if (this.serverId) return;
    try {
      const info = await getJellyfinClient().get<{ Id?: string }>('/System/Info/Public');
      this.serverId = info?.Id ?? null;
    } catch {
      this.serverId = null;
    }
  }

  private broadcastState(): void {
    const s = playbackService.getSnapshot();
    if (!s.item) return;
    this.send(
      buildStateMessage({
        serverId: this.serverId,
        trackId: s.item.Id,
        positionMs: Math.round(s.positionSec * 1000),
        paused: s.isPaused,
        index: s.index,
      }),
    );
  }

  private onRelay(p: Record<string, unknown> | undefined): void {
    if (!p || typeof p !== 'object') return;

    // Members on a different Jellyfin server cannot stream the host's tracks,
    // so the room refuses rather than half-working.
    if (isForeignServer(p.serverId as string | null | undefined, this.serverId)) {
      this.teardown('That room is on a different Jellyfin server.');
      return;
    }

    if (p.k === 'hello' && this.snapshot.role === 'host') {
      this.broadcastState();
      return;
    }

    if (p.k === 'control' && this.snapshot.role === 'host') {
      this.applyControl(p as unknown as { action: WfControlAction; positionMs?: number });
      return;
    }

    if (p.k === 'state' && this.snapshot.role === 'guest') {
      this.applyState(p as unknown as WfStateMessage);
    }
  }

  private applyControl(msg: { action: WfControlAction; positionMs?: number }): void {
    const s = playbackService.getSnapshot();
    switch (msg.action) {
      case 'playpause':
        if (s.isPaused) playbackService.resume();
        else playbackService.pause();
        break;
      case 'next':
        playbackService.next();
        break;
      case 'prev':
        playbackService.previous();
        break;
      case 'seek':
        if (msg.positionMs != null) void playbackService.seek(msg.positionMs / 1000);
        break;
    }
    // Answer immediately rather than letting the room wait up to a heartbeat to
    // see what its own button did.
    this.broadcastState();
  }

  private applyState(state: WfStateMessage): void {
    const local = playbackService.getSnapshot();

    if (state.trackId && state.trackId !== local.item?.Id) {
      // Only load once per track: the host repeats its state every heartbeat,
      // and reloading on each would restart the song four times a second.
      if (this.loadedTrackId === state.trackId) return;
      this.loadedTrackId = state.trackId;
      void this.loadTrack(state);
      return;
    }

    if (state.paused !== local.isPaused) {
      if (state.paused) playbackService.pause();
      else playbackService.resume();
    }

    const target = expectedPositionMs(state);
    if (shouldReseek(local.positionSec * 1000, target)) {
      void playbackService.seek(target / 1000);
    }
  }

  private async loadTrack(state: WfStateMessage): Promise<void> {
    try {
      const item = await getJellyfinClient().get<{ Id: string }>(`/Items/${state.trackId}`);
      // play() takes a queue; a guest follows the host one track at a time, so
      // the queue is that track.
      await playbackService.play([item as never], 0);
      const target = expectedPositionMs(state);
      if (target > 0) await playbackService.seek(target / 1000);
    } catch {
      // Let the next heartbeat retry rather than wedging on one bad fetch.
      this.loadedTrackId = null;
    }
  }
}

export const waterfallService = new WaterfallServiceImpl();

export function useWaterfall(): WaterfallSnapshot {
  return useSyncExternalStore(waterfallService.subscribe, waterfallService.getSnapshot);
}
