// Makes this client a Jellyfin remote-control target: "cast to Cascade" from
// the web UI, a phone, or (later) a TV client.
//
// Two halves:
//   1. Register capabilities so the server lists us as controllable.
//   2. Hold a WebSocket and dispatch the commands that arrive on it.
//
// Only the protocol lives here. Actually starting playback is a set of callbacks
// the host platform supplies, so the same code works in Electron and on a TV.

import type { JellyfinClient } from './jellyfin.ts'
import type { ServerConfig } from './types.ts'

/** What the host platform must be able to do for a remote to be useful. */
export interface RemoteHandlers {
  /** PlayNow / PlayNext / PlayLast with the item ids the controller picked. */
  play(itemIds: string[], startIndex: number, playCommand: string): void | Promise<void>
  playPause(): void
  pause(): void
  unpause(): void
  stop(): void
  nextTrack(): void
  previousTrack(): void
  /** Absolute position, in ticks (100ns units). */
  seek(positionTicks: number): void
  /** 0-100, matching Jellyfin's scale. */
  setVolume(percent: number): void
  volumeUp(): void
  volumeDown(): void
  toggleMute(): void
  setMute(muted: boolean): void
}

/** Return false to refuse an incoming command (see ownership.ts). */
export type CommandGate = () => boolean

interface SocketMessage {
  MessageType?: string
  Data?: any
}

const KEEPALIVE_FALLBACK_MS = 30_000
const RECONNECT_MS = 5_000

/**
 * Commands declared to the server.
 *
 * **These must be GeneralCommandType values only.** Pause, PlayPause, Stop,
 * NextTrack, PreviousTrack and Seek are *PlaystateCommand* values - putting
 * them here makes Jellyfin reject the whole registration with a 400
 * ("could not be converted to GeneralCommandType"), which silently leaves the
 * client invisible as a cast target. Playstate commands need no declaration;
 * they are implied by SupportsMediaControl and still arrive over the socket.
 *
 * Only list what `handleGeneralCommand` actually implements - a declared
 * command with no handler is a dead button in the controller's UI.
 */
export const SUPPORTED_COMMANDS = [
  'SetVolume', 'ToggleMute', 'Mute', 'Unmute',
  'VolumeUp', 'VolumeDown',
  'Play', 'PlayState',
] as const

export class RemoteControl {
  private readonly client: JellyfinClient
  private readonly getConfig: () => ServerConfig
  private readonly handlers: RemoteHandlers
  private readonly gate: CommandGate

  private ws: WebSocket | null = null
  private keepAliveTimer: ReturnType<typeof setInterval> | null = null
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private stopped = true

  constructor(
    client: JellyfinClient,
    getConfig: () => ServerConfig,
    handlers: RemoteHandlers,
    gate: CommandGate = () => true,
  ) {
    this.client = client
    this.getConfig = getConfig
    this.handlers = handlers
    this.gate = gate
  }

  /**
   * Open the command socket and register with the server. Safe to call twice.
   *
   * Socket first, deliberately. Jellyfin only reports a session as controllable
   * while it holds an **open WebSocket** - `SupportsMediaControl` on the session
   * is computed from the live connection, not just from the capabilities we
   * POST. So the socket is the thing that actually makes casting work, and a
   * failed capability registration must not prevent it.
   */
  async start(): Promise<void> {
    this.stopped = false
    this.openSocket()
    await this.registerCapabilities()
  }

  stop(): void {
    this.stopped = true
    this.clearTimers()
    if (this.ws) {
      // Drop the handler first so our own close does not schedule a reconnect.
      this.ws.onclose = null
      try { this.ws.close() } catch { /* already gone */ }
      this.ws = null
    }
  }

  get connected(): boolean {
    return !!this.ws && this.ws.readyState === WebSocket.OPEN
  }

  /**
   * Register as a controllable session.
   *
   * Throws on failure, deliberately. This used to swallow errors, which hid a
   * 400 from a malformed SupportedCommands list - the feature was completely
   * dead and there was no way to tell from inside the app. If registration
   * fails the client will never appear as a cast target, so the caller needs to
   * know.
   */
  private async registerCapabilities(): Promise<void> {
    await this.client.post('/Sessions/Capabilities/Full', {
      PlayableMediaTypes: ['Audio', 'Video'],
      SupportedCommands: [...SUPPORTED_COMMANDS],
      SupportsMediaControl: true,
      SupportsPersistentIdentifier: true,
      // Not a client that can be told to display arbitrary content.
      SupportsContentUploading: false,
      SupportsSync: false,
    })
  }

  private socketUrl(): string {
    const { url, token, deviceId } = this.getConfig()
    const base = url.replace(/^http/, 'ws')
    return `${base}/socket?api_key=${encodeURIComponent(token)}&deviceId=${encodeURIComponent(deviceId || '')}`
  }

  private openSocket(): void {
    if (this.stopped) return

    let ws: WebSocket
    try {
      ws = new WebSocket(this.socketUrl())
    } catch {
      this.scheduleReconnect()
      return
    }
    this.ws = ws

    ws.onopen = () => {
      // Ask the server to tell us how often it wants a KeepAlive; until it
      // does, use a conservative default so the socket is not culled.
      this.send({ MessageType: 'KeepAlive' })
      this.startKeepAlive(KEEPALIVE_FALLBACK_MS)

      // Re-register on every (re)connect. A dropped socket removes the session
      // server-side, so capabilities registered against the old one are gone.
      this.registerCapabilities().catch(() => { /* reported at startup */ })
    }

    ws.onmessage = ev => {
      let msg: SocketMessage
      try { msg = JSON.parse(String(ev.data)) } catch { return }
      this.handleMessage(msg)
    }

    ws.onclose = () => {
      this.clearTimers()
      this.ws = null
      this.scheduleReconnect()
    }

    // onerror is always followed by onclose, which already reconnects.
    ws.onerror = () => { /* handled by onclose */ }
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return
    // ponytail: fixed interval, no backoff. This is a LAN-ish connection to a
    // server the user chose; add backoff if it ever hammers something.
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      this.openSocket()
    }, RECONNECT_MS)
  }

  private startKeepAlive(intervalMs: number): void {
    if (this.keepAliveTimer) clearInterval(this.keepAliveTimer)
    this.keepAliveTimer = setInterval(() => this.send({ MessageType: 'KeepAlive' }), intervalMs)
  }

  private clearTimers(): void {
    if (this.keepAliveTimer) { clearInterval(this.keepAliveTimer); this.keepAliveTimer = null }
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null }
  }

  private send(payload: unknown): void {
    if (!this.connected) return
    try { this.ws!.send(JSON.stringify(payload)) } catch { /* closing */ }
  }

  /** Exposed for tests; normally driven by the socket. */
  handleMessage(msg: SocketMessage): void {
    switch (msg.MessageType) {
      case 'ForceKeepAlive':
        // Data is the server's timeout in seconds; ping at half that.
        this.startKeepAlive(Math.max(1, Number(msg.Data) || 60) * 500)
        return

      case 'KeepAlive':
        return

      case 'Play':
        if (!this.gate()) return
        this.handlers.play(
          msg.Data?.ItemIds || [],
          Number(msg.Data?.StartIndex) || 0,
          String(msg.Data?.PlayCommand || 'PlayNow'),
        )
        return

      case 'Playstate':
      case 'PlayState':
        if (!this.gate()) return
        this.handlePlayState(msg.Data)
        return

      case 'GeneralCommand':
        if (!this.gate()) return
        this.handleGeneralCommand(msg.Data)
        return
    }
  }

  private handlePlayState(data: any): void {
    switch (data?.Command) {
      case 'PlayPause':     this.handlers.playPause(); return
      case 'Pause':         this.handlers.pause(); return
      case 'Unpause':       this.handlers.unpause(); return
      case 'Stop':          this.handlers.stop(); return
      case 'NextTrack':     this.handlers.nextTrack(); return
      case 'PreviousTrack': this.handlers.previousTrack(); return
      case 'Seek':          this.handlers.seek(Number(data.SeekPositionTicks) || 0); return
    }
  }

  private handleGeneralCommand(data: any): void {
    // Arguments arrive as strings even for numbers.
    const args = data?.Arguments || {}
    switch (data?.Name) {
      case 'SetVolume':  this.handlers.setVolume(clampPercent(Number(args.Volume))); return
      case 'VolumeUp':   this.handlers.volumeUp(); return
      case 'VolumeDown': this.handlers.volumeDown(); return
      case 'ToggleMute': this.handlers.toggleMute(); return
      case 'Mute':       this.handlers.setMute(true); return
      case 'Unmute':     this.handlers.setMute(false); return
    }
  }
}

function clampPercent(n: number): number {
  if (!Number.isFinite(n)) return 0
  return Math.min(100, Math.max(0, n))
}
