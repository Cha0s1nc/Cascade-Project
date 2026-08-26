const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('miniPlayer', {
  onState: (cb)     => ipcRenderer.on('miniplayer-state', (_e, state) => cb(state)),
  control: (action) => ipcRenderer.send('miniplayer-control', action),
  restore: ()       => ipcRenderer.send('miniplayer-restore'),
})
