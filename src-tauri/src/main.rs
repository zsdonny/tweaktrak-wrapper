#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(feature = "smoke")]
mod smoke {
    use std::env;
    use std::fs;
    use std::path::{Path, PathBuf};

    const BOOTSTRAP: &str = include_str!("smoke_bootstrap.js");

    #[tauri::command]
    pub fn __tweaktrak_smoke_report(app: tauri::AppHandle, payload_json: String) {
        if let Ok(path) = env::var("TWEAKTRAK_SMOKE_REPORT") {
            let p = PathBuf::from(&path);
            if let Some(parent) = p.parent() {
                if !parent.as_os_str().is_empty() {
                    let _ = fs::create_dir_all(parent);
                }
            }
            let _ = fs::write(&p, payload_json.as_bytes());
        }
        // Give the OS a brief moment to flush the file before exiting.
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(100));
            app.exit(0);
        });
    }

    pub fn build_bootstrap_script() -> String {
        let wait_ms = env::var("TWEAKTRAK_SMOKE_WAIT_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(8000);
        let hard_ms = env::var("TWEAKTRAK_SMOKE_HARD_TIMEOUT_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(60000);
        format!(
            "window.__TWEAKTRAK_SMOKE_WAIT_MS={};window.__TWEAKTRAK_SMOKE_HARD_TIMEOUT_MS={};\n{}",
            wait_ms, hard_ms, BOOTSTRAP
        )
    }

    pub fn is_enabled() -> bool {
        env::var("TWEAKTRAK_SMOKE").ok().as_deref() == Some("1")
    }

    pub fn write_failure_marker(reason: &str) {
        if let Ok(path) = env::var("TWEAKTRAK_SMOKE_REPORT") {
            let p = Path::new(&path);
            if let Some(parent) = p.parent() {
                if !parent.as_os_str().is_empty() {
                    let _ = fs::create_dir_all(parent);
                }
            }
            let body = format!(
                "{{\"finishedAt\":\"{}\",\"exitReason\":\"{}\",\"runtimeErrors\":[{{\"kind\":\"host\",\"message\":\"{}\"}}],\"consoleMessages\":[],\"domProbe\":null}}",
                placeholder_timestamp(),
                reason,
                reason
            );
            let _ = fs::write(p, body);
        }
    }

    fn placeholder_timestamp() -> String {
        // Avoid pulling in chrono just for a failure-marker. The CI
        // driver only inspects exitReason and runtimeErrors, not this
        // field, so a literal placeholder is acceptable here.
        String::from("unknown")
    }
}

fn main() {
    #[cfg(feature = "smoke")]
    {
        if smoke::is_enabled() {
            run_smoke();
            return;
        }
    }
    run_normal();
}

fn run_normal() {
    #[allow(unused_mut)]
    let mut builder = tauri::Builder::default();

    // On Android, inject the Web MIDI API shim on every page load so the
    // bundled TweakTrak app can reach USB-MIDI and BLE-MIDI devices via
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

#[cfg(feature = "smoke")]
fn run_smoke() {
    let bootstrap = smoke::build_bootstrap_script();
    let result = tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![smoke::__tweaktrak_smoke_report])
        .on_page_load(move |webview, payload| {
            if matches!(payload.event(), tauri::webview::PageLoadEvent::Started) {
                let _ = webview.eval(&bootstrap);
            }
        })
        .run(tauri::generate_context!());
    if let Err(err) = result {
        smoke::write_failure_marker(&format!("tauri-run-error: {}", err));
        std::process::exit(1);
    }
}
