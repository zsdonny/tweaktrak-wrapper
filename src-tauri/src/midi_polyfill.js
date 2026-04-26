// Web MIDI API polyfill for Tauri on macOS and Linux.
//
// Injected at page-load-started time (before any page JS runs) by the Tauri
// wrapper's on_page_load hook.  On Windows, WebView2 ships a native Web MIDI
// implementation and navigator.requestMIDIAccess already exists, so this
// script exits immediately without touching anything.
//
// Design:
//   - Backed by Tauri IPC commands in src/midi.rs (midi_list, midi_open_input,
//     midi_close_input, midi_open_output, midi_close_output, midi_send).
//   - Rust emits `midi-message` and `midi-state` Tauri events; the polyfill
//     subscribes using the raw transformCallback + plugin:event|listen IPC so
//     it works without @tauri-apps/api installed in the page.
//   - SysEx is always silently granted (sysexEnabled = true) — matching the
//     current Electron wrapper behaviour; no permission prompt is shown.
//     See the MIDI section of README.md.
//
// API surface (driven by TweakTrak's MIDIService):
//   navigator.requestMIDIAccess(options)  → Promise<MIDIAccess>
//   MIDIAccess.inputs / .outputs          → Map  (forEach + get)
//   MIDIAccess.onstatechange              → property setter (hot-plug)
//   MIDIAccess.sysexEnabled               → boolean (always true)
//   MIDIInput.onmidimessage               → property setter; opens port on assign
//   MIDIInput / MIDIOutput .id .name .manufacturer .type .state .connection
//   MIDIInput / MIDIOutput addEventListener / removeEventListener
//   MIDIOutput.send(data)                 → no-timestamp path
//   MIDIOutput.open() / .close()
(function () {
  'use strict';

  // 1. Feature-detect: bail out if the native API is present (Windows WebView2).
  if (typeof navigator !== 'undefined' &&
      typeof navigator.requestMIDIAccess === 'function') {
    return;
  }

  // 2. Require the Tauri IPC bridge — absent outside the wrapper.
  var _ipc = (typeof window !== 'undefined') && window.__TAURI_INTERNALS__;
  if (!_ipc || typeof _ipc.invoke !== 'function') return;

  // ── IPC helpers ────────────────────────────────────────────────────────────

  function invoke(cmd, args) {
    return _ipc.invoke(cmd, args || {});
  }

  // Subscribe to a named Tauri event emitted from Rust.
  // Uses the raw transformCallback + plugin:event|listen pattern so it works
  // without the @tauri-apps/api package installed in the page.
  function ipcListen(eventName, handler) {
    if (typeof _ipc.transformCallback !== 'function') return;
    var cbId = _ipc.transformCallback(function (ev) {
      try { handler(ev.payload); } catch (_) {}
    });
    _ipc.invoke('plugin:event|listen', {
      event:   eventName,
      target:  { kind: 'Any' },
      handler: cbId
    }).catch(function () {});
  }

  // ── MIDIPort base ──────────────────────────────────────────────────────────

  function MIDIPort(info) {
    this.id           = String(info.id);
    this.name         = String(info.name  || '');
    this.manufacturer = String(info.manufacturer || '');
    this.type         = String(info.type);   // 'input' | 'output'
    this.state        = 'connected';
    this.connection   = 'closed';
    this._listeners   = Object.create(null);
  }

  MIDIPort.prototype.addEventListener = function (type, fn) {
    if (!this._listeners[type]) this._listeners[type] = [];
    if (this._listeners[type].indexOf(fn) < 0) this._listeners[type].push(fn);
  };

  MIDIPort.prototype.removeEventListener = function (type, fn) {
    if (!this._listeners[type]) return;
    this._listeners[type] = this._listeners[type].filter(function (h) {
      return h !== fn;
    });
  };

  MIDIPort.prototype._fire = function (type, event) {
    var hs = this._listeners[type] || [];
    for (var i = 0; i < hs.length; i++) {
      try { hs[i](event); } catch (_) {}
    }
  };

  // ── MIDIInput ──────────────────────────────────────────────────────────────

  function MIDIInput(info) {
    MIDIPort.call(this, info);
    this._onmidimessage = null;
  }
  MIDIInput.prototype = Object.create(MIDIPort.prototype);
  MIDIInput.prototype.constructor = MIDIInput;

  // Assigning onmidimessage opens the Rust MIDI connection for this port;
  // clearing it closes the connection — matching Chromium's native behaviour.
  Object.defineProperty(MIDIInput.prototype, 'onmidimessage', {
    get: function () { return this._onmidimessage; },
    set: function (fn) {
      this._onmidimessage = (typeof fn === 'function') ? fn : null;
      if (this._onmidimessage) {
        invoke('midi_open_input', { id: this.id }).catch(function () {});
      } else {
        invoke('midi_close_input', { id: this.id }).catch(function () {});
      }
    }
  });

  // ── MIDIOutput ─────────────────────────────────────────────────────────────

  function MIDIOutput(info) {
    MIDIPort.call(this, info);
  }
  MIDIOutput.prototype = Object.create(MIDIPort.prototype);
  MIDIOutput.prototype.constructor = MIDIOutput;

  MIDIOutput.prototype.open = function () {
    this.connection = 'open';
    return invoke('midi_open_output', { id: this.id });
  };

  MIDIOutput.prototype.close = function () {
    this.connection = 'closed';
    return invoke('midi_close_output', { id: this.id });
  };

  // TweakTrak calls output.send(array | Uint8Array) with no timestamp arg.
  // The output port is opened lazily on the Rust side if not already open.
  MIDIOutput.prototype.send = function (data) {
    var bytes;
    try { bytes = Array.from(data); } catch (_) { bytes = []; }
    invoke('midi_send', { id: this.id, data: bytes }).catch(function () {});
  };

  // ── MIDIAccess ─────────────────────────────────────────────────────────────

  function MIDIAccess(ports, sysexEnabled) {
    this.sysexEnabled = sysexEnabled;
    this._onstatechange = null;
    this.inputs  = new Map();
    this.outputs = new Map();
    var self = this;
    ports.forEach(function (p) {
      if (p.type === 'input')  self.inputs.set(p.id,  new MIDIInput(p));
      else                     self.outputs.set(p.id, new MIDIOutput(p));
    });
  }

  Object.defineProperty(MIDIAccess.prototype, 'onstatechange', {
    get: function () { return this._onstatechange; },
    set: function (fn) {
      this._onstatechange = (typeof fn === 'function') ? fn : null;
    }
  });

  // Apply a hot-plug snapshot: add new ports, remove disappeared ones,
  // fire onstatechange when the set changes.
  MIDIAccess.prototype._applyPorts = function (newPorts) {
    var self = this;
    var seen = Object.create(null);
    newPorts.forEach(function (p) {
      seen[p.type + ':' + p.id] = true;
      if (p.type === 'input'  && !self.inputs.has(p.id))
        self.inputs.set(p.id,  new MIDIInput(p));
      if (p.type === 'output' && !self.outputs.has(p.id))
        self.outputs.set(p.id, new MIDIOutput(p));
    });
    self.inputs.forEach(function  (_, id) {
      if (!seen['input:'  + id]) self.inputs.delete(id);
    });
    self.outputs.forEach(function (_, id) {
      if (!seen['output:' + id]) self.outputs.delete(id);
    });
    if (typeof self._onstatechange === 'function') {
      try { self._onstatechange({ target: self }); } catch (_) {}
    }
  };

  // Deliver an incoming MIDI message to the correct MIDIInput.
  MIDIAccess.prototype._deliver = function (inputId, data) {
    var input = this.inputs.get(inputId);
    if (!input) return;
    var ev = {
      data:      new Uint8Array(data),
      target:    input,
      timeStamp: (typeof performance !== 'undefined') ? performance.now() : 0
    };
    // Property handler (MIDIService uses `input.onmidimessage = fn`).
    if (typeof input._onmidimessage === 'function') {
      try { input._onmidimessage(ev); } catch (_) {}
    }
    // addEventListener-style listeners.
    input._fire('midimessage', ev);
  };

  // ── navigator.requestMIDIAccess ────────────────────────────────────────────

  Object.defineProperty(navigator, 'requestMIDIAccess', {
    value: function requestMIDIAccess(/* options */) {
      // SysEx is always silently allowed; sysexEnabled is always true so
      // TweakTrak's SysEx code paths all activate without a permission prompt.
      return invoke('midi_list').then(function (ports) {
        var access = new MIDIAccess(ports || [], true);

        // Incoming MIDI bytes forwarded from an open input port.
        ipcListen('midi-message', function (payload) {
          access._deliver(payload.id, payload.data);
        });

        // Hot-plug snapshot — Rust polls and emits when the port list changes.
        ipcListen('midi-state', function (payload) {
          access._applyPorts(payload.ports || []);
        });

        return access;
      });
    },
    writable:     false,
    configurable: false,
    enumerable:   true
  });

}());
