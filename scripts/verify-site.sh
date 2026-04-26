#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="${1:-site}"
BASELINE_FILE="${2:-.github/site-baseline.json}"
ALLOWED_DOMAINS_FILE="${3:-.github/allowed-domains.txt}"

if [[ ! -d "$SITE_DIR" ]]; then
  echo "Missing site directory: $SITE_DIR" >&2
  exit 1
fi

if [[ ! -f "$SITE_DIR/index.html" ]]; then
  echo "Missing index.html in $SITE_DIR" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

normalize_js_path() {
  local raw="$1"
  raw="${raw%%\?*}"
  raw="${raw%%#*}"
  raw="${raw#./}"
  raw="${raw#/}"
  printf '%s' "$raw"
}

detect_main_js() {
  local candidate
  while IFS= read -r candidate; do
    candidate="$(normalize_js_path "$candidate")"
    if [[ -n "$candidate" && -f "$SITE_DIR/$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done < <(grep -oE '<script[^>]+src="[^"]+"' "$SITE_DIR/index.html" | sed -E 's/.*src="([^"]+)"/\1/' | grep -Ei '\.js($|\?)' || true)

  find "$SITE_DIR" -type f -name '*.js' -printf '%s %P\n' | sort -nr | head -n 1 | awk '{print $2}'
}

read_baseline_key() {
  local key="$1"
  python3 - "$BASELINE_FILE" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    print(data.get(key, ""))
except Exception:
    print("")
PY
}

size_check() {
  local bytes
  bytes="$(du -sb "$SITE_DIR" | awk '{print $1}')"
  if (( bytes < 500000 )); then
    echo "SIZE check failed: site is too small (${bytes} bytes, expected >= 500000)."
    return 1
  fi
  if (( bytes > 100000000 )); then
    echo "SIZE check failed: site is too large (${bytes} bytes, expected <= 100000000)."
    return 1
  fi
  echo "SIZE check passed (${bytes} bytes)."
}

signature_check() {
  local patterns=("TweakTrak" "SEQTRAK" "id=\"app\"" "id=\"root\"" "data-reactroot")
  local hit=0
  for p in "${patterns[@]}"; do
    if grep -qi "$p" "$SITE_DIR/index.html"; then
      hit=1
      break
    fi
  done

  if (( hit == 0 )); then
    echo "SIGNATURE check failed: expected markers not found in index.html."
    return 1
  fi

  echo "SIGNATURE check passed."
}

hash_check() {
  local main_js
  local index_hash
  local main_hash
  local baseline_index
  local baseline_main
  local baseline_main_path

  main_js="$(detect_main_js || true)"
  if [[ -z "$main_js" || ! -f "$SITE_DIR/$main_js" ]]; then
    echo "HASH check failed: could not resolve main JS file."
    return 1
  fi

  index_hash="$(sha256sum "$SITE_DIR/index.html" | awk '{print $1}')"
  main_hash="$(sha256sum "$SITE_DIR/$main_js" | awk '{print $1}')"

  baseline_index=""
  baseline_main=""
  baseline_main_path=""

  if [[ -f "$BASELINE_FILE" ]]; then
    baseline_index="$(read_baseline_key index_html_sha256)"
    baseline_main="$(read_baseline_key main_js_sha256)"
    baseline_main_path="$(read_baseline_key main_js_path)"
  fi

  local changed=false
  if [[ -z "$baseline_index" || -z "$baseline_main" ]]; then
    changed=true
  elif [[ "$index_hash" != "$baseline_index" || "$main_hash" != "$baseline_main" ]]; then
    changed=true
  fi

  {
    echo "## Baseline hash check"
    echo
    echo "| Item | Baseline | Current |"
    echo "|---|---|---|"
    echo "| index.html | ${baseline_index:-<unset>} | $index_hash |"
    echo "| main JS path | ${baseline_main_path:-<unset>} | $main_js |"
    echo "| main JS hash | ${baseline_main:-<unset>} | $main_hash |"
  } > "$TMP_DIR/hash-summary.md"

  if [[ "$changed" == "true" ]]; then
    echo "true" > "$TMP_DIR/hash_changed"
    echo "HASH check: baseline mismatch detected (non-blocking at this step)."
  else
    echo "false" > "$TMP_DIR/hash_changed"
    echo "HASH check passed (baseline matches)."
  fi
}

malware_check() {
  local scan_file="$TMP_DIR/js-scan.txt"
  : > "$scan_file"

  while IFS= read -r pattern; do
    find "$SITE_DIR" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.html' \) -print0 \
      | xargs -0 grep -Eni "$pattern" >> "$scan_file" || true
  done <<'PATTERNS'
eval\s*\(\s*atob\s*\(
coinhive
cryptonight
fromCharCode\s*\(\s*[0-9]{2,}\s*(,\s*[0-9]{2,}){1,40}\)
WebAssembly\.instantiate\s*\(\s*atob\s*\(
PATTERNS

  if [[ -s "$scan_file" ]]; then
    echo "MALWARE check failed: suspicious patterns found:"
    cat "$scan_file"
    return 1
  fi

  echo "MALWARE check passed."
}

domains_check() {
  if [[ ! -f "$ALLOWED_DOMAINS_FILE" ]]; then
    echo "DOMAINS check failed: missing allowlist file $ALLOWED_DOMAINS_FILE"
    return 1
  fi

  local discovered="$TMP_DIR/discovered-domains.txt"
  local allowed="$TMP_DIR/allowed-domains.txt"
  local unknown="$TMP_DIR/unknown-domains.txt"

  grep -RhoE '(https?:)?//[A-Za-z0-9._:-]+' "$SITE_DIR" \
    | sed -E 's#^(https?:)?//##' \
    | sed -E 's#:[0-9]+$##' \
    | sed -E 's#/.*$##' \
    | tr '[:upper:]' '[:lower:]' \
    | sed '/^$/d' \
    | sort -u > "$discovered"

  grep -Ev '^\s*(#|$)' "$ALLOWED_DOMAINS_FILE" \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u > "$allowed"

  comm -23 "$discovered" "$allowed" > "$unknown" || true

  if [[ -s "$unknown" ]]; then
    echo "DOMAINS check failed: unexpected external domains detected:"
    cat "$unknown"
    return 1
  fi

  echo "DOMAINS check passed."
}

run_check() {
  local name="$1"
  local fn="$2"
  (
    set +e
    "$fn" > "$TMP_DIR/$name.log" 2>&1
    echo "$?" > "$TMP_DIR/$name.status"
  ) &
}

run_check size size_check
run_check signature signature_check
run_check hash hash_check
run_check malware malware_check
run_check domains domains_check
wait

hard_fail=0
for check in size signature malware domains; do
  cat "$TMP_DIR/$check.log"
  if [[ "$(cat "$TMP_DIR/$check.status")" != "0" ]]; then
    hard_fail=1
  fi
done

cat "$TMP_DIR/hash.log"
if [[ -f "$TMP_DIR/hash-summary.md" && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$TMP_DIR/hash-summary.md" >> "$GITHUB_STEP_SUMMARY"
fi

hash_changed="false"
if [[ -f "$TMP_DIR/hash_changed" ]]; then
  hash_changed="$(cat "$TMP_DIR/hash_changed")"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "hash_changed=$hash_changed" >> "$GITHUB_OUTPUT"
  if (( hard_fail == 0 )); then
    echo "integrity_passed=true" >> "$GITHUB_OUTPUT"
  else
    echo "integrity_passed=false" >> "$GITHUB_OUTPUT"
  fi
fi

if [[ "$hash_changed" == "true" ]]; then
  cp "$TMP_DIR/hash-summary.md" site-hash-diff.md
fi

if (( hard_fail != 0 )); then
  echo "Integrity verification failed." >&2
  exit 1
fi
