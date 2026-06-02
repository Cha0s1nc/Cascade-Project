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
})
