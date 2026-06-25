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
  proxyFetch: (url, method, body, extraHeaders) => ipcRenderer.invoke('proxy-fetch', { url, method, body, extraHeaders }),
  kugouGetLyrics: (opts) => ipcRenderer.invoke('kugou-lyrics', opts),
  lyricsEditor: {
    open: (data) => ipcRenderer.send('open-lyrics-editor', data),
  },
  remote: {
    // Enable / disable the WebSocket server
    enable:    (on)  => ipcRenderer.invoke('remote-control-enable', on),
    status:    ()    => ipcRenderer.invoke('remote-control-status'),
    // Renderer calls this to push state to connected Android clients
    pushState: (state) => ipcRenderer.send('remote-state-update', state),
    // Main asks renderer for state (renderer calls pushState in response)
    onGetState: (cb) => ipcRenderer.on('remote-get-state', () => cb()),
    // Main forwards seek / volume commands from Android
    onSeek:    (cb)  => ipcRenderer.on('remote-seek',   (_e, pos) => cb(pos)),
    onVolume:  (cb)  => ipcRenderer.on('remote-volume', (_e, vol) => cb(vol)),
  },
})
