const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('miniPlayer', {
  onState: (cb)     => ipcRenderer.on('miniplayer-state', (_e, state) => cb(state)),
  control: (action) => ipcRenderer.send('miniplayer-control', action),
  restore: ()       => ipcRenderer.send('miniplayer-restore'),
  // macOS: traffic lights only while the pointer is over the window, the way
  // Apple Music's miniplayer does it, so they do not sit on the cover.
  hover: (on)       => ipcRenderer.send('miniplayer-hover', !!on),
  // macOS gets real traffic lights instead of an in-page close button, and the
  // drag strip has to start clear of them - miniplayer.html keys both off this.
  platform: process.platform,
  // The global --font setting, read on load. Only this one key: a generic
  // store getter here would hand this window the Jellyfin token too.
  uiFont: () => ipcRenderer.invoke('store-get', 'uiFont'),
})
