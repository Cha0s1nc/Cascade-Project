// Electron preload: builds `window.cascade`, the renderer's only route to the
// main process.
//
// Typed as ElectronPlatform, so this file and types/cascade.d.ts are checked
// against one contract - adding a method here without declaring it (or vice
// versa) is now a build error rather than a silent mismatch.
//
// Bundled to build/preload.js (cjs, node target, electron external).

import { contextBridge, ipcRenderer } from 'electron'
import type { ElectronPlatform } from './platform/index.ts'

const cascade: ElectronPlatform = {
  store: {
    get:    (key) => ipcRenderer.invoke('store-get', key),
    set:    (key, value) => ipcRenderer.invoke('store-set', key, value),
    delete: (key) => ipcRenderer.invoke('store-delete', key),
  },
  // Reverse-proxy support: extra headers (applied in the main process, to the
  // Jellyfin server's origin only) and the remembered client certificate.
  connection: {
    getHeaders:       () => ipcRenderer.invoke('connection-get-headers'),
    set:              (serverUrl, headers, persist) => ipcRenderer.invoke('connection-set', serverUrl, headers, persist),
    resetCertificate: () => ipcRenderer.invoke('connection-reset-certificate'),
  },
  offline: {
    setOwner: (userId) => ipcRenderer.invoke('offline-owner', userId),
    summary:  () => ipcRenderer.invoke('offline-summary'),
    tracks:   (collectionId) => ipcRenderer.invoke('offline-tracks', collectionId),
    add:      (collection, tracks, session, opts) => ipcRenderer.invoke('offline-add', collection, tracks, session, opts),
    setVideoProfile: (profile) => ipcRenderer.invoke('offline-video-profile', profile),
    follow:   (seriesId, on) => ipcRenderer.invoke('offline-follow', seriesId, on),
    addEpisodes: (seriesId, items, session, containers) => ipcRenderer.invoke('offline-add-episodes', seriesId, items, session, containers),
    watched:  (id) => ipcRenderer.invoke('offline-watched', id),
    removeWatched: () => ipcRenderer.invoke('offline-remove-watched'),
    remove:   (collectionId) => ipcRenderer.invoke('offline-remove', collectionId),
    resume:   (session) => ipcRenderer.invoke('offline-resume', session),
    addPlay:  (play) => ipcRenderer.invoke('offline-play-add', play),
    takePlays: () => ipcRenderer.invoke('offline-plays-take'),
    holdPlays: (held) => ipcRenderer.invoke('offline-plays-hold', held),
    discardPlays: () => ipcRenderer.invoke('offline-plays-discard'),
    addChange: (change) => ipcRenderer.invoke('offline-change-add', change),
    takeChanges: () => ipcRenderer.invoke('offline-changes-take'),
    setHistory: (items) => ipcRenderer.invoke('offline-set-history', items),
    setUserData: (items) => ipcRenderer.invoke('offline-set-user-data', items),
    setLimit: (bytes) => ipcRenderer.invoke('offline-limit', bytes),
    onEvent:  (cb) => { ipcRenderer.on('offline-event', (_e, event) => cb(event)) },
    catalog:  () => ipcRenderer.invoke('offline-catalog'),
    setLibraries: (views) => ipcRenderer.invoke('offline-set-libraries', views),
    setUser:  (user) => ipcRenderer.invoke('offline-set-user', user),
    place:    (libraryId, items) => ipcRenderer.invoke('offline-place', libraryId, items),
    setLyrics: (trackId, lyrics) => ipcRenderer.invoke('offline-set-lyrics', trackId, lyrics),
    dropLyrics: (trackId) => ipcRenderer.invoke('offline-drop-lyrics', trackId),
    disk:     () => ipcRenderer.invoke('offline-disk'),
    setMode:  (state) => ipcRenderer.invoke('offline-mode', state),
  },
  local: {
    start:        (profile) => ipcRenderer.invoke('local-start', profile),
    summary:      () => ipcRenderer.invoke('local-summary'),
    catalog:      () => ipcRenderer.invoke('local-catalog'),
    rescan:       () => ipcRenderer.invoke('local-rescan'),
    chooseFolder: () => ipcRenderer.invoke('local-choose-folder'),
    addFolder:    () => ipcRenderer.invoke('local-add-folder'),
    removeFolder: (path: string) => ipcRenderer.invoke('local-remove-folder', path),
    setProfile:   (profile) => ipcRenderer.invoke('local-set-profile', profile),
    change:       (itemId, change) => ipcRenderer.invoke('local-change', itemId, change),
    playlist:     (op) => ipcRenderer.invoke('local-playlist', op),
    lyrics:       (itemId) => ipcRenderer.invoke('local-lyrics', itemId),
    onEvent:      (cb) => { ipcRenderer.on('local-event', (_e, event) => cb(event)) },
  },
  spicy: {
    lyrics: (q) => ipcRenderer.invoke('spicy-lyrics', q),
    status: () => ipcRenderer.invoke('spicy-status'),
    setKey: (key) => ipcRenderer.invoke('spicy-set-key', key),
  },
  clipboard: {
    write: (text) => ipcRenderer.invoke('clipboard-write', text),
    read:  () => ipcRenderer.invoke('clipboard-read'),
  },
  presets: {
    save: (fileName, text) => ipcRenderer.invoke('preset-save', fileName, text),
    open: () => ipcRenderer.invoke('preset-open'),
  },
  shell: {
    openExternal: (url) => ipcRenderer.invoke('shell-open', url),
  },
  download:        (url, filename) => ipcRenderer.invoke('download-file', url, filename),
  checkForUpdates: () => ipcRenderer.invoke('check-for-updates'),
  fetchAnnouncements: () => ipcRenderer.invoke('announcements-fetch'),
  canTryNativeMac: () => ipcRenderer.invoke('can-try-native-mac'),
  tryNativeMac:    () => ipcRenderer.invoke('try-native-mac'),
  getVersion:      () => ipcRenderer.invoke('get-version'),
  isPackaged:      () => ipcRenderer.invoke('is-packaged'),
  isDebugMode:     () => ipcRenderer.invoke('is-debug-mode'),
  tuningBake:      (payload) => ipcRenderer.invoke('tuning-bake', payload),
  appMetrics:      () => ipcRenderer.invoke('app-metrics'),
  onMediaKey:      (cb) => { ipcRenderer.on('media-key', (_e, key) => cb(key)) },
  platform:        process.platform,
  touchbarUpdate:  (data) => ipcRenderer.send('touchbar-update', data),
  setTitleBarOverlay: (mode) => ipcRenderer.send('set-titlebar-overlay', { mode }),
  setWindowButtonsVisible: (visible) => ipcRenderer.send('set-window-buttons-visible', !!visible),
  discord: {
    connect:  (clientId) => ipcRenderer.send('discord-rpc-connect', clientId),
    update:   (activity) => ipcRenderer.send('discord-rpc-update', activity),
    clear:    () => ipcRenderer.send('discord-rpc-clear'),
    onStatus: (cb) => { ipcRenderer.on('discord-rpc-status', (_e, connected) => cb(connected)) },
  },
  nowPlayingUpdate: (data) => ipcRenderer.send('now-playing-update', data),
  jellyfinCredentialsUpdate: (data) => ipcRenderer.send('jellyfin-credentials', data),
  kugouGetLyrics:   (opts) => ipcRenderer.invoke('kugou-lyrics', opts),
  lyricsEditor: {
    open:    (data) => ipcRenderer.send('open-lyrics-editor', data),
    onSaved: (cb) => { ipcRenderer.on('lyrics-saved', (_e, itemId) => cb(itemId)) },
  },
  metadataEditor: {
    open:    (data) => ipcRenderer.send('open-metadata-editor', data),
    onSaved: (cb) => { ipcRenderer.on('metadata-saved', (_e, itemId) => cb(itemId)) },
  },
  appleTranslation: {
    supported:    () => ipcRenderer.invoke('apple-translation:supported'),
    availability: (languages) => ipcRenderer.invoke('apple-translation:availability', languages),
    translate:    (key, text) => ipcRenderer.invoke('apple-translation:translate', key, text),
    openSettings: () => ipcRenderer.invoke('apple-translation:open-settings'),
  },
  translationCache: {
    load: () => ipcRenderer.invoke('translation-cache:load'),
    save: (entries) => ipcRenderer.invoke('translation-cache:save', entries),
  },
  translationModels: {
    status:     () => ipcRenderer.invoke('translation-models:status'),
    download:   (key) => ipcRenderer.invoke('translation-models:download', key),
    remove:     (key) => ipcRenderer.invoke('translation-models:remove', key),
    onProgress: (cb) => { ipcRenderer.on('translation-models:progress', (_e, p) => cb(p)) },
  },
  miniPlayer: {
    open:        () => ipcRenderer.send('open-miniplayer'),
    updateState: (state) => ipcRenderer.send('miniplayer-state', state),
    onControl:   (cb) => { ipcRenderer.on('miniplayer-control', (_e, action) => cb(action)) },
    onOpenChange: (cb) => { ipcRenderer.on('miniplayer-open-state', (_e, open) => cb(!!open)) },
  },
}

contextBridge.exposeInMainWorld('cascade', cascade)
