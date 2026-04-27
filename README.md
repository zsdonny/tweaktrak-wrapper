# TweakTrak Desktop & Mobile

TweakTrak as a standalone app for **Windows, macOS, Linux, and Android** — the
same TweakTrak you'd use at [tweaktrak.ibiza.dev](https://tweaktrak.ibiza.dev/),
but in its own window (or its own Android app), fully offline, with no browser
tabs and no network chatter.

## Download

Grab the latest installer for your platform from the
[Releases page](https://github.com/zsdonny/tweaktrak-wrapper/releases/latest):

| Platform | File | Notes |
|---|---|---|
| Windows 10/11 (x64) | `TweakTrak-windows-x64.exe` | Double-click to launch — no installer wizard. |
| macOS — Tauri (recommended) | `TweakTrak-<version>-tauri-macos.dmg` | Open the disk image and drag TweakTrak to **Applications**. Full MIDI + SysEx. |
| macOS — Electron (legacy) | `TweakTrak-<version>-electron-macos.dmg` | Same experience, larger download. Will be retired next release. |
| Linux — Tauri (recommended) | `TweakTrak-<version>-tauri-linux.AppImage` | `chmod +x` then run. Full MIDI + SysEx via ALSA. |
| Linux — Electron (legacy) | `TweakTrak-<version>-electron-linux.AppImage` | Same experience, larger download. Will be retired next release. |
| Android 7.0+ (most phones, arm64-v8a) | `TweakTrak-android-arm64-v8a.apk` | Sideload — see [Android notes](#android) below. |
| Android 7.0+ (older 32-bit ARM) | `TweakTrak-android-armeabi-v7a.apk` | Sideload only for older 32-bit phones/tablets. |

Each release also ships a `SHA256SUMS.txt` file so you can verify the download:

```bash
sha256sum -c SHA256SUMS.txt
```

## What you get

- **A real desktop window.** TweakTrak runs in its own window with its own icon
  in your dock / taskbar / app switcher — no browser, no tabs, no address bar.
- **Works offline.** The web app is bundled inside the download, so it keeps
  working on a plane, in a coffee shop with flaky Wi-Fi, or on an air-gapped
  machine. There is nothing to log into and nothing to install separately.
- **No tracking, no telemetry, no network calls.** The app is locked down so it
  cannot reach the internet at runtime — not for analytics, not for fonts, not
  for updates. If you click an external link, it opens in your normal browser
  instead.
- **Same TweakTrak you already know.** The interface and features are exactly
  what's on the website at the time the version was built.

## Updating

TweakTrak Desktop does not auto-update. To get the latest version, download
the newest release from the
[Releases page](https://github.com/zsdonny/tweaktrak-wrapper/releases/latest)
and replace your existing copy. New releases are cut whenever the upstream
TweakTrak site changes (or whenever the desktop wrapper itself is improved).

## Platform notes

- **Windows** uses the system WebView2 runtime (already present on Windows 11,
  and on most up-to-date Windows 10 installs). No extra download is required.
- **macOS** binaries are not notarized. The first time you launch the app you
  may need to right-click → **Open** and confirm the Gatekeeper prompt, or
  allow it under **System Settings → Privacy & Security**.
- **Linux** AppImages run on most modern distributions without installation.
  You may need `libfuse2` on some systems for AppImage support.
  The Tauri AppImage links against ALSA (`libasound`) which is present on all
  major distributions by default.
- <a name="android"></a>**Android** APKs are not distributed via Google Play —
  sideloading is required:
  1. On your phone, go to **Settings → Apps → Special app access → Install
     unknown apps** and enable it for your browser or file manager.
  2. Download the `arm64-v8a` APK directly to your phone. Use `armeabi-v7a`
     only for older 32-bit ARM devices; `x86` / `x86_64` builds are mainly for
     emulators and ChromeOS.
  3. Tap the downloaded file to install.
  - Minimum Android 7.0 (API 24).
  - **USB-MIDI** requires a USB OTG (On-The-Go) adapter. Connect the adapter
    to your phone, plug in your MIDI device, and the app will see it
    automatically via `navigator.requestMIDIAccess()`.
  - **BLE-MIDI** devices: power on the device in Bluetooth-MIDI pairing or
    advertising mode, then open TweakTrak and allow the Bluetooth permission
    prompt. Standard BLE-MIDI devices, including devices that expose Yamaha's
    Bluetooth MIDI transmission/reception, should appear in the MIDI list.

## MIDI notes

TweakTrak uses [Web MIDI](https://developer.mozilla.org/en-US/docs/Web/API/Web_MIDI_API)
to communicate with your hardware synth.

- **Windows:** Web MIDI is provided natively by the WebView2 (Edge/Chromium) runtime.
- **macOS (Tauri build):** Web MIDI is provided by a native polyfill backed by
  CoreMIDI. MIDI input/output and SysEx are all supported.
- **Linux (Tauri build):** Web MIDI is provided by a native polyfill backed by
  ALSA sequencer. MIDI input/output and SysEx are all supported.
- **macOS / Linux (Electron builds):** Web MIDI is provided by Chromium's
  built-in implementation (same as the Tauri polyfill in capability).

**SysEx policy:** SysEx access is granted silently — no browser-style permission
prompt is shown. TweakTrak uses SysEx to read and write synth parameters;
silently allowing it matches the behaviour you would get running TweakTrak in
a Chromium-based browser with Web MIDI enabled.

## Reporting issues

Found a bug, a layout glitch, or something that works on the website but not
in the desktop app? Please
[open an issue](https://github.com/zsdonny/tweaktrak-wrapper/issues/new) and
include your OS, the version of TweakTrak Desktop you're running, and what you
were doing when it happened.

## Privacy

TweakTrak Desktop does not have an account system, does not phone home, and
does not collect usage data. Anything you do in the app stays in the app's
local storage on your computer.

## Building from source

Most people don't need this — the
[Releases page](https://github.com/zsdonny/tweaktrak-wrapper/releases/latest)
has prebuilt binaries for every platform. If you'd like to build your own
copy or contribute changes, see the workflow files under `.github/workflows/`
for the canonical build recipe, and [`.github/WORKFLOWS.md`](.github/WORKFLOWS.md)
for a plain-English walkthrough of what each job does.

## Credits & licensing

- The desktop wrapper code in this repository is released under the
  [Unlicense](LICENSE) (public domain).
- The TweakTrak web application itself is the work of its upstream authors and
  is bundled into each release for offline use; it is not redistributed in
  source form from this repository.
- The application icon is the 🎹 musical-keyboard glyph (U+1F3B9) from
  [Noto Emoji](https://github.com/googlefonts/noto-emoji), Apache 2.0. See
  [`NOTICE`](NOTICE) for full attribution.
