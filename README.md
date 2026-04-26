# tweaktrak-wrapper

Cross-platform wrapper build system for packaging [https://tweaktrak.ibiza.dev/](https://tweaktrak.ibiza.dev/) as offline desktop executables.

## Platform architecture

- **Windows**: Tauri v2 + WebView2/Chromium
- **macOS**: Electron + bundled Chromium
- **Linux**: Electron + bundled Chromium

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
- Hash drift raises an issue and blocks release gating.

## Workflows

### `.github/workflows/build.yml`

Triggers:
- push to `main`
- `workflow_dispatch`
- daily schedule (`0 3 * * *`)

Pipeline stages:
1. detect wrapper/workflow changes and compute remote site signature
2. fetch/cache/verify site snapshot
3. package desktop binaries:
   - Windows (Tauri)
   - macOS (Electron)
   - Linux (Electron)
4. enforce release gate on integrity/hash status

### `.github/workflows/update-baseline.yml`

Manual workflow that refreshes `.github/site-baseline.json` from a fresh site mirror after passing integrity checks.

## Local usage

### Fetch mirror

```bash
./scripts/fetch-site.sh
```

Windows:

```bat
scripts\\fetch-site.bat
```

### Run integrity checks

```bash
./scripts/verify-site.sh site .github/site-baseline.json .github/allowed-domains.txt
```

## Licensing

Wrapper/build automation code is released under the **Unlicense**.
The upstream TweakTrak web application is not redistributed from this repository.
