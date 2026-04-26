const { app, BrowserWindow } = require('electron');
const path = require('path');
const fs = require('fs');

app.commandLine.appendSwitch('enable-web-midi');

function resolveIndexPath() {
  const siteDir = app.isPackaged
    ? path.join(process.resourcesPath, 'site')
    : path.resolve(__dirname, '..', 'site');

  const indexPath = path.join(siteDir, 'index.html');
  if (!fs.existsSync(indexPath)) {
    throw new Error(`Missing site content at ${indexPath}`);
  }
  return indexPath;
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 800,
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      sandbox: true
    }
  });

  win.loadFile(resolveIndexPath());
}

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});
