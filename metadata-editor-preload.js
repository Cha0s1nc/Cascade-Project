const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('metadataEditor', {
  onInit: (cb)     => ipcRenderer.on('metadata-editor-init', (_e, data) => cb(data)),
  close:  ()       => ipcRenderer.send('metadata-editor-close'),
  // Tell the main window a save landed so it can drop its cached copy
  saved:  (itemId) => ipcRenderer.send('metadata-editor-saved', itemId),
  // The global --font setting, read on load. Only this one key: a generic
  // store getter here would hand this window the Jellyfin token too.
  uiFont: () => ipcRenderer.invoke('store-get', 'uiFont'),
})
