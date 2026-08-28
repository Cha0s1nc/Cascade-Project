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
  clipboard: {
    write: (text) => ipcRenderer.invoke('clipboard-write', text),
  },
  shell: {
    openExternal: (url) => ipcRenderer.invoke('shell-open', url),
  },
  download:        (url, filename) => ipcRenderer.invoke('download-file', url, filename),
  checkForUpdates: () => ipcRenderer.invoke('check-for-updates'),
  getVersion:      () => ipcRenderer.invoke('get-version'),
  isPackaged:      () => ipcRenderer.invoke('is-packaged'),
  isDebugMode:     () => ipcRenderer.invoke('is-debug-mode'),
  onMediaKey:      (cb) => { ipcRenderer.on('media-key', (_e, key) => cb(key)) },
  platform:        process.platform,
  touchbarUpdate:  (data) => ipcRenderer.send('touchbar-update', data),
  setTitleBarOverlay: (mode) => ipcRenderer.send('set-titlebar-overlay', { mode }),
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
  miniPlayer: {
    open:        () => ipcRenderer.send('open-miniplayer'),
    updateState: (state) => ipcRenderer.send('miniplayer-state', state),
    onControl:   (cb) => { ipcRenderer.on('miniplayer-control', (_e, action) => cb(action)) },
  },
}

contextBridge.exposeInMainWorld('cascade', cascade)
