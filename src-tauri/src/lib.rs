// lib.rs — Android entry point.
// Desktop platforms use main.rs (bin target); Android requires a cdylib/staticlib
// target. Tauri's `tauri_build` + `generate_context!()` work the same in both.

use tauri::{plugin::Builder as PluginBuilder, Runtime};

fn midi_plugin<R: Runtime>() -> tauri::plugin::TauriPlugin<R> {
    PluginBuilder::new("midi")
        .setup(|_app, api| {
            #[cfg(target_os = "android")]
            api.register_android_plugin("dev.ibiza.tweaktrak.wrapper", "MidiPlugin")?;
            Ok(())
        })
        .build()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    #[allow(unused_mut)]
    let mut builder = tauri::Builder::default().plugin(midi_plugin());

    // Inject the Web MIDI API shim on every page load so the bundled
    // TweakTrak app can reach USB-MIDI and BLE-MIDI devices via
    // navigator.requestMIDIAccess() without knowing about the native plugin.
    #[cfg(target_os = "android")]
    {
        builder = builder.on_page_load(|webview, payload| {
            if matches!(payload.event(), tauri::webview::PageLoadEvent::Started) {
                let _ = webview.eval(include_str!("midi_shim.js"));
            }
        });
    }

    builder
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
