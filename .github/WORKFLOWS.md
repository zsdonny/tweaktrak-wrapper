# CI / CD Workflows

This document describes how the two GitHub Actions workflows in this repository work.

---

## `build.yml` — build, verify, smoke-test, and release

### Triggers

| Event | When it fires |
|---|---|
| `push` to `main` | Every merge |
| `pull_request` targeting `main` | Every PR open / update |
| `workflow_dispatch` | Manual run from the Actions tab |
| `schedule` (`0 3 * * *`) | Daily at 03:00 UTC — catches upstream site changes even when no code changed |

Concurrent runs on the same ref cancel each other (`concurrency: cancel-in-progress: true`).

---

### Job pipeline

```
check-changes ──┬── fetch-site ──┬── smoke-electron ──────┬── pr-gate (PRs only)
                │                ├── smoke-tauri-windows ──┤
                │                ├── build-tauri-windows ──┤
                │                ├── build-electron-macos ─┤── release-gate ── release-publish
                │                └── build-electron-linux ─┘
```

---

### `check-changes`

Runs on `ubuntu-latest`. Two things happen here:

1. **Path filtering** — uses `dorny/paths-filter` to set boolean outputs for whether `src-tauri/`, `electron/`, `.github/workflows/`, or `.github/site-baseline.json` changed. Downstream build jobs use these flags to skip rebuilds when nothing relevant was touched.

2. **Remote site signature** — fetches the HTTP headers of `https://tweaktrak.ibiza.dev/` and hashes the `ETag` + `Last-Modified` values together. This hash is included in the `fetch-site` cache key so a CDN-level change to the live site invalidates the cached mirror even when the fetch script itself hasn't changed.

---

### `fetch-site`

Runs on `ubuntu-latest`. This is the security and integrity hub for the whole pipeline.

1. **Cache check** — looks up a cache keyed on the fetch script hash + remote site signature. A cache hit means the site hasn't changed since the last successful run and the mirror is reused, skipping the actual download.

2. **Mirror** — on a cache miss, `scripts/fetch-site.sh` uses `wget` to produce a self-contained offline copy of the site under `site/`. External CDN scripts and stylesheets are inlined into `index.html` so the wrapper can serve everything from `file://` with no outbound requests.

3. **Integrity check** — `scripts/verify-site.sh` compares the SHA-256 of `index.html` and the main JS bundle against the committed baseline in `.github/site-baseline.json`. Outputs `hash_changed=true` if they differ.

4. **Delta security scan** (hard gate, only when `hash_changed == true`) — `scripts/scan-delta.sh` submits the changed files to VirusTotal and runs `retire.js` against the bundle. Either tool reporting a detection fails the workflow immediately — no binary is built or published until a human reviews the finding. The poll deadline is 600 s to allow VT's full engine set to finish.

5. **Issue creation** — if the baseline hash drifted, an issue is automatically opened containing the hash diff and the full scan report, prompting a review before the baseline is refreshed.

6. **Artifact upload** — the mirrored `site/` directory is uploaded as the `mirrored-site` artifact so all downstream build and smoke jobs share exactly the same snapshot.

---

### `smoke-electron`

Runs on `ubuntu-latest` with `xvfb`. Downloads the `mirrored-site` artifact, starts the real `electron/main.js` under a virtual display, and asserts:

- The SPA root (`#root`) gains real DOM content (i.e. the app actually mounted).
- No CSP violations appear in the renderer console.
- No fatal JS errors are logged.

This job is the canonical CSP gate for macOS and Linux builds because both ship the Electron (Chromium) wrapper. A failure here blocks both the PR gate and the release gate.

---

### `smoke-tauri-windows`

Runs on `windows-latest`. Builds a debug Tauri binary with the `smoke` Cargo feature enabled. That feature injects `src-tauri/src/smoke_bootstrap.js` at page-load time to capture console output and runtime errors and report them back over Tauri IPC. `scripts/smoke-tauri.ps1` then asserts the same pass criteria as the Electron smoke.

This job is supplementary coverage: the Electron smoke is the stronger gate (Chromium fires console events earlier than the bootstrap injection point), but this job catches WebView2-specific regressions that Electron wouldn't surface.

---

### `build-tauri-windows` / `build-electron-macos` / `build-electron-linux`

Each runs on its own runner (`windows-latest` / `macos-latest` / `ubuntu-latest`). All three:

1. Download the shared `mirrored-site` artifact.
2. Build the release binary (`tweaktrak-wrapper.exe`, `.dmg`, or `.AppImage`).
3. Upload the binary as a named artifact — **skipped on PRs** to avoid producing release-quality binaries from unreviewed code.

A build job is **skipped entirely** (its `if:` condition evaluates false) when none of the relevant source directories changed and the site cache was hit, i.e. nothing that would affect the binary is different from the last run.

---

### `pr-gate`

Runs only on pull requests. Requires `fetch-site`, `smoke-electron`, and `smoke-tauri-windows` to all be `success`. This is the single required-status check used for branch protection — one anchor instead of three separate required checks.

---

### `release-gate`

Runs on every non-PR event. Requires all five upstream jobs to pass and additionally blocks the release if `hash_changed == true` (baseline drift means a human must review and refresh before anything ships).

---

### `release-publish`

Runs only when `release-gate` passes **and** at least one of the three source areas actually changed (`tauri_changed`, `electron_changed`, or `baseline_changed`). This prevents a no-op daily cron run from cutting a duplicate release.

Steps:

1. **Stage assets** — copies the three platform binaries into `release-assets/` with consistent names (`TweakTrak-windows-x64.exe`, etc.) and generates `SHA256SUMS.txt`.
2. **CalVer tag** — computes a tag in the format `vYYYY.M.D`, bumping to `vYYYY.M.D.1`, `.2`, etc. if a tag for today already exists.
3. **Release notes** — generates a markdown release body with a download table, SHA-256 checksums, and platform notes.
4. **Publish** — creates a public GitHub Release with all four files attached.

---

## `update-baseline.yml` — refresh the site hash baseline

### Trigger

`workflow_dispatch` only — run manually from the Actions tab. There is no automatic trigger.

### When to run it

Run this workflow after reviewing a site-hash-drift issue and confirming that the upstream TweakTrak site changed legitimately (a planned update, not a supply-chain compromise).

### What it does

1. Fetches a fresh mirror of the site (same `fetch-site.sh` logic as `build.yml`).
2. Runs the full delta security scan (VT + retire.js, same hard gate). If the scan fails, the workflow stops and opens a tracking issue — the baseline is **not** updated.
3. On a clean scan, computes the new SHA-256 hashes and writes them to `.github/site-baseline.json`.
4. Auto-commits and pushes the updated baseline under the `github-actions[bot]` identity.

After this workflow succeeds, the next `build.yml` run will see `hash_changed == false` and the release pipeline will proceed normally.

---

## Secrets and permissions

| Secret | Used by | Purpose |
|---|---|---|
| `VT_API_KEY` | `fetch-site`, `update-baseline` | Authenticate to the VirusTotal API for delta scans |
| `GITHUB_TOKEN` | `release-publish`, `update-baseline`, issue creation | Built-in token; write access is only requested by jobs that need it |

All jobs default to `permissions: contents: read`. Individual jobs request additional permissions (`contents: write`, `issues: write`, `pull-requests: read`) only where necessary.
