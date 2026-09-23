const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('metadataEditor', {
  onInit: (cb)     => ipcRenderer.on('metadata-editor-init', (_e, data) => cb(data)),
  close:  ()       => ipcRenderer.send('metadata-editor-close'),
  // Tell the main window a save landed so it can drop its cached copy
  saved:  (itemId) => ipcRenderer.send('metadata-editor-saved', itemId),
  // Minimal read-only access to the same electron-store the main window
  // writes to (main.js's store-get handler), just enough to read the global
  // --font setting on load.
  store: { get: (key) => ipcRenderer.invoke('store-get', key) },
})
