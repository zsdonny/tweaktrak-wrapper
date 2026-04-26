# tweaktrak-wrapper

Cross-platform wrapper build system for packaging [https://tweaktrak.ibiza.dev/](https://tweaktrak.ibiza.dev/) as offline desktop executables.

## Platform architecture

- **Windows**: Tauri v2 + WebView2/Chromium
- **macOS**: Electron + bundled Chromium
- **Linux**: Electron + bundled Chromium

The application icon is the 🎹 musical-keyboard glyph (U+1F3B9) from
[Noto Emoji](https://github.com/googlefonts/noto-emoji), Apache 2.0. See
[`NOTICE`](NOTICE) for full attribution.

## Key behavior

- The TweakTrak web app is **never committed** to this repository.
- CI mirrors the site at build time into `site/`.
- Cached fetches are keyed by remote `ETag` + `Last-Modified` signature.
- Integrity checks run on every build (including cache hits):
  - size bounds
  - expected TweakTrak signature strings/DOM markers
  - baseline hash drift detection
  - malware-pattern scanning
  - external-domain allowlist enforcement
- **Hard-gated delta scans** run whenever the site differs from the committed
  baseline (see "Delta protection" below).
- Hash drift raises an issue and blocks release gating until the baseline is
  refreshed via the `update-baseline.yml` workflow (which is itself gated on
  the same delta scans).

## Runtime hardening

The shipped wrapper enforces an offline, allowlist-only execution model so
that even if a malicious page change slipped past every CI gate it would be
unable to reach the network or escape the wrapper window.

- **Tauri (Windows)** — strict `Content-Security-Policy` declared in
  `src-tauri/tauri.conf.json` (`default-src 'none'`, no remote `script-src`,
  no `connect-src` other than IPC).
- **Electron (macOS / Linux)** — `electron/main.js`:
  - `session.webRequest.onBeforeRequest` cancels every request whose URL is
    not `file://`, `data:` or `blob:` — a hard network kill-switch.
  - `session.webRequest.onHeadersReceived` strips any inbound CSP and injects
    the same strict policy as Tauri.
  - `setWindowOpenHandler` / `will-navigate` deny new windows and
    cross-origin navigation; HTTP(S) links are forwarded to the OS browser.
  - `setPermissionRequestHandler` denies all permission prompts (geolocation,
    notifications, etc.).

## Runtime smoke gates (G)

Two runtime smoke checks act as **hard gates**, exercising the actual
wrapper binaries against the freshly mirrored `site/`. Both upload a JSON
report + screenshot/log artifact so failures are debuggable from the
Actions UI alone.

### `smoke-electron` (Linux + Chromium)

`scripts/smoke-electron.sh` boots the real `electron/main.js` inside
`xvfb` and asserts the SPA mounts under the wrapper's offline + CSP
constraints. Fails the gate when any of:

- the wrapper failed to load `index.html`;
- the network kill-switch dropped any `http(s)` / `ws(s)` request (i.e.
  the mirrored site references an external asset the wrapper hard-blocks
  at runtime — e.g. a CDN font, third-party analytics);
- the renderer logged a CSP violation, an unhandled `TypeError`,
  `ReferenceError`, `SyntaxError`, or any console message at level
  `error`;
- the SPA root never gained meaningful DOM content (default threshold:
  ≥ 50 descendants under `#root` / `#app` / `body`).

### `smoke-tauri-windows` (Windows + WebView2)

`scripts/smoke-tauri.ps1` builds the Tauri wrapper with the `smoke`
cargo feature and launches the resulting exe under WebView2 on
`windows-latest`. The smoke build injects a JS bootstrap on
`page-load-started` that hooks `console.error` / `console.warn`,
`window.onerror`, `window.onunhandledrejection`, and
`securitypolicyviolation` events, then runs the same DOM probe as the
Electron smoke and posts the captured report back through a Tauri IPC
command (`__tweaktrak_smoke_report`) which writes JSON to disk and
exits the app. Pass criteria match the Electron smoke (DOM mount + no
fatal console + no runtime errors).

The `smoke` feature is gated behind a cargo flag, so release binaries
do **not** include the probe code — only the smoke CI build does.

**Limitation:** the Tauri bootstrap is injected on
`page-load-started`, slightly later than Chromium's native
`console-message` event. Errors that fire during the very first HTML
parse may be missed by the Tauri smoke; the Electron smoke catches
that earlier window via the native event and remains the canonical CSP
gate. The Tauri smoke is supplementary coverage so a WebView2-only
regression (IPC bridge breakage, WebView2-specific behaviour, etc.)
cannot ship silently.

### Gating

- **PR runs:** the `pr-gate` job aggregates both smoke jobs and acts as
  a single required-status-check anchor for branch protection. A failed
  smoke on a PR blocks the merge.
- **Push / scheduled / dispatch runs:** both smoke jobs are
  prerequisites of `release-gate` and `release-publish`; a failing
  smoke blocks the release entirely.

### Local smoke run

```bash
# Electron (Linux / macOS)
(cd electron && npm install)
./scripts/smoke-electron.sh site

# Tauri (Windows, PowerShell)
cargo build --features smoke --manifest-path src-tauri/Cargo.toml
./scripts/smoke-tauri.ps1 -ExePath src-tauri/target/debug/tweaktrak-wrapper.exe -SiteDir site
```

### Diagnostic env vars

Honoured by both `electron/main.js` and the smoke-feature build of
`src-tauri` (no effect when the relevant trigger — `TWEAKTRAK_SMOKE=1`
or the `smoke` feature — is absent, so shipped binaries are
unaffected):

| Variable | Effect |
|---|---|
| `TWEAKTRAK_SMOKE=1` | Boots non-interactively, captures blocked URLs (Electron) + console messages + a DOM probe, and exits. |
| `TWEAKTRAK_SMOKE_REPORT=<path>` | Writes the JSON capture to `<path>`. |
| `TWEAKTRAK_SMOKE_SCREENSHOT=<path>` | Electron only: writes a PNG screenshot of the renderer to `<path>`. |
| `TWEAKTRAK_SMOKE_WAIT_MS=<int>` | How long to wait after `did-finish-load` / page-load-started before probing (default 8000). |
| `TWEAKTRAK_SMOKE_HARD_TIMEOUT_MS=<int>` | Outer bound after which the run aborts and writes a partial report (default 60000). |

## Delta protection (E + F + D′)

A "delta" is any difference between the freshly mirrored site and the
SHA-256 baseline committed in `.github/site-baseline.json`. When a delta is
detected the build pipeline runs `scripts/scan-delta.sh`, which is a
**hard gate** composed of:

1. **size sanity** — same bounds as `verify-site.sh`.
2. **retire.js** — scans the bundled JS for known-vulnerable components;
   any finding at `medium` severity or higher fails the gate.
3. **VirusTotal** — for `index.html` and the main JS file:
   `GET /files/{sha256}` → on cache miss, `POST /files` then poll
   `/analyses/{id}` until `completed` (default 5 min). Fails closed if
   `VT_API_KEY` is unset, if the analysis times out, on 3 consecutive API
   errors, or if any verdict exceeds the configured malicious / suspicious
   thresholds.

If any of those checks fails, **no binary is built and no release is
published**; an issue is opened on the repository with the full scan report
attached as a workflow artifact.

The same script also gates the auto-commit step in
`update-baseline.yml`: the baseline can only be refreshed when the new
snapshot passes all three checks. A failure aborts the commit and opens a
tracking issue.

### Required secret

| Secret | Purpose |
|---|---|
| `VT_API_KEY` | Public VirusTotal v3 API key. The delta scan fails closed when missing. |

## Release publishing (C + policy B)

`release-publish` in `build.yml` attaches the bare executables (no zip
wrapping) to a GitHub Release whenever there is a **wrapper-or-site delta**:

- `tauri/**` changed, **or**
- `electron/**` changed, **or**
- `.github/site-baseline.json` was updated (i.e. the upstream site
  changed and was approved by the gated `update-baseline.yml` workflow).

Releases are tagged with CalVer `vYYYY.M.D[.N]` (the trailing `.N` increments
on same-day re-releases) and ship three single-file deliverables:

| Platform | File |
|---|---|
| Windows x64 | `TweakTrak-windows-x64.exe` (Tauri) |
| macOS | `TweakTrak-<version>.dmg` (Electron) |
| Linux x86_64 | `TweakTrak-<version>.AppImage` (Electron) |

A `SHA256SUMS.txt` file is attached alongside, and every binary carries a
SLSA build-provenance attestation produced by
[`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance)
(`gh attestation verify <file> --repo zsdonny/tweaktrak-wrapper`).

The release body contains: reason for the release, per-asset size + SHA-256,
the bundled site hashes, scan-gate results and a link to the workflow run.

## Workflows

### `.github/workflows/build.yml`

Triggers:
- push to `main`
- pull requests to `main` (build-only, no publish, no provenance)
- `workflow_dispatch`
- daily schedule (`0 3 * * *`)

Pipeline stages:
1. detect wrapper / workflow / baseline changes; compute remote site signature
2. fetch / cache / verify site snapshot (with `scan-delta.sh` hard gate on drift)
3. runtime smoke gates — `smoke-electron` (Linux + Chromium) and
   `smoke-tauri-windows` (Windows + WebView2) — both boot the wrapper
   binaries headlessly and assert the SPA mounts under offline + CSP
   constraints
4. PR runs: `pr-gate` aggregates the smoke jobs as a single required check
5. package desktop binaries (Windows / macOS / Linux)
6. attach provenance attestations
7. enforce release gate
8. publish to GitHub Releases on wrapper-or-site delta

### `.github/workflows/update-baseline.yml`

Manual workflow that refreshes `.github/site-baseline.json` from a fresh site
mirror, but only after the new snapshot passes the same `scan-delta.sh`
hard gate. A scan failure aborts the commit and opens an issue.

### Action pinning

Every third-party Action is pinned to a 40-character commit SHA with the
human-readable version as a trailing comment, and every job declares an
explicit minimum-privilege `permissions:` block.

## Local usage

### Fetch mirror

```bash
./scripts/fetch-site.sh
```

After mirroring, `fetch-site.sh` walks `index.html` for absolute external
`<script src="https://…">` and `<link rel="stylesheet" href="https://…">`
references, downloads the body of each, and **inlines it directly** into
`index.html` — the `<script src="…"></script>` element is replaced with
`<script>…body…</script>` (and likewise `<link rel="stylesheet">` becomes
`<style>…body…</style>`), with a leading
`/* tweaktrak: inlined from <URL> */` marker comment so upstream changes
show up in PR diffs. This keeps the wrapper fully offline at runtime —
required because both wrappers hard-block all `http(s)` traffic via the
network kill-switch and forbid remote origins via CSP — while preserving
`site/` as a single self-contained `index.html` (no `vendor/` directory).
The inlined content is covered by the existing `index_html_sha256`
baseline check, so any upstream change to a vendored library still trips
hash drift through the normal flow.

> **Note on Alpine.js & `'unsafe-eval'`:** the upstream SPA uses
> Alpine.js, which evaluates `x-data` / `x-show` / etc. via `Function()`
> and therefore requires `'unsafe-eval'` in `script-src`. Both wrappers
> grant `'unsafe-eval'` for that reason. The network kill-switch +
> `default-src 'none'` still hard-block any attempt to load remote code,
> so this only enables in-page eval of already-shipped local script
> content.

Windows (local dev only — CI uses `fetch-site.sh`):

```bat
scripts\\fetch-site.bat
```

### Run integrity checks

```bash
./scripts/verify-site.sh site .github/site-baseline.json .github/allowed-domains.txt
```

### Run delta scans (requires `VT_API_KEY`)

```bash
VT_API_KEY=xxxx ./scripts/scan-delta.sh site
```

## Licensing

Wrapper/build automation code is released under the **Unlicense**.
The upstream TweakTrak web application is not redistributed from this repository.
The bundled icon glyph is from Noto Emoji (Apache 2.0); see [`NOTICE`](NOTICE).
