const { app, BrowserWindow, session, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const { URL } = require('url');

app.commandLine.appendSwitch('enable-web-midi');

// --- Strict offline content policy -------------------------------------------
//
// The wrapper bundles a snapshot of https://tweaktrak.ibiza.dev/ that has
// already passed the integrity, malware-pattern, retire.js and (on baseline
// changes) VirusTotal gates run in CI. Once shipped, the wrapper must behave
// as a fully offline app:
//
//   * Only file:// loads are ever issued by the renderer; everything else is
//     dropped in webRequest.onBeforeRequest.
//   * A strict Content-Security-Policy header is injected on every response
//     so even a hypothetical inline script from a tampered mirror cannot
//     reach out to the network or load remote modules.
//   * window.open / target=_blank links are forwarded to the OS browser
//     instead of opening new in-process windows that would inherit the
//     renderer privileges.
//   * Navigation away from the bundled file:// origin is denied.
//
// These three layers together mean a malicious page change that slipped past
// every CI gate would still be unable to fetch remote payloads, exfiltrate
// data, or escape the wrapper window.
const CSP = [
  "default-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
  // The mirrored SPA inlines its scripts and styles into index.html; allow
  // self + 'unsafe-inline' for those, but no remote origins.
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self' data:",
  "media-src 'self' blob:",
  // No connect-src means XHR/fetch/WebSocket are all blocked.
  "connect-src 'none'",
  "object-src 'none'",
  "worker-src 'self' blob:"
].join('; ');

function isAllowedRequestUrl(rawUrl) {
  if (!rawUrl) return false;
  // Devtools and chrome://* internals are required for Electron to function.
  if (rawUrl.startsWith('devtools://') || rawUrl.startsWith('chrome-extension://')) {
    return true;
  }
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch (err) {
    return false;
  }
  // Allow the renderer to load its own bundled assets and inline data URIs.
  return parsed.protocol === 'file:' || parsed.protocol === 'data:' || parsed.protocol === 'blob:';
}

function applyHardening(targetSession) {
  targetSession.webRequest.onBeforeRequest((details, callback) => {
    if (isAllowedRequestUrl(details.url)) {
      callback({ cancel: false });
      return;
    }
    // Drop anything that isn't a local asset. This is the primary network
    // kill-switch — the bundled SPA must never reach the public internet.
    callback({ cancel: true });
  });

  targetSession.webRequest.onHeadersReceived((details, callback) => {
    const responseHeaders = Object.assign({}, details.responseHeaders || {});
    // Strip any CSP that may have been baked into the mirrored index.html so
    // ours is the only one in effect.
    for (const key of Object.keys(responseHeaders)) {
      if (key.toLowerCase() === 'content-security-policy') {
        delete responseHeaders[key];
      }
    }
    responseHeaders['Content-Security-Policy'] = [CSP];
    responseHeaders['X-Content-Type-Options'] = ['nosniff'];
    responseHeaders['Referrer-Policy'] = ['no-referrer'];
    callback({ responseHeaders });
  });

  // Block any permission request (geolocation, notifications, etc.). MIDI is
  // enabled at the command-line level above and does not flow through this API.
  targetSession.setPermissionRequestHandler((_webContents, _permission, completion) => {
    completion(false);
  });
}

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
      sandbox: true,
      nodeIntegration: false,
      webSecurity: true,
      allowRunningInsecureContent: false,
      experimentalFeatures: false
    }
  });

  // Forward window.open / target=_blank to the OS browser instead of letting
  // the renderer spawn a new BrowserWindow with default privileges.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) {
      shell.openExternal(url);
    }
    return { action: 'deny' };
  });

  // Block any navigation that leaves the bundled file:// origin.
  win.webContents.on('will-navigate', (event, targetUrl) => {
    try {
      const target = new URL(targetUrl);
      if (target.protocol !== 'file:') {
        event.preventDefault();
        if (/^https?:$/i.test(target.protocol)) {
          shell.openExternal(targetUrl);
        }
      }
    } catch (_err) {
      event.preventDefault();
    }
  });

  win.loadFile(resolveIndexPath());
}

app.whenReady().then(() => {
  applyHardening(session.defaultSession);
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('web-contents-created', (_event, contents) => {
  // Defensive: if any additional WebContents is ever spawned, refuse to attach
  // a webview to it.
  contents.on('will-attach-webview', (event) => {
    event.preventDefault();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});
