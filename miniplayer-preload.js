const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('miniPlayer', {
  onState: (cb)     => ipcRenderer.on('miniplayer-state', (_e, state) => cb(state)),
  control: (action) => ipcRenderer.send('miniplayer-control', action),
  restore: ()       => ipcRenderer.send('miniplayer-restore'),
  // macOS gets real traffic lights instead of an in-page close button, and the
  // drag strip has to start clear of them - miniplayer.html keys both off this.
  platform: process.platform,
})
