// The host-platform contract.
//
// Everything Cascade needs that is not plain web API: persistent storage, and a
// set of desktop integrations that only exist on desktop. Splitting them is the
// point - a webOS/Tizen/React Native host implements `Platform` (storage plus a
// version string) and simply omits the rest.
//
// This is also the single definition of what `window.cascade` is. src/preload.ts
// implements it and types/cascade.d.ts declares the global from it, so the
// bridge and its type surface cannot drift apart.

/** Persistent key-value storage. localStorage on a TV, electron-store here. */
export interface PlatformStorage {
  /**
   * Deliberately `any`: a schemaless JSON KV store. Typing it `unknown` would
   * force a cast at every call site for no real safety gain. Values are often
   * stringified booleans ('true').
   */
  get(key: string): Promise<any>
  set(key: string, value: unknown): Promise<void>
  delete(key: string): Promise<void>
}

/** What main.js merges into its now-playing state. Partial: call sites push
 *  updates like `{ isPlaying: false }` on their own. */
export interface NowPlayingUpdate {
  title?: string
  artist?: string
  album?: string
  isPlaying?: boolean
  /** Jellyfin ids, so a consumer with its own session can build an artwork URL
   *  rather than being handed one carrying this client's token. */
  artItemId?: string
  artImageTag?: string
  durationMs?: number | null
  positionMs?: number | null
}

/** The live Jellyfin session, handed to the control server so Cha0s Stream can
 *  talk to the same server without the user configuring Jellyfin twice. */
export interface JellyfinCredentials {
  url: string
  token: string
  userId: string
}

/** macOS TouchBar state. Partial for the same reason as NowPlayingUpdate. */
export interface TouchBarUpdate {
  title?: string
  playing?: boolean
}

/** Discord rich presence. The numeric activity type is injected by main.js at
 *  the protocol level, because discord-rpc's setActivity() rebuilds the payload
 *  from a fixed field list and drops anything else. Callers pick between the two
 *  types Cascade uses with `watching`, not by setting a number. */
export interface DiscordActivity {
  details: string
  state: string
  /** Both timestamps together are what makes Discord draw a progress bar; a
   *  start on its own only gets the "XX:XX elapsed" line. Absent while paused,
   *  since they are wall-clock and would otherwise keep running. */
  startTimestamp?: number
  endTimestamp?: number
  largeImageKey?: string
  largeImageText?: string
  /** true renders as "Watching Cascade", false/absent as "Listening to Cascade". */
  watching?: boolean
}

/** Result of an update check. `error` is set when GitHub could not be reached;
 *  the updater window is its own feedback when an update is found. */
export interface UpdateCheckResult {
  hasUpdate: boolean
  error?: string
}

/** One Electron process, as the debug panel's resources section shows it. */
export interface ProcessMetric {
  type: string
  pid: number
  memMB: number
  /** Percent of one core since the previous call. */
  cpu: number
  /** Always 0 on Windows. */
  wakeups: number
}

/** One on-device translation model, as main.js reports it. */
export interface TranslationModelStatus {
  name: string
  /** Total download size of every file in the model. */
  bytes: number
  state: 'absent' | 'downloading' | 'ready'
  /** Bytes downloaded so far; 0 unless downloading. */
  transferred: number
}

export interface TranslationModelProgress {
  key: string
  state: 'absent' | 'downloading' | 'ready'
  transferred: number
  total: number
}

export interface KugouLyricsQuery {
  title: string
  artist: string
  durationMs: number
}

/**
 * The minimum a host must provide.
 *
 * Keep this small. Anything added here becomes work for every future platform,
 * so if a capability can be optional, it belongs below instead.
 */
export interface Platform {
  store: PlatformStorage
  /** Host identifier, e.g. 'darwin', 'win32', 'webos'. */
  platform: string
  getVersion(): Promise<string>
}

/**
 * Desktop integrations. All optional: a TV host omits every one of them.
 *
 * The property name is the feature test - `if (platform.discord)` rather than a
 * capability-flags object that could disagree with reality.
 */
export interface DesktopCapabilities {
  clipboard?: { write(text: string): Promise<void> }
  shell?: { openExternal(url: string): Promise<void> }
  download?(url: string, filename: string): Promise<unknown>

  checkForUpdates?(): Promise<UpdateCheckResult>
  isPackaged?(): Promise<boolean>
  /** True when the `.cascade-debug` sentinel file was present at startup.
   *  Gates the renderer's debug panel - see main.js debugSentinelPresent(). */
  isDebugMode?(): Promise<boolean>
  /** Per-process memory and CPU, for the debug panel. */
  appMetrics?(): Promise<ProcessMetric[]>

  onMediaKey?(cb: (key: string) => void): void
  touchbarUpdate?(data: TouchBarUpdate): void
  nowPlayingUpdate?(data: NowPlayingUpdate): void
  jellyfinCredentialsUpdate?(data: JellyfinCredentials): void
  /** Recolours the OS-drawn Windows/Linux caption buttons to match the active
   *  theme. No-op on macOS, where the traffic lights are not ours to colour. */
  setTitleBarOverlay?(mode: 'light' | 'dark'): void

  discord?: {
    connect(clientId: string): void
    update(activity: DiscordActivity): void
    clear(): void
    onStatus(cb: (connected: boolean) => void): void
  }

  /** Returns raw KRC text, or null when Kugou has no match. */
  kugouGetLyrics?(opts: KugouLyricsQuery): Promise<string | null>

  lyricsEditor?: {
    open(data: unknown): void
    onSaved(cb: (itemId: string) => void): void
  }

  metadataEditor?: {
    open(data: unknown): void
    onSaved(cb: (itemId: string) => void): void
  }

  /**
   * The miniplayer is a remote control view, not a second player - it mirrors
   * playback state over IPC rather than loading its own media element. See
   * CODEMAP.md on why: the two <video> decks and the Web Audio graph they
   * feed live only in the main window, and a second BrowserWindow with its
   * own media element would mean a fresh Jellyfin stream negotiation and
   * every track restarting.
   */
  /** Apple's on-device Translation framework, through a helper process.
   *  Only macOS 26+; `supported()` is false everywhere else. */
  appleTranslation?: {
    supported(): Promise<boolean>
    /** Per model key: installed in macOS, installable, or not offered by Apple. */
    availability(): Promise<Record<string, 'installed' | 'supported' | 'unsupported'>>
    /** One line into English. Rejects if the language is not installed. */
    translate(key: string, text: string): Promise<string>
    /** Opens System Settings at Language & Region. */
    openSettings(): Promise<void>
  }
  /** Translated lyric lines on disk, as [cacheKey, english, translatedAtMs]
   *  entries. `load` returns the file as parsed, unchecked. */
  translationCache?: {
    load(): Promise<unknown>
    save(entries: [string, string, number][]): Promise<void>
  }
  /** Download, inspect and remove the on-device lyric translation models.
   *  Keys are the manifest's: 'ja', 'ko', 'zh-Hans', 'zh-Hant'. */
  translationModels?: {
    status(): Promise<Record<string, TranslationModelStatus>>
    /** Resolves once the model is installed and verified; a second call for
     *  the same key joins the download already running. */
    download(key: string): Promise<void>
    remove(key: string): Promise<void>
    onProgress(cb: (p: TranslationModelProgress) => void): void
  }
  miniPlayer?: {
    /** Opens the miniplayer window (creating it if needed) and minimizes the
     *  main window, mirroring Spotify/Apple Music's compact mode. */
    open(): void
    /** Pushes a state snapshot to the miniplayer window, if one is open. */
    updateState(state: unknown): void
    /** A control button in the miniplayer window was pressed. Restoring the
     *  main window on a click there is handled entirely in the main process
     *  (BrowserWindow.restore()) - nothing for this window to do. */
    onControl(cb: (action: string) => void): void
    /** The miniplayer window opened (true) or closed (false). */
    onOpenChange(cb: (open: boolean) => void): void
  }
}

/**
 * What Electron actually exposes: every optional capability, present.
 *
 * Re-stated as required so renderer.js can keep calling
 * `window.cascade.discord.connect(...)` without optional chaining.
 */
export interface ElectronPlatform extends Platform, DesktopCapabilities {
  clipboard: NonNullable<DesktopCapabilities['clipboard']>
  shell: NonNullable<DesktopCapabilities['shell']>
  download: NonNullable<DesktopCapabilities['download']>
  checkForUpdates: NonNullable<DesktopCapabilities['checkForUpdates']>
  isPackaged: NonNullable<DesktopCapabilities['isPackaged']>
  isDebugMode: NonNullable<DesktopCapabilities['isDebugMode']>
  appMetrics: NonNullable<DesktopCapabilities['appMetrics']>
  onMediaKey: NonNullable<DesktopCapabilities['onMediaKey']>
  touchbarUpdate: NonNullable<DesktopCapabilities['touchbarUpdate']>
  nowPlayingUpdate: NonNullable<DesktopCapabilities['nowPlayingUpdate']>
  jellyfinCredentialsUpdate: NonNullable<DesktopCapabilities['jellyfinCredentialsUpdate']>
  setTitleBarOverlay: NonNullable<DesktopCapabilities['setTitleBarOverlay']>
  discord: NonNullable<DesktopCapabilities['discord']>
  kugouGetLyrics: NonNullable<DesktopCapabilities['kugouGetLyrics']>
  lyricsEditor: NonNullable<DesktopCapabilities['lyricsEditor']>
  metadataEditor: NonNullable<DesktopCapabilities['metadataEditor']>
  appleTranslation: NonNullable<DesktopCapabilities['appleTranslation']>
  translationCache: NonNullable<DesktopCapabilities['translationCache']>
  translationModels: NonNullable<DesktopCapabilities['translationModels']>
  miniPlayer: NonNullable<DesktopCapabilities['miniPlayer']>
}
