const { app, BrowserWindow, ipcMain, clipboard, shell, Menu } = require('electron')
const path = require('path')
const Store = require('electron-store')

const store = new Store()

let win

function createWindow() {
  win = new BrowserWindow({
    width: 1100,
    height: 700,
    minWidth: 800,
    minHeight: 500,
    backgroundColor: '#111113',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 12, y: 11 },
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    show: false,
  })

  win.loadFile('index.html')

  win.once('ready-to-show', () => win.show())
}

app.whenReady().then(createWindow)

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow()
})

// IPC: store
ipcMain.handle('store-get', (_e, key) => store.get(key))
ipcMain.handle('store-set', (_e, key, value) => store.set(key, value))
ipcMain.handle('store-delete', (_e, key) => store.delete(key))

// IPC: clipboard
ipcMain.handle('clipboard-write', (_e, text) => clipboard.writeText(text))

// IPC: shell
ipcMain.handle('shell-open', (_e, url) => shell.openExternal(url))

// IPC: download — uses Electron's session download API
ipcMain.handle('download-file', (_e, url, filename) => {
  win.webContents.downloadURL(url)
})

// IPC: native context menu for now-playing
ipcMain.handle('show-np-menu', (_e, actions) => {
  return new Promise((resolve) => {
    const template = actions.map(a => {
      if (a.type === 'separator') return { type: 'separator' }
      return {
        label: a.label,
        enabled: a.enabled !== false,
        ...(a.role ? { role: a.role } : {}),
        click: () => resolve(a.id)
      }
    })
    const menu = Menu.buildFromTemplate(template)
    menu.popup({ window: win, callback: () => resolve(null) })
  })
})
