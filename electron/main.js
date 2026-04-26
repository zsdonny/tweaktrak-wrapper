const { app, BrowserWindow, session, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const { URL } = require('url');

app.commandLine.appendSwitch('enable-web-midi');

// --- Smoke / diagnostic mode -------------------------------------------------
//
// When TWEAKTRAK_SMOKE=1 is set, the wrapper runs as a non-interactive probe:
//
//   * Every URL dropped by the network kill-switch is recorded.
//   * Every console message (including CSP violations the renderer reports
//     via console.error) is recorded.
//   * After TWEAKTRAK_SMOKE_WAIT_MS (default 8000ms) following did-finish-load,
//     the renderer is queried for a small DOM probe and a PNG screenshot is
//     captured.
//   * A JSON report is written to TWEAKTRAK_SMOKE_REPORT and the app exits.
//
// This mode has zero effect when the env var is unset, so it cannot affect
// shipped binaries — it is only used by the smoke-test release gate.
const SMOKE_MODE = process.env.TWEAKTRAK_SMOKE === '1';
const SMOKE_REPORT_PATH = process.env.TWEAKTRAK_SMOKE_REPORT || '';
const SMOKE_SCREENSHOT_PATH = process.env.TWEAKTRAK_SMOKE_SCREENSHOT || '';
const SMOKE_WAIT_MS = (() => {
  const raw = Number(process.env.TWEAKTRAK_SMOKE_WAIT_MS || '8000');
  return Number.isFinite(raw) && raw >= 0 ? raw : 8000;
})();
const SMOKE_HARD_TIMEOUT_MS = (() => {
  const raw = Number(process.env.TWEAKTRAK_SMOKE_HARD_TIMEOUT_MS || '60000');
  return Number.isFinite(raw) && raw >= 0 ? raw : 60000;
})();
const smokeRecord = {
  startedAt: new Date().toISOString(),
  finishedAt: null,
  appVersion: process.versions.electron,
  loadOk: false,
  domProbe: null,
  blockedRequests: [],
  consoleMessages: [],
  errors: []
};

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
  // self + 'unsafe-inline' for those, but no remote origins. The audio
  // engine instantiates a WebAssembly module at startup, which requires
  // 'wasm-unsafe-eval' under CSP3 — without it the main mixer view fails
  // to mount even though static dialogs (e.g. Effects) still render.
  // 'unsafe-eval' is required by Alpine.js (which the upstream loads from
  // a CDN that fetch-site.sh localizes into vendor/) to evaluate
  // `x-data` / `x-show` / etc. directives via `Function()`. The wrapper's
  // network kill-switch + CSP `default-src 'none'` still hard-block any
  // attempt to load remote code, so this only enables in-page eval of
  // already-shipped local script content.
  "script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'",
  "script-src-attr 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "style-src-attr 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self' data:",
  "media-src 'self' blob:",
  // The SPA fetches some of its own bundled resources at runtime via XHR/
  // fetch, so connect-src has to permit same-origin (file://) and data:/
  // blob: URIs. Egress to the public network is still hard-blocked by the
  // webRequest.onBeforeRequest filter below, which only ever lets file:,
  // data: and blob: requests through regardless of what CSP allows.
  "connect-src 'self' data: blob:",
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
    if (SMOKE_MODE) {
      // Record the drop so the smoke gate can fail when the mirrored site
      // references an external asset that the wrapper hard-blocks at runtime.
      smokeRecord.blockedRequests.push({
        url: details.url,
        resourceType: details.resourceType || 'unknown',
        method: details.method || 'GET'
      });
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
    show: !SMOKE_MODE,
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

  if (SMOKE_MODE) {
    attachSmokeProbe(win);
  }

  win.loadFile(resolveIndexPath());
  return win;
}

// --- Smoke-mode helpers ------------------------------------------------------
// All of the following are only invoked when SMOKE_MODE is true.

function attachSmokeProbe(win) {
  const wc = win.webContents;

  wc.on('console-message', (_event, level, message, line, sourceId) => {
    smokeRecord.consoleMessages.push({
      // Electron levels: 0=verbose, 1=info, 2=warning, 3=error.
      level,
      message: String(message || ''),
      source: sourceId ? `${sourceId}:${line}` : ''
    });
  });

  wc.on('render-process-gone', (_event, details) => {
    smokeRecord.errors.push(`render-process-gone: ${details && details.reason}`);
    finalizeSmoke(win, 'render-process-gone');
  });

  wc.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
    smokeRecord.errors.push(
      `did-fail-load: ${errorCode} ${errorDescription} (${validatedURL})`
    );
  });

  wc.on('did-finish-load', () => {
    smokeRecord.loadOk = true;
    setTimeout(() => {
      runSmokeProbe(win).catch((err) => {
        smokeRecord.errors.push(`probe-error: ${err && err.message}`);
        finalizeSmoke(win, 'probe-error');
      });
    }, SMOKE_WAIT_MS);
  });
}

async function runSmokeProbe(win) {
  const wc = win.webContents;

  // Small in-renderer probe. Kept self-contained (no closures over outer
  // scope) because it runs in an isolated renderer context.
  const probeSource = `(() => {
    const root = document.getElementById('root') || document.getElementById('app') || document.body;
    const all = root ? root.querySelectorAll('*') : [];
    const text = (document.body && document.body.innerText) || '';
    return {
      url: location.href,
      title: document.title,
      hasRoot: !!root,
      rootId: root ? root.id : null,
      descendantCount: all.length,
      bodyTextLength: text.length,
      bodyTextSample: text.slice(0, 1024)
    };
  })()`;

  try {
    smokeRecord.domProbe = await wc.executeJavaScript(probeSource, true);
  } catch (err) {
    smokeRecord.errors.push(`executeJavaScript-failed: ${err && err.message}`);
  }

  if (SMOKE_SCREENSHOT_PATH) {
    try {
      const image = await wc.capturePage();
      fs.mkdirSync(path.dirname(SMOKE_SCREENSHOT_PATH), { recursive: true });
      fs.writeFileSync(SMOKE_SCREENSHOT_PATH, image.toPNG());
    } catch (err) {
      smokeRecord.errors.push(`screenshot-failed: ${err && err.message}`);
    }
  }

  finalizeSmoke(win, 'ok');
}

function armSmokeHardTimeout(win) {
  // .unref() so a stalled/early-completed run doesn't keep the event loop
  // alive on this timer alone — finalizeSmoke()'s own app.exit() is the
  // primary shutdown path; this timer is only a safety net.
  setTimeout(() => {
    if (smokeRecord.finishedAt) return;
    smokeRecord.errors.push(`hard-timeout after ${SMOKE_HARD_TIMEOUT_MS}ms`);
    finalizeSmoke(win, 'hard-timeout');
  }, SMOKE_HARD_TIMEOUT_MS).unref();
}

function finalizeSmoke(win, reason) {
  if (smokeRecord.finishedAt) return;
  smokeRecord.finishedAt = new Date().toISOString();
  smokeRecord.exitReason = reason;
  if (SMOKE_REPORT_PATH) {
    try {
      fs.mkdirSync(path.dirname(SMOKE_REPORT_PATH), { recursive: true });
      fs.writeFileSync(SMOKE_REPORT_PATH, JSON.stringify(smokeRecord, null, 2));
    } catch (err) {
      // Last-resort log; the smoke driver script will detect a missing report.
      console.error(`[smoke] failed to write report: ${err && err.message}`);
    }
  }
  try {
    if (win && !win.isDestroyed()) {
      win.destroy();
    }
  } catch (_err) {
    // ignore
  }
  app.exit(0);
}

app.whenReady().then(() => {
  applyHardening(session.defaultSession);
  const win = createWindow();

  if (SMOKE_MODE) {
    armSmokeHardTimeout(win);
  }

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
