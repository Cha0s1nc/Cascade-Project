const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('lyricsEditor', {
  onInit:  (cb) => ipcRenderer.on('lyrics-editor-init', (_e, data) => cb(data)),
  close:   ()   => ipcRenderer.send('lyrics-editor-close'),
})
