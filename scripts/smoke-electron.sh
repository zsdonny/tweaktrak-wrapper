#!/usr/bin/env bash
# smoke-electron.sh — runtime smoke gate for the Electron wrapper.
#
# Launches the real electron/main.js against a mirrored site/ directory in a
# headless display, then evaluates the JSON report it writes. Fails the gate
# when any of the following are true:
#
#   * the wrapper failed to load index.html
#   * the renderer dropped any http(s)/ws(s) request via the kill-switch
#     (i.e. the mirror references an external asset the wrapper hard-blocks
#     at runtime — this is the failure mode that produced the empty-knobs
#     screenshot)
#   * the renderer logged a CSP violation or a JS error
#   * the SPA did not actually mount (DOM probe shows a near-empty root)
#
# Inputs:
#   $1  Site directory (default: site)
#
# Outputs (under $SMOKE_OUTPUT_DIR, default ./smoke-out):
#   smoke-report.json   raw report from the wrapper
#   smoke-screenshot.png  capture taken after SMOKE_WAIT_MS
#   smoke-summary.md    human-readable summary
#
# Exits non-zero on any hard-gate failure.

set -euo pipefail

SITE_DIR="${1:-site}"
SMOKE_OUTPUT_DIR="${SMOKE_OUTPUT_DIR:-smoke-out}"
SMOKE_WAIT_MS="${SMOKE_WAIT_MS:-8000}"
SMOKE_HARD_TIMEOUT_MS="${SMOKE_HARD_TIMEOUT_MS:-60000}"
# Generous outer bound on the whole electron run (probe wait + screenshot +
# graceful shutdown + safety margin).
SMOKE_PROCESS_TIMEOUT_SEC="${SMOKE_PROCESS_TIMEOUT_SEC:-90}"
# Minimum descendant element count required under the SPA root for the gate
# to consider the app "mounted". The TweakTrak SPA renders well over this
# even on the bare landing screen.
SMOKE_MIN_DOM_NODES="${SMOKE_MIN_DOM_NODES:-50}"
# Console error patterns that must not appear in the renderer log.
SMOKE_FATAL_CONSOLE_PATTERNS="${SMOKE_FATAL_CONSOLE_PATTERNS:-Refused to|Content Security Policy|Uncaught|SyntaxError|TypeError|ReferenceError}"

if [[ ! -d "$SITE_DIR" ]]; then
  echo "smoke-electron: missing site directory: $SITE_DIR" >&2
  exit 1
fi
if [[ ! -f "$SITE_DIR/index.html" ]]; then
  echo "smoke-electron: missing index.html in $SITE_DIR" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$SMOKE_OUTPUT_DIR"
SMOKE_OUTPUT_DIR_ABS="$(cd "$SMOKE_OUTPUT_DIR" && pwd)"
REPORT_PATH="$SMOKE_OUTPUT_DIR_ABS/smoke-report.json"
SCREENSHOT_PATH="$SMOKE_OUTPUT_DIR_ABS/smoke-screenshot.png"
SUMMARY_PATH="$SMOKE_OUTPUT_DIR_ABS/smoke-summary.md"
RUN_LOG="$SMOKE_OUTPUT_DIR_ABS/electron-run.log"
rm -f "$REPORT_PATH" "$SCREENSHOT_PATH" "$SUMMARY_PATH" "$RUN_LOG"

# Resolve the site dir to an absolute path so the wrapper can find it
# regardless of cwd. The wrapper itself defaults to ../site relative to the
# electron/ folder when not packaged; we override by symlinking site/ into
# the expected location only when needed.
SITE_DIR_ABS="$(cd "$SITE_DIR" && pwd)"
EXPECTED_SITE_DIR="$REPO_ROOT/site"
LINK_CREATED=0
if [[ "$SITE_DIR_ABS" != "$EXPECTED_SITE_DIR" ]]; then
  if [[ -e "$EXPECTED_SITE_DIR" && ! -L "$EXPECTED_SITE_DIR" ]]; then
    echo "smoke-electron: $EXPECTED_SITE_DIR exists and is not a symlink; refusing to overwrite." >&2
    exit 1
  fi
  ln -sfn "$SITE_DIR_ABS" "$EXPECTED_SITE_DIR"
  LINK_CREATED=1
fi
cleanup_link() {
  if (( LINK_CREATED == 1 )) && [[ -L "$EXPECTED_SITE_DIR" ]]; then
    rm -f "$EXPECTED_SITE_DIR"
  fi
}
trap cleanup_link EXIT

cd "$REPO_ROOT/electron"

# Pick a launcher that can supply a virtual display when no $DISPLAY exists.
LAUNCHER=()
if [[ -n "${DISPLAY:-}" ]]; then
  :
elif command -v xvfb-run >/dev/null 2>&1; then
  LAUNCHER=(xvfb-run -a --server-args="-screen 0 1280x800x24")
else
  echo "smoke-electron: no DISPLAY and xvfb-run not available." >&2
  exit 1
fi

# Resolve the local electron binary installed by `npm install`.
ELECTRON_BIN="./node_modules/.bin/electron"
if [[ ! -x "$ELECTRON_BIN" ]]; then
  echo "smoke-electron: $ELECTRON_BIN not found. Run 'npm install' in electron/ first." >&2
  exit 1
fi

# --no-sandbox: GitHub-hosted Linux runners run as root and lack the
# user-namespace setup electron's chrome-sandbox needs; this is fine for the
# smoke test (we are intentionally launching electron in a CI sandbox).
ELECTRON_ARGS=(. --no-sandbox)

# Send TERM first so the inner finalizeSmoke() handler still has a moment
# to flush its JSON report; escalate to KILL only after a 10s grace period.
set +e
TWEAKTRAK_SMOKE=1 \
TWEAKTRAK_SMOKE_REPORT="$REPORT_PATH" \
TWEAKTRAK_SMOKE_SCREENSHOT="$SCREENSHOT_PATH" \
TWEAKTRAK_SMOKE_WAIT_MS="$SMOKE_WAIT_MS" \
TWEAKTRAK_SMOKE_HARD_TIMEOUT_MS="$SMOKE_HARD_TIMEOUT_MS" \
ELECTRON_DISABLE_SECURITY_WARNINGS=1 \
  timeout --signal=TERM --kill-after=10 "$SMOKE_PROCESS_TIMEOUT_SEC" \
    "${LAUNCHER[@]}" "$ELECTRON_BIN" "${ELECTRON_ARGS[@]}" \
    > "$RUN_LOG" 2>&1
electron_exit=$?
set -e

if [[ ! -f "$REPORT_PATH" ]]; then
  echo "smoke-electron: report not produced (electron exited $electron_exit). Last 50 log lines:" >&2
  tail -n 50 "$RUN_LOG" >&2 || true
  exit 1
fi

# Evaluate the report.
python3 - "$REPORT_PATH" "$SUMMARY_PATH" "$SMOKE_MIN_DOM_NODES" "$SMOKE_FATAL_CONSOLE_PATTERNS" <<'PY'
import json
import re
import sys
from pathlib import Path

report_path, summary_path, min_dom_nodes, fatal_patterns = sys.argv[1:5]
data = json.loads(Path(report_path).read_text(encoding="utf-8"))

failures = []
warnings = []

if not data.get("loadOk"):
    failures.append("renderer never reached did-finish-load")

probe = data.get("domProbe") or {}
descendants = int(probe.get("descendantCount") or 0)
if descendants < int(min_dom_nodes):
    failures.append(
        f"SPA mount probe failed: only {descendants} descendants under root "
        f"(threshold {min_dom_nodes})"
    )

blocked = data.get("blockedRequests") or []
external_blocked = [
    b for b in blocked
    if str(b.get("url", "")).split(":", 1)[0].lower() in {"http", "https", "ws", "wss"}
]
if external_blocked:
    sample = ", ".join(sorted({b["url"] for b in external_blocked})[:5])
    failures.append(
        f"{len(external_blocked)} external request(s) dropped by the wrapper "
        f"kill-switch — the mirrored site references assets the wrapper "
        f"hard-blocks at runtime. Examples: {sample}"
    )

console = data.get("consoleMessages") or []
fatal_re = re.compile(fatal_patterns, re.IGNORECASE) if fatal_patterns else None
fatal_console = []
for m in console:
    text = str(m.get("message", ""))
    level = m.get("level")
    is_error = level == 3 or (fatal_re and fatal_re.search(text))
    if is_error:
        fatal_console.append(m)
if fatal_console:
    failures.append(f"{len(fatal_console)} fatal console message(s)")

errors = data.get("errors") or []
for e in errors:
    failures.append(f"runtime error: {e}")

# Render summary regardless of pass/fail.
lines = ["# Electron smoke gate", ""]
lines.append(f"- exitReason: `{data.get('exitReason')}`")
lines.append(f"- electron: `{data.get('appVersion')}`")
lines.append(f"- loadOk: `{data.get('loadOk')}`")
if probe:
    lines.append(
        f"- DOM probe: root=`{probe.get('rootId')}` "
        f"descendants=`{descendants}` bodyText=`{probe.get('bodyTextLength')}` chars"
    )
lines.append(f"- blocked requests (any): `{len(blocked)}`")
lines.append(f"- blocked requests (external): `{len(external_blocked)}`")
if external_blocked:
    lines.append("")
    lines.append("<details><summary>External blocked URLs</summary>")
    lines.append("")
    for b in external_blocked[:50]:
        lines.append(f"- `{b['url']}` ({b.get('resourceType')})")
    if len(external_blocked) > 50:
        lines.append(f"- … and {len(external_blocked) - 50} more")
    lines.append("</details>")
lines.append(f"- console messages: `{len(console)}` (fatal: `{len(fatal_console)}`)")
if fatal_console:
    lines.append("")
    lines.append("<details><summary>Fatal console messages</summary>")
    lines.append("")
    for m in fatal_console[:50]:
        snippet = str(m.get("message", "")).replace("`", "'")[:240]
        lines.append(f"- L{m.get('level')} {m.get('source')}: `{snippet}`")
    lines.append("</details>")
lines.append("")
if failures:
    lines.append("**Result: ❌ failed**")
    lines.append("")
    for f in failures:
        lines.append(f"- {f}")
else:
    lines.append("**Result: ✅ passed**")

Path(summary_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines))

if failures:
    sys.exit(1)
PY

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "smoke_passed=true" >> "$GITHUB_OUTPUT"
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$SUMMARY_PATH" >> "$GITHUB_STEP_SUMMARY"
fi

echo "smoke-electron: passed (report at $REPORT_PATH)"
