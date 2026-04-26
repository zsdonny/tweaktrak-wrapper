#!/usr/bin/env bash
# scan-delta.sh — hard-gated security scans for the mirrored site.
#
# Runs:
#   1. size sanity (re-uses verify-site.sh's bounds via inline check)
#   2. retire.js  — known-vulnerable JS components in the bundle (hard gate)
#   3. VirusTotal — file reputation for index.html + main JS (hard gate)
#
# Inputs:
#   $1  Site directory (default: site)
#
# Environment:
#   VT_API_KEY               Required. Public VT API key.
#   VT_POLL_TIMEOUT_SEC      Per-file analysis timeout (default 300).
#   VT_MAX_CONSECUTIVE_ERR   Abort after N consecutive API errors (default 3).
#   VT_MALICIOUS_MAX         Max allowed malicious verdicts (default 0).
#   VT_SUSPICIOUS_MAX        Max allowed suspicious verdicts (default 3).
#   RETIRE_MIN_SEVERITY      Minimum severity that counts as a failure
#                            (low|medium|high|critical, default medium).
#   SCAN_OUTPUT_DIR          Where to write reports (default ./scan-out).
#
# Exits non-zero on any hard-gate failure. Always writes:
#   $SCAN_OUTPUT_DIR/scan-report.json
#   $SCAN_OUTPUT_DIR/scan-report.md
# and, when running under Actions, emits GITHUB_OUTPUT keys:
#   scan_passed=true|false
#   vt_max_malicious=<int>
#   vt_max_suspicious=<int>
#   retire_findings=<int>

set -euo pipefail

SITE_DIR="${1:-site}"
SCAN_OUTPUT_DIR="${SCAN_OUTPUT_DIR:-scan-out}"
VT_POLL_TIMEOUT_SEC="${VT_POLL_TIMEOUT_SEC:-300}"
VT_MAX_CONSECUTIVE_ERR="${VT_MAX_CONSECUTIVE_ERR:-3}"
VT_MALICIOUS_MAX="${VT_MALICIOUS_MAX:-0}"
VT_SUSPICIOUS_MAX="${VT_SUSPICIOUS_MAX:-3}"
RETIRE_MIN_SEVERITY="${RETIRE_MIN_SEVERITY:-medium}"

mkdir -p "$SCAN_OUTPUT_DIR"
JSON_REPORT="$SCAN_OUTPUT_DIR/scan-report.json"
MD_REPORT="$SCAN_OUTPUT_DIR/scan-report.md"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ ! -d "$SITE_DIR" ]]; then
  echo "scan-delta: missing site directory: $SITE_DIR" >&2
  exit 1
fi
if [[ ! -f "$SITE_DIR/index.html" ]]; then
  echo "scan-delta: missing $SITE_DIR/index.html" >&2
  exit 1
fi

severity_rank() {
  case "${1,,}" in
    critical) echo 4 ;;
    high)     echo 3 ;;
    medium)   echo 2 ;;
    low)      echo 1 ;;
    *)        echo 0 ;;
  esac
}
MIN_SEV_RANK="$(severity_rank "$RETIRE_MIN_SEVERITY")"

# ---- Detect main JS (mirror verify-site.sh logic) ---------------------------
detect_main_js() {
  local candidate
  while IFS= read -r candidate; do
    candidate="${candidate%%\?*}"
    candidate="${candidate%%#*}"
    candidate="${candidate#./}"
    candidate="${candidate#/}"
    if [[ -n "$candidate" && -f "$SITE_DIR/$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(grep -oE '<script[^>]+src="[^"]+"' "$SITE_DIR/index.html" \
            | sed -E 's/.*src="([^"]+)"/\1/' \
            | grep -Ei '\.js($|\?)' || true)
  find "$SITE_DIR" -type f -name '*.js' -printf '%s %P\n' \
    | sort -nr | head -n 1 | awk '{print $2}'
}

MAIN_JS="$(detect_main_js || true)"
INDEX_PATH="$SITE_DIR/index.html"
SCAN_TARGETS=("$INDEX_PATH")
if [[ -n "$MAIN_JS" && -f "$SITE_DIR/$MAIN_JS" && "$SITE_DIR/$MAIN_JS" != "$INDEX_PATH" ]]; then
  SCAN_TARGETS+=("$SITE_DIR/$MAIN_JS")
fi

# ---- Size sanity ------------------------------------------------------------
SIZE_BYTES="$(du -sb "$SITE_DIR" | awk '{print $1}')"
SIZE_OK=true
SIZE_MSG="size ok (${SIZE_BYTES} bytes)"
if (( SIZE_BYTES < 200000 )); then
  SIZE_OK=false
  SIZE_MSG="site too small (${SIZE_BYTES} < 200000 bytes)"
elif (( SIZE_BYTES > 100000000 )); then
  SIZE_OK=false
  SIZE_MSG="site too large (${SIZE_BYTES} > 100000000 bytes)"
fi

# ---- retire.js scan ---------------------------------------------------------
RETIRE_PASS=true
RETIRE_FINDINGS=0
RETIRE_OUT="$TMP_DIR/retire.json"
RETIRE_LOG="$TMP_DIR/retire.log"
RETIRE_REASON=""

if ! command -v npx >/dev/null 2>&1; then
  RETIRE_PASS=false
  RETIRE_REASON="npx not available; cannot run retire.js"
else
  # Use --outputformat jsonsimple so we can parse uniformly. Don't fail the
  # script on retire.js's own non-zero exit (that just signals findings).
  set +e
  npx --yes retire \
      --path "$SITE_DIR" \
      --outputformat jsonsimple \
      --outputpath "$RETIRE_OUT" \
      --severity "$RETIRE_MIN_SEVERITY" \
      > "$RETIRE_LOG" 2>&1
  retire_rc=$?
  set -e
  if [[ ! -s "$RETIRE_OUT" ]]; then
    # Some retire.js versions emit `[]` to stdout instead of the file.
    if grep -qE '^\[' "$RETIRE_LOG"; then
      cp "$RETIRE_LOG" "$RETIRE_OUT"
    else
      echo "[]" > "$RETIRE_OUT"
    fi
  fi
  RETIRE_FINDINGS="$(python3 - "$RETIRE_OUT" "$MIN_SEV_RANK" <<'PY'
import json, sys
path, min_rank = sys.argv[1], int(sys.argv[2])
ranks = {"critical": 4, "high": 3, "medium": 2, "low": 1}
try:
    data = json.load(open(path))
except Exception:
    print(0); sys.exit(0)
count = 0
for entry in data if isinstance(data, list) else []:
    for res in entry.get("results", []):
        for vuln in res.get("vulnerabilities", []):
            sev = (vuln.get("severity") or "").lower()
            if ranks.get(sev, 0) >= min_rank:
                count += 1
print(count)
PY
)"
  if (( RETIRE_FINDINGS > 0 )); then
    RETIRE_PASS=false
    RETIRE_REASON="${RETIRE_FINDINGS} retire.js finding(s) at severity >= ${RETIRE_MIN_SEVERITY}"
  elif (( retire_rc != 0 )) && (( retire_rc != 13 )); then
    # 13 is retire.js's "vulnerabilities found" exit; anything else is a tool error
    RETIRE_PASS=false
    RETIRE_REASON="retire.js exited with status ${retire_rc}; see log"
  fi
fi

# ---- VirusTotal scan --------------------------------------------------------
VT_PASS=true
VT_REASON=""
VT_RESULTS="$TMP_DIR/vt-results.json"
echo "[]" > "$VT_RESULTS"
VT_MAX_MAL=0
VT_MAX_SUS=0

if [[ -z "${VT_API_KEY:-}" ]]; then
  VT_PASS=false
  VT_REASON="VT_API_KEY is not set; failing closed"
else
  consecutive_err=0
  successful_targets=0
  python_results=()
  for target in "${SCAN_TARGETS[@]}"; do
    sha="$(sha256sum "$target" | awk '{print $1}')"
    name="${target#"$SITE_DIR/"}"
    [[ "$target" == "$INDEX_PATH" ]] && name="index.html"

    echo "scan-delta: VT lookup ${name} (${sha})"
    lookup_body="$TMP_DIR/vt-lookup-${sha}.json"
    lookup_code="$(curl -sS -o "$lookup_body" -w '%{http_code}' \
        -H "x-apikey: ${VT_API_KEY}" \
        "https://www.virustotal.com/api/v3/files/${sha}" || echo "000")"

    stats_json=""
    if [[ "$lookup_code" == "200" ]]; then
      stats_json="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d["data"]["attributes"].get("last_analysis_stats",{})))' "$lookup_body" 2>/dev/null || echo "")"
      consecutive_err=0
    elif [[ "$lookup_code" == "404" ]]; then
      consecutive_err=0
      echo "scan-delta: VT cache miss; uploading ${name}"
      upload_body="$TMP_DIR/vt-upload-${sha}.json"
      upload_code="$(curl -sS -o "$upload_body" -w '%{http_code}' \
          -H "x-apikey: ${VT_API_KEY}" \
          -F "file=@${target}" \
          "https://www.virustotal.com/api/v3/files" || echo "000")"
      if [[ "$upload_code" != "200" ]]; then
        VT_PASS=false
        VT_REASON="VT upload of ${name} returned HTTP ${upload_code}"
        break
      fi
      analysis_id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["data"]["id"])' "$upload_body" 2>/dev/null || echo "")"
      if [[ -z "$analysis_id" ]]; then
        VT_PASS=false
        VT_REASON="VT upload of ${name} returned no analysis id"
        break
      fi

      deadline=$(( SECONDS + VT_POLL_TIMEOUT_SEC ))
      poll_status=""
      while (( SECONDS < deadline )); do
        sleep 15
        poll_body="$TMP_DIR/vt-poll-${sha}.json"
        poll_code="$(curl -sS -o "$poll_body" -w '%{http_code}' \
            -H "x-apikey: ${VT_API_KEY}" \
            "https://www.virustotal.com/api/v3/analyses/${analysis_id}" || echo "000")"
        if [[ "$poll_code" != "200" ]]; then
          consecutive_err=$(( consecutive_err + 1 ))
          if (( consecutive_err >= VT_MAX_CONSECUTIVE_ERR )); then
            VT_PASS=false
            VT_REASON="VT poll for ${name} failed ${consecutive_err} times in a row (last HTTP ${poll_code})"
            break 2
          fi
          continue
        fi
        consecutive_err=0
        poll_status="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["data"]["attributes"].get("status",""))' "$poll_body" 2>/dev/null || echo "")"
        if [[ "$poll_status" == "completed" ]]; then
          stats_json="$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["data"]["attributes"].get("stats",{})))' "$poll_body" 2>/dev/null || echo "")"
          break
        fi
      done
      if [[ "$poll_status" != "completed" ]]; then
        VT_PASS=false
        VT_REASON="VT analysis of ${name} did not complete within ${VT_POLL_TIMEOUT_SEC}s"
        break
      fi
    else
      consecutive_err=$(( consecutive_err + 1 ))
      if (( consecutive_err >= VT_MAX_CONSECUTIVE_ERR )); then
        VT_PASS=false
        VT_REASON="VT lookup for ${name} failed ${consecutive_err} times in a row (last HTTP ${lookup_code})"
        break
      fi
      continue
    fi

    if [[ -z "$stats_json" ]]; then
      stats_json='{}'
    fi
    mal="$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(int(d.get("malicious",0)))' "$stats_json" 2>/dev/null || echo 0)"
    sus="$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(int(d.get("suspicious",0)))' "$stats_json" 2>/dev/null || echo 0)"
    (( mal > VT_MAX_MAL )) && VT_MAX_MAL=$mal
    (( sus > VT_MAX_SUS )) && VT_MAX_SUS=$sus

    python_results+=("$(python3 - "$name" "$sha" "$stats_json" <<'PY'
import json, sys
print(json.dumps({
  "name": sys.argv[1],
  "sha256": sys.argv[2],
  "stats": json.loads(sys.argv[3] or "{}"),
}))
PY
)")
    successful_targets=$(( successful_targets + 1 ))
  done
  if [[ "$VT_PASS" == "true" ]]; then
    if (( successful_targets < ${#SCAN_TARGETS[@]} )); then
      VT_PASS=false
      VT_REASON="VT obtained verdicts for only ${successful_targets}/${#SCAN_TARGETS[@]} target(s); failing closed"
    elif (( VT_MAX_MAL > VT_MALICIOUS_MAX )); then
      VT_PASS=false
      VT_REASON="VT malicious=${VT_MAX_MAL} > allowed ${VT_MALICIOUS_MAX}"
    elif (( VT_MAX_SUS > VT_SUSPICIOUS_MAX )); then
      VT_PASS=false
      VT_REASON="VT suspicious=${VT_MAX_SUS} > allowed ${VT_SUSPICIOUS_MAX}"
    fi
  fi
  if (( ${#python_results[@]} > 0 )); then
    printf '%s\n' "${python_results[@]}" | python3 -c 'import json,sys;print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))' > "$VT_RESULTS"
  fi
fi

# ---- Aggregate report -------------------------------------------------------
SCAN_PASS=true
[[ "$SIZE_OK"     == "true" ]] || SCAN_PASS=false
[[ "$RETIRE_PASS" == "true" ]] || SCAN_PASS=false
[[ "$VT_PASS"     == "true" ]] || SCAN_PASS=false

python3 - "$JSON_REPORT" "$MD_REPORT" "$VT_RESULTS" "$RETIRE_OUT" \
  "$SCAN_PASS" "$SIZE_OK" "$SIZE_BYTES" "$SIZE_MSG" \
  "$RETIRE_PASS" "$RETIRE_FINDINGS" "$RETIRE_REASON" "$RETIRE_MIN_SEVERITY" \
  "$VT_PASS" "$VT_REASON" "$VT_MAX_MAL" "$VT_MAX_SUS" \
  "$VT_MALICIOUS_MAX" "$VT_SUSPICIOUS_MAX" <<'PY'
import json, sys, os
(json_path, md_path, vt_results_path, retire_out_path,
 scan_pass, size_ok, size_bytes, size_msg,
 retire_pass, retire_findings, retire_reason, retire_min_sev,
 vt_pass, vt_reason, vt_max_mal, vt_max_sus,
 vt_mal_max, vt_sus_max) = sys.argv[1:]

def load_json(p, default):
    try:
        return json.load(open(p))
    except Exception:
        return default

vt_results = load_json(vt_results_path, [])
retire_data = load_json(retire_out_path, [])

report = {
  "scan_passed": scan_pass == "true",
  "size": {
    "passed": size_ok == "true",
    "bytes": int(size_bytes),
    "message": size_msg,
  },
  "retire_js": {
    "passed": retire_pass == "true",
    "findings_at_min_severity": int(retire_findings),
    "min_severity": retire_min_sev,
    "reason": retire_reason,
    "raw": retire_data,
  },
  "virustotal": {
    "passed": vt_pass == "true",
    "max_malicious": int(vt_max_mal),
    "max_suspicious": int(vt_max_sus),
    "thresholds": {
      "malicious_max": int(vt_mal_max),
      "suspicious_max": int(vt_sus_max),
    },
    "reason": vt_reason,
    "results": vt_results,
  },
}
with open(json_path, "w") as f:
    json.dump(report, f, indent=2, sort_keys=True)

def tick(b): return "✅" if b else "❌"
lines = []
lines.append(f"## Delta scan {'passed' if report['scan_passed'] else 'FAILED'}")
lines.append("")
lines.append(f"- {tick(report['size']['passed'])} **size sanity** — {report['size']['message']}")
rj = report['retire_js']
lines.append(
  f"- {tick(rj['passed'])} **retire.js** — {rj['findings_at_min_severity']} finding(s) "
  f">= {rj['min_severity']}" + (f" ({rj['reason']})" if rj['reason'] else "")
)
vt = report['virustotal']
lines.append(
  f"- {tick(vt['passed'])} **VirusTotal** — malicious={vt['max_malicious']} (max {vt['thresholds']['malicious_max']}), "
  f"suspicious={vt['max_suspicious']} (max {vt['thresholds']['suspicious_max']})"
  + (f" ({vt['reason']})" if vt['reason'] else "")
)
if vt['results']:
    lines.append("")
    lines.append("| File | SHA-256 | malicious | suspicious | undetected | harmless |")
    lines.append("|---|---|---:|---:|---:|---:|")
    for r in vt['results']:
        s = r.get('stats') or {}
        lines.append("| {n} | `{h}` | {m} | {s} | {u} | {ha} |".format(
          n=r['name'], h=r['sha256'],
          m=s.get('malicious',0), s=s.get('suspicious',0),
          u=s.get('undetected',0), ha=s.get('harmless',0)))

with open(md_path, "w") as f:
    f.write("\n".join(lines) + "\n")
PY

cat "$MD_REPORT"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "scan_passed=$SCAN_PASS"
    echo "vt_max_malicious=$VT_MAX_MAL"
    echo "vt_max_suspicious=$VT_MAX_SUS"
    echo "retire_findings=$RETIRE_FINDINGS"
  } >> "$GITHUB_OUTPUT"
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$MD_REPORT" >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$SCAN_PASS" != "true" ]]; then
  echo "scan-delta: hard gate failed (size=$SIZE_OK retire=$RETIRE_PASS vt=$VT_PASS)" >&2
  exit 1
fi
echo "scan-delta: all hard gates passed."
