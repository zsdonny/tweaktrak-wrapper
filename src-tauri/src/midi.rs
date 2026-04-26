//! Web MIDI polyfill back-end for macOS and Linux.
//!
//! Compiled only on non-Windows targets; Windows keeps native Web MIDI via
//! WebView2 / Chromium and never touches this module.
//!
//! Exposes six Tauri IPC commands:
//!   `midi_list`         — enumerate all available input and output ports
//!   `midi_open_input`   — connect to an input; starts forwarding midi-message events
//!   `midi_close_input`  — disconnect from an input
//!   `midi_open_output`  — pre-open an output (send also opens lazily)
//!   `midi_close_output` — close an output
//!   `midi_send`         — send raw MIDI bytes through an open output
//!
//! Tauri events emitted to the webview:
//!   `midi-message`  { id: string, data: number[] }   — incoming MIDI bytes
//!   `midi-state`    { ports: PortInfo[] }            — hot-plug snapshot
//!
//! Hot-plug detection polls every two seconds in a background thread.
//! SysEx is passed through without filtering; the JS polyfill grants it
//! silently (no permission prompt) matching the current Electron behaviour.

use midir::{MidiInput, MidiInputConnection, MidiOutput, MidiOutputConnection};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tauri::{AppHandle, Emitter, State};

// ── Port descriptor ──────────────────────────────────────────────────────────

#[derive(Clone, Serialize, Deserialize)]
pub struct PortInfo {
    pub id:           String,
    pub name:         String,
    pub manufacturer: String,
    #[serde(rename = "type")]
    pub port_type:    String, // "input" | "output"
}

// ── Shared state ─────────────────────────────────────────────────────────────

pub struct MidiState {
    inputs:  HashMap<String, MidiInputConnection<()>>,
    outputs: HashMap<String, MidiOutputConnection>,
}

impl MidiState {
    pub fn new() -> Self {
        Self {
            inputs:  HashMap::new(),
            outputs: HashMap::new(),
        }
    }
}

pub type SharedMidiState = Arc<Mutex<MidiState>>;

pub fn new_state() -> SharedMidiState {
    Arc::new(Mutex::new(MidiState::new()))
}

// ── Internal helpers ─────────────────────────────────────────────────────────

fn list_ports_internal() -> Vec<PortInfo> {
    let mut ports = Vec::new();

    if let Ok(mi) = MidiInput::new("tweaktrak-enum") {
        for p in mi.ports() {
            if let Ok(name) = mi.port_name(&p) {
                ports.push(PortInfo {
                    id:           name.clone(),
                    name:         name.clone(),
                    manufacturer: String::new(),
                    port_type:    "input".into(),
                });
            }
        }
    }

    if let Ok(mo) = MidiOutput::new("tweaktrak-enum") {
        for p in mo.ports() {
            if let Ok(name) = mo.port_name(&p) {
                ports.push(PortInfo {
                    id:           name.clone(),
                    name:         name.clone(),
                    manufacturer: String::new(),
                    port_type:    "output".into(),
                });
            }
        }
    }

    ports
}

fn open_output_by_id(id: &str) -> Result<MidiOutputConnection, String> {
    let mo = MidiOutput::new("tweaktrak-out").map_err(|e| e.to_string())?;
    let ports = mo.ports();
    let port = ports
        .iter()
        .find(|p| mo.port_name(p).ok().as_deref() == Some(id))
        .ok_or_else(|| format!("MIDI output not found: {id}"))?;
    mo.connect(port, "tweaktrak-send").map_err(|e| e.to_string())
}

// ── Event payload structs ────────────────────────────────────────────────────

#[derive(Serialize)]
struct MidiMessagePayload<'a> {
    id:   &'a str,
    data: &'a [u8],
}

#[derive(Serialize)]
struct MidiStatePayload {
    ports: Vec<PortInfo>,
}

// ── Tauri commands ───────────────────────────────────────────────────────────

#[tauri::command]
pub fn midi_list() -> Vec<PortInfo> {
    list_ports_internal()
}

#[tauri::command]
pub fn midi_open_input(
    app:   AppHandle,
    state: State<'_, SharedMidiState>,
    id:    String,
) -> Result<(), String> {
    let mut st = state.lock().map_err(|e| e.to_string())?;
    if st.inputs.contains_key(&id) {
        return Ok(());
    }

    let mi = MidiInput::new("tweaktrak-in").map_err(|e| e.to_string())?;
    let ports = mi.ports();
    let port = ports
        .iter()
        .find(|p| mi.port_name(p).ok().as_deref() == Some(id.as_str()))
        .ok_or_else(|| format!("MIDI input not found: {id}"))?;

    let app_c = app.clone();
    let id_c  = id.clone();
    let conn  = mi
        .connect(
            port,
            "tweaktrak-recv",
            move |_ts, data, _| {
                let _ = app_c.emit(
                    "midi-message",
                    MidiMessagePayload { id: &id_c, data },
                );
            },
            (),
        )
        .map_err(|e| e.to_string())?;

    st.inputs.insert(id, conn);
    Ok(())
}

#[tauri::command]
pub fn midi_close_input(
    state: State<'_, SharedMidiState>,
    id:    String,
) -> Result<(), String> {
    let mut st = state.lock().map_err(|e| e.to_string())?;
    st.inputs.remove(&id); // dropping the connection closes the port
    Ok(())
}

#[tauri::command]
pub fn midi_open_output(
    state: State<'_, SharedMidiState>,
    id:    String,
) -> Result<(), String> {
    let mut st = state.lock().map_err(|e| e.to_string())?;
    if st.outputs.contains_key(&id) {
        return Ok(());
    }
    let conn = open_output_by_id(&id)?;
    st.outputs.insert(id, conn);
    Ok(())
}

#[tauri::command]
pub fn midi_close_output(
    state: State<'_, SharedMidiState>,
    id:    String,
) -> Result<(), String> {
    let mut st = state.lock().map_err(|e| e.to_string())?;
    st.outputs.remove(&id);
    Ok(())
}

#[tauri::command]
pub fn midi_send(
    state: State<'_, SharedMidiState>,
    id:    String,
    data:  Vec<u8>,
) -> Result<(), String> {
    let mut st = state.lock().map_err(|e| e.to_string())?;

    // Open the output lazily on first send (TweakTrak calls send() without
    // calling open() first).
    if !st.outputs.contains_key(&id) {
        let conn = open_output_by_id(&id)?;
        st.outputs.insert(id.clone(), conn);
    }

    st.outputs
        .get_mut(&id)
        .expect("just inserted")
        .send(&data)
        .map_err(|e| e.to_string())
}

// ── Hot-plug watcher ─────────────────────────────────────────────────────────

/// Starts a background thread that polls the MIDI port list every 2 s and
/// emits a `midi-state` event to the webview whenever the list changes.
/// The 2 s latency is acceptable for device connect/disconnect on a desktop
/// synth editor and avoids platform-specific notification APIs.
pub fn start_hotplug_watcher(app: AppHandle) {
    std::thread::spawn(move || {
        let mut last: Vec<String> = Vec::new();
        loop {
            std::thread::sleep(Duration::from_secs(2));
            let ports = list_ports_internal();
            let snap: Vec<String> = ports
                .iter()
                .map(|p| format!("{}-{}", p.port_type, p.id))
                .collect();
            if snap != last {
                last = snap;
                let _ = app.emit("midi-state", MidiStatePayload { ports });
            }
        }
    });
}
