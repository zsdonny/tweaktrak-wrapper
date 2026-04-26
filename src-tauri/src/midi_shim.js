/**
 * Web MIDI API shim for Android (Tauri wrapper).
 *
 * Polyfills navigator.requestMIDIAccess() by delegating to the native
 * MidiPlugin Kotlin plugin via Tauri IPC.
 *
 * Terminology mapping (Android vs Web MIDI):
 *   Android MidiInputPort  (app writes TO device)  ↔  Web MIDIOutput
 *   Android MidiOutputPort (device writes TO app)  ↔  Web MIDIInput
 *
 * Device port types reported by MidiPlugin.listDevices():
 *   port.type === "input"  → device INPUT port → expose as Web MIDIOutput
 *   port.type === "output" → device OUTPUT port → expose as Web MIDIInput
 *
 * Incoming MIDI events are delivered as Tauri events named "midiMessage"
 * with payload: { handle, data: number[], timestamp: number }
 */
(function () {
  'use strict';

  if (typeof window.__TAURI__ === 'undefined') return;
  if (typeof navigator.requestMIDIAccess === 'function') return;

  var invoke = function (cmd, args) {
    return window.__TAURI__.core.invoke('plugin:midi|' + cmd, args || {});
  };

  // ---------------------------------------------------------------------------
  // MIDIOutput — wraps an Android MidiInputPort (send TO device)
  // ---------------------------------------------------------------------------

  function MIDIOutput(deviceId, portIndex, name) {
    this.id = deviceId + ':in:' + portIndex;
    this.name = name;
    this.type = 'output';
    this.state = 'connected';
    this.connection = 'closed';
    this._handle = null;
    this._openPending = null;
  }

  MIDIOutput.prototype._open = function () {
    if (this._handle) return Promise.resolve(this._handle);
    if (this._openPending) return this._openPending;
    var self = this;
    var parts = self.id.split(':'); // [deviceId, "in", portIndex]
    this._openPending = invoke('openInputPort', {
      deviceId: parts[0],
      portIndex: parseInt(parts[2], 10) || 0
    }).then(function (r) {
      self._handle = r.handle;
      self.connection = 'open';
      self._openPending = null;
      return r.handle;
    });
    return this._openPending;
  };

  MIDIOutput.prototype.send = function (data, timestamp) {
    return this._open().then(function (h) {
      return invoke('send', { handle: h, data: Array.from(data) });
    });
  };

  MIDIOutput.prototype.clear = function () { /* no buffering */ };

  MIDIOutput.prototype.close = function () {
    if (!this._handle) return Promise.resolve();
    var h = this._handle;
    this._handle = null;
    this.connection = 'closed';
    return invoke('closePort', { handle: h });
  };

  // ---------------------------------------------------------------------------
  // MIDIInput — wraps an Android MidiOutputPort (receive FROM device)
  // ---------------------------------------------------------------------------

  function MIDIInput(deviceId, portIndex, name) {
    this.id = deviceId + ':out:' + portIndex;
    this.name = name;
    this.type = 'input';
    this.state = 'connected';
    this.connection = 'closed';
    this.onmidimessage = null;
    this._handle = null;
    this._unlisten = null;
  }

  MIDIInput.prototype._open = function () {
    if (this._handle) return Promise.resolve(this._handle);
    var self = this;
    var parts = self.id.split(':'); // [deviceId, "out", portIndex]
    return invoke('openOutputPort', {
      deviceId: parts[0],
      portIndex: parseInt(parts[2], 10) || 0
    }).then(function (r) {
      self._handle = r.handle;
      self.connection = 'open';
      window.__TAURI__.event.listen('midiMessage', function (event) {
        if (event.payload.handle !== self._handle) return;
        if (typeof self.onmidimessage !== 'function') return;
        self.onmidimessage({
          data: new Uint8Array(event.payload.data),
          timeStamp: event.payload.timestamp / 1e6
        });
      }).then(function (fn) { self._unlisten = fn; });
      return r.handle;
    });
  };

  MIDIInput.prototype.close = function () {
    if (!this._handle) return Promise.resolve();
    if (this._unlisten) { this._unlisten(); this._unlisten = null; }
    var h = this._handle;
    this._handle = null;
    this.connection = 'closed';
    return invoke('closePort', { handle: h });
  };

  // ---------------------------------------------------------------------------
  // MIDIAccess
  // ---------------------------------------------------------------------------

  function buildMIDIAccess(rawDevices) {
    var inputs = new Map();
    var outputs = new Map();
    (rawDevices || []).forEach(function (dev) {
      (dev.ports || []).forEach(function (port) {
        var portName = (port.name && port.name.trim()) || dev.name || 'Port ' + port.id;
        if (port.type === 'output') {
          // Device OUTPUT → Web MIDIInput (we receive MIDI)
          var mi = new MIDIInput(dev.id, port.id, portName);
          inputs.set(mi.id, mi);
        } else {
          // Device INPUT → Web MIDIOutput (we send MIDI)
          var mo = new MIDIOutput(dev.id, port.id, portName);
          outputs.set(mo.id, mo);
        }
      });
    });
    return {
      inputs: inputs,
      outputs: outputs,
      sysexEnabled: false,
      onstatechange: null
    };
  }

  // ---------------------------------------------------------------------------
  // Polyfill
  // ---------------------------------------------------------------------------

  navigator.requestMIDIAccess = function (/*options*/) {
    return invoke('listDevices').then(function (result) {
      return buildMIDIAccess(result.devices);
    });
  };

  console.log('[TweakTrak] Web MIDI API shim active (Android)');
})();
