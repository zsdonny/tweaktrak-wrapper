// Injected into the Tauri webview at page-load-started time when the
// `smoke` cargo feature is built. Captures console errors / warnings,
// uncaught JS errors, unhandled promise rejections, and runs a DOM probe
// after a configurable settle delay. Posts the captured report back via
// the `__tweaktrak_smoke_report` Tauri command, which writes the JSON to
// disk and exits the app. Has no effect when the smoke feature is not
// compiled in (the bootstrap is simply never injected).
(function () {
  if (window.__tweaktrakSmokeInstalled) return;
  window.__tweaktrakSmokeInstalled = true;

  var record = {
    startedAt: new Date().toISOString(),
    finishedAt: null,
    href: location.href,
    consoleMessages: [],
    runtimeErrors: [],
    domProbe: null
  };

  function capture(level, args) {
    try {
      record.consoleMessages.push({
        level: level,
        message: Array.prototype.slice.call(args).map(function (a) {
          if (a && a.stack) return String(a.stack);
          if (typeof a === 'object') {
            try { return JSON.stringify(a); } catch (_) { return String(a); }
          }
          return String(a);
        }).join(' ')
      });
    } catch (_e) { /* best-effort capture */ }
  }

  var origError = console.error;
  var origWarn = console.warn;
  console.error = function () { capture('error', arguments); return origError.apply(console, arguments); };
  console.warn = function () { capture('warn', arguments); return origWarn.apply(console, arguments); };

  window.addEventListener('error', function (ev) {
    record.runtimeErrors.push({
      kind: 'error',
      message: String(ev.message || ''),
      source: String(ev.filename || ''),
      line: ev.lineno || 0,
      stack: ev.error && ev.error.stack ? String(ev.error.stack) : ''
    });
  }, true);

  window.addEventListener('unhandledrejection', function (ev) {
    var reason = ev.reason;
    record.runtimeErrors.push({
      kind: 'unhandledrejection',
      message: reason && reason.message ? String(reason.message) : String(reason),
      stack: reason && reason.stack ? String(reason.stack) : ''
    });
  }, true);

  // CSP violations are reported here in addition to console.error in
  // some webviews; capture them explicitly.
  document.addEventListener('securitypolicyviolation', function (ev) {
    record.runtimeErrors.push({
      kind: 'csp-violation',
      message: 'CSP violation: ' + ev.violatedDirective + ' blocked ' + ev.blockedURI,
      directive: String(ev.violatedDirective || ''),
      blockedURI: String(ev.blockedURI || ''),
      source: String(ev.sourceFile || '')
    });
  }, true);

  function probe() {
    var root = document.getElementById('root') || document.getElementById('app') || document.body;
    var all = root ? root.querySelectorAll('*') : [];
    var text = (document.body && document.body.innerText) || '';
    record.domProbe = {
      url: location.href,
      title: document.title,
      hasRoot: !!root,
      rootId: root ? root.id : null,
      descendantCount: all.length,
      bodyTextLength: text.length,
      bodyTextSample: text.slice(0, 1024)
    };
  }

  function send(reason) {
    if (record.finishedAt) return;
    record.finishedAt = new Date().toISOString();
    record.exitReason = reason;
    var ipc = window.__TAURI_INTERNALS__;
    var payload = JSON.stringify(record);
    try {
      if (ipc && typeof ipc.invoke === 'function') {
        ipc.invoke('__tweaktrak_smoke_report', { payloadJson: payload });
      } else if (window.__TAURI__ && window.__TAURI__.core && typeof window.__TAURI__.core.invoke === 'function') {
        window.__TAURI__.core.invoke('__tweaktrak_smoke_report', { payloadJson: payload });
      } else {
        // No IPC available — at least surface the report in the console
        // so the host process can scrape it from the captured log.
        console.log('__TWEAKTRAK_SMOKE_REPORT__' + payload);
      }
    } catch (e) {
      console.log('__TWEAKTRAK_SMOKE_REPORT__' + payload);
    }
  }

  var waitMs = Number(window.__TWEAKTRAK_SMOKE_WAIT_MS || 8000);
  var hardMs = Number(window.__TWEAKTRAK_SMOKE_HARD_TIMEOUT_MS || 60000);

  setTimeout(function () { try { probe(); } catch (_) {} send('ok'); }, waitMs);
  setTimeout(function () { send('hard-timeout'); }, hardMs);
})();
