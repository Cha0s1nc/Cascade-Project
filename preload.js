const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('cascade', {
  store: {
    get: (key) => ipcRenderer.invoke('store-get', key),
    set: (key, value) => ipcRenderer.invoke('store-set', key, value),
    delete: (key) => ipcRenderer.invoke('store-delete', key),
  },
  clipboard: {
    write: (text) => ipcRenderer.invoke('clipboard-write', text),
  },
  shell: {
    openExternal: (url) => ipcRenderer.invoke('shell-open', url),
  },
  download: (url, filename) => ipcRenderer.invoke('download-file', url, filename),
  showNpMenu: (actions) => ipcRenderer.invoke('show-np-menu', actions),
  checkForUpdates: () => ipcRenderer.invoke('check-for-updates'),
  getVersion: () => ipcRenderer.invoke('get-version'),
  isPackaged: () => ipcRenderer.invoke('is-packaged'),
  onMediaKey: (cb) => ipcRenderer.on('media-key', (_e, key) => cb(key)),
  platform: process.platform,
  touchbarUpdate: (data) => ipcRenderer.send('touchbar-update', data),
  discord: {
    connect:   (clientId) => ipcRenderer.send('discord-rpc-connect', clientId),
    update:    (activity) => ipcRenderer.send('discord-rpc-update', activity),
    clear:     ()         => ipcRenderer.send('discord-rpc-clear'),
    onStatus:  (cb)       => ipcRenderer.on('discord-rpc-status', (_e, connected) => cb(connected)),
  },
  nowPlayingUpdate: (data) => ipcRenderer.send('now-playing-update', data),
  kugouGetLyrics: (opts) => ipcRenderer.invoke('kugou-lyrics', opts),
  lyricsEditor: {
    open: (data) => ipcRenderer.send('open-lyrics-editor', data),
  },
})
