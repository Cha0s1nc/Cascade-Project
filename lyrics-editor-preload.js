const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('lyricsEditor', {
  onInit:  (cb)     => ipcRenderer.on('lyrics-editor-init', (_e, data) => cb(data)),
  close:   ()       => ipcRenderer.send('lyrics-editor-close'),
  // Tell the main window a save landed so it can drop its cached copy
  saved:   (itemId) => ipcRenderer.send('lyrics-editor-saved', itemId),
})
