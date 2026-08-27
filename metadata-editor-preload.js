const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('metadataEditor', {
  onInit: (cb)     => ipcRenderer.on('metadata-editor-init', (_e, data) => cb(data)),
  close:  ()       => ipcRenderer.send('metadata-editor-close'),
  // Tell the main window a save landed so it can drop its cached copy
  saved:  (itemId) => ipcRenderer.send('metadata-editor-saved', itemId),
})
