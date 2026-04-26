#!/usr/bin/env bash
set -euo pipefail

SITE_URL="${SITE_URL:-https://tweaktrak.ibiza.dev/}"
SITE_DIR="${1:-site}"
TMP_DIR="${SITE_DIR}.tmp"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
mkdir -p "$SITE_DIR"

fetch_with_lftp() {
  lftp -e "set ssl:verify-certificate yes; mirror --parallel=8 --verbose / ${TMP_DIR}; bye" "$SITE_URL"
}

fetch_with_wget2() {
  wget2 \
    --mirror \
    --adjust-extension \
    --convert-links \
    --page-requisites \
    --no-host-directories \
    --directory-prefix "$TMP_DIR" \
    "$SITE_URL"
}

fetch_with_httrack() {
  httrack "$SITE_URL" -O "$TMP_DIR" "+tweaktrak.ibiza.dev/*" --quiet
}

if command -v lftp >/dev/null 2>&1; then
  fetch_with_lftp
elif command -v wget2 >/dev/null 2>&1; then
  fetch_with_wget2
elif command -v httrack >/dev/null 2>&1; then
  fetch_with_httrack
else
  echo "No mirror tool found. Install one of: lftp, wget2, httrack" >&2
  exit 1
fi

INDEX_PATH="$(find "$TMP_DIR" -type f -name index.html | head -n 1 || true)"
if [[ -z "$INDEX_PATH" ]]; then
  echo "Could not locate index.html in mirrored output" >&2
  exit 1
fi

ROOT_DIR="$(dirname "$INDEX_PATH")"
rsync -a --delete "$ROOT_DIR"/ "$SITE_DIR"/

if [[ ! -f "$SITE_DIR/index.html" ]]; then
  echo "Flattening failed: ${SITE_DIR}/index.html missing" >&2
  exit 1
fi

rm -rf "$TMP_DIR"
echo "Site mirror ready at $SITE_DIR"
