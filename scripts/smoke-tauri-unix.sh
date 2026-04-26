#!/usr/bin/env bash
# smoke-tauri-unix.sh — runtime smoke gate for the Tauri wrapper on Linux
# and macOS.
#
# Mirrors smoke-tauri.ps1 (which covers Windows) but implemented in bash for
# the unix CI jobs.  Launches the smoke-feature build of the Tauri wrapper with
# TWEAKTRAK_SMOKE=1 and evaluates the JSON report it writes.
#
# Pass criteria:
#   * SPA mounted (>= SMOKE_MIN_DOM_NODES descendants under #root / body)
#   * no fatal console messages matching SMOKE_FATAL_CONSOLE_PATTERNS
#   * no runtime errors (window.onerror, unhandledrejection, CSP violations)
#
# Inputs:
#   $1  Path to the smoke-feature binary (built with `cargo build --features smoke`)
#   $2  Path to the mirrored site/ directory
#
# Optional env vars:
#   SMOKE_OUTPUT_DIR              default: smoke-out-tauri
#   SMOKE_WAIT_MS                 default: 8000
#   SMOKE_HARD_TIMEOUT_MS         default: 60000
#   SMOKE_PROCESS_TIMEOUT_SEC     default: 90
#   SMOKE_MIN_DOM_NODES           default: 50
#   SMOKE_FATAL_CONSOLE_PATTERNS  default: (see below)
#
# Outputs (under $SMOKE_OUTPUT_DIR):
#   smoke-report.json   raw JSON report from the wrapper
#   smoke-summary.md    human-readable gate summary
#
# Exits non-zero on any hard-gate failure.

set -euo pipefail

BIN_PATH="${1:-}"
SITE_DIR="${2:-site}"
SMOKE_OUTPUT_DIR="${SMOKE_OUTPUT_DIR:-smoke-out-tauri}"
SMOKE_WAIT_MS="${SMOKE_WAIT_MS:-8000}"
SMOKE_HARD_TIMEOUT_MS="${SMOKE_HARD_TIMEOUT_MS:-60000}"
SMOKE_PROCESS_TIMEOUT_SEC="${SMOKE_PROCESS_TIMEOUT_SEC:-90}"
SMOKE_MIN_DOM_NODES="${SMOKE_MIN_DOM_NODES:-50}"
SMOKE_FATAL_CONSOLE_PATTERNS="${SMOKE_FATAL_CONSOLE_PATTERNS:-Refused to|Content Security Policy|Uncaught|SyntaxError|TypeError|ReferenceError}"

if [[ -z "$BIN_PATH" ]]; then
  echo "smoke-tauri-unix: usage: $0 <binary-path> [<site-dir>]" >&2
  exit 1
fi
if [[ ! -x "$BIN_PATH" ]]; then
  echo "smoke-tauri-unix: binary not found or not executable: $BIN_PATH" >&2
  exit 1
fi
if [[ ! -f "$SITE_DIR/index.html" ]]; then
  echo "smoke-tauri-unix: missing index.html in $SITE_DIR" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$SMOKE_OUTPUT_DIR"
SMOKE_OUTPUT_DIR_ABS="$(cd "$SMOKE_OUTPUT_DIR" && pwd)"
REPORT_PATH="$SMOKE_OUTPUT_DIR_ABS/smoke-report.json"
SUMMARY_PATH="$SMOKE_OUTPUT_DIR_ABS/smoke-summary.md"
RUN_LOG="$SMOKE_OUTPUT_DIR_ABS/tauri-run.log"
rm -f "$REPORT_PATH" "$SUMMARY_PATH" "$RUN_LOG"

# The Tauri binary resolves frontendDist ("../site" relative to src-tauri/)
# at compile time, so it expects site/ to live at $REPO_ROOT/site at runtime.
# Symlink the supplied site dir there if it is in a different location.
SITE_DIR_ABS="$(cd "$SITE_DIR" && pwd)"
EXPECTED_SITE="$REPO_ROOT/site"
LINK_CREATED=0
if [[ "$SITE_DIR_ABS" != "$EXPECTED_SITE" ]]; then
  if [[ -e "$EXPECTED_SITE" && ! -L "$EXPECTED_SITE" ]]; then
    echo "smoke-tauri-unix: $EXPECTED_SITE exists and is not a symlink; refusing to overwrite." >&2
    exit 1
  fi
  ln -sfn "$SITE_DIR_ABS" "$EXPECTED_SITE"
  LINK_CREATED=1
fi
cleanup() {
  if (( LINK_CREATED == 1 )) && [[ -L "$EXPECTED_SITE" ]]; then
    rm -f "$EXPECTED_SITE"
  fi
}
trap cleanup EXIT

# portable_timeout SEC CMD [ARGS…]
# Uses GNU timeout (Linux), gtimeout (macOS via Homebrew coreutils), or a
# pure-bash watchdog when neither is available.
portable_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=10 "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --signal=TERM --kill-after=10 "$secs" "$@"
  else
    "$@" &
    local child=$!
    ( sleep "$secs"; kill -TERM "$child" 2>/dev/null
      sleep 10;     kill -KILL "$child" 2>/dev/null ) &
    local watcher=$!
    wait "$child"; local rc=$?
    kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null || true
    return "$rc"
  fi
}

# On Linux: use a virtual display (xvfb) so the window can open headlessly.
# On macOS: the runner has a real display; run directly.
LAUNCHER=()
case "$(uname -s)" in
  Linux)
    if [[ -z "${DISPLAY:-}" ]]; then
      if command -v xvfb-run >/dev/null 2>&1; then
        LAUNCHER=(xvfb-run -a --server-args="-screen 0 1280x800x24")
      else
        echo "smoke-tauri-unix: no DISPLAY and xvfb-run not found." >&2
        exit 1
      fi
    fi
    ;;
  Darwin)
    : # macOS GitHub Actions runners have a real display
    ;;
esac

BIN_PATH_ABS="$(cd "$(dirname "$BIN_PATH")" && pwd)/$(basename "$BIN_PATH")"
set +e
TWEAKTRAK_SMOKE=1 \
TWEAKTRAK_SMOKE_REPORT="$REPORT_PATH" \
TWEAKTRAK_SMOKE_WAIT_MS="$SMOKE_WAIT_MS" \
TWEAKTRAK_SMOKE_HARD_TIMEOUT_MS="$SMOKE_HARD_TIMEOUT_MS" \
  portable_timeout "$SMOKE_PROCESS_TIMEOUT_SEC" \
    ${LAUNCHER[@]+"${LAUNCHER[@]}"} "$BIN_PATH_ABS" \
    > "$RUN_LOG" 2>&1
binary_exit=$?
set -e

if [[ ! -f "$REPORT_PATH" ]]; then
  echo "smoke-tauri-unix: report not produced (exit $binary_exit). Last 50 log lines:" >&2
  tail -n 50 "$RUN_LOG" >&2 || true
  exit 1
fi

# Evaluate the JSON report with Python 3 (available on all GitHub runners).
python3 - \
  "$REPORT_PATH" "$SUMMARY_PATH" \
  "$SMOKE_MIN_DOM_NODES" "$SMOKE_FATAL_CONSOLE_PATTERNS" \
  "${GITHUB_STEP_SUMMARY:-}" "${GITHUB_OUTPUT:-}" \
  <<'PY'
import json, re, sys
from pathlib import Path

report_path, summary_path, min_dom_str, fatal_pat, step_summary, gh_output = sys.argv[1:7]
data  = json.loads(Path(report_path).read_text(encoding='utf-8'))
min_dom = int(min_dom_str)

failures = []

probe = data.get('domProbe') or {}
desc  = int(probe.get('descendantCount') or 0)
if desc < min_dom:
    failures.append(
        f'SPA mount probe failed: {desc} descendants (threshold {min_dom})')

console   = data.get('consoleMessages') or []
fatal_re  = re.compile(fatal_pat, re.IGNORECASE) if fatal_pat else None
fatal_con = [m for m in console
             if m.get('level') == 'error' or (fatal_re and fatal_re.search(str(m.get('message', ''))))]
if fatal_con:
    failures.append(f'{len(fatal_con)} fatal console message(s)')

errors = data.get('runtimeErrors') or []
if errors:
    failures.append(f'{len(errors)} runtime error(s)')

lines = ['# Tauri smoke gate (unix)', '']
lines.append(f"- exitReason: `{data.get('exitReason')}`")
lines.append(f"- href: `{probe.get('url', '')}`")
if probe:
    lines.append(
        f"- DOM probe: root=`{probe.get('rootId')}` descendants=`{desc}` "
        f"bodyText=`{probe.get('bodyTextLength')}` chars")
lines.append(f"- console messages: `{len(console)}` (fatal: `{len(fatal_con)}`)")
if fatal_con:
    lines += ['', '<details><summary>Fatal console messages</summary>', '']
    for m in fatal_con[:50]:
        snip = str(m.get('message', ''))[:240].replace('`', "'")
        lines.append(f"- {m.get('level')}: `{snip}`")
    lines.append('</details>')
lines.append(f"- runtime errors: `{len(errors)}`")
if errors:
    lines += ['', '<details><summary>Runtime errors</summary>', '']
    for e in errors[:50]:
        snip = str(e.get('message', ''))[:240].replace('`', "'")
        lines.append(f"- {e.get('kind')}: `{snip}`")
    lines.append('</details>')
lines.append('')
if failures:
    lines.append('**Result: ❌ failed**')
    lines += [''] + [f'- {f}' for f in failures]
else:
    lines.append('**Result: ✅ passed**')

text = '\n'.join(lines) + '\n'
Path(summary_path).write_text(text, encoding='utf-8')
print(text)

if step_summary:
    with open(step_summary, 'a', encoding='utf-8') as f:
        f.write(text)
if gh_output:
    with open(gh_output, 'a', encoding='utf-8') as f:
        f.write(f"smoke_passed={'true' if not failures else 'false'}\n")

if failures:
    sys.exit(1)
PY
