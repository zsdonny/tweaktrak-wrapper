#!/usr/bin/env bash
set -euo pipefail

SITE_URL="${SITE_URL:-https://tweaktrak.ibiza.dev/}"
SITE_DIR="${1:-site}"
TMP_DIR="${SITE_DIR}.tmp"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
mkdir -p "$SITE_DIR"

fetch_with_wget() {
  wget \
    --mirror \
    --adjust-extension \
    --convert-links \
    --page-requisites \
    --no-host-directories \
    --directory-prefix "$TMP_DIR" \
    "$SITE_URL"
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

if command -v wget >/dev/null 2>&1; then
  fetch_with_wget
elif command -v wget2 >/dev/null 2>&1; then
  fetch_with_wget2
elif command -v httrack >/dev/null 2>&1; then
  fetch_with_httrack
else
  echo "No mirror tool found. Install one of: wget, wget2, httrack" >&2
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

# Inline cross-origin script / stylesheet references.
#
# wget --mirror only follows requisites within the original host, so a
# `<script src="https://cdn.jsdelivr.net/...">` in index.html is left
# pointing at a remote origin. The wrapper's CSP + runtime network
# kill-switch hard-block all http(s) at startup, so any such reference
# breaks the SPA in the desktop wrapper.
#
# Walk index.html, download each absolute external script / stylesheet
# body, and replace the matched element in place with an inline
# equivalent (`<script>…body…</script>` or `<style>…body…</style>`),
# stripping `src` / `href` / `defer` / `async` / `crossorigin` /
# `integrity` (none meaningful for inline). A leading marker comment
# (`/* tweaktrak: inlined from <URL> */`) makes upstream changes
# visible in PR diffs. Result is a single self-contained `index.html`.
localize_externals() {
  local html="$SITE_DIR/index.html"
  local urls
  urls="$(python3 - "$html" <<'PY'
import re, sys
with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
    html = f.read()
patterns = [
    ('script', r'<script\b[^>]*\bsrc=["\']([^"\']+)["\']'),
    ('style',  r'<link\b[^>]*\brel=["\']stylesheet["\'][^>]*\bhref=["\']([^"\']+)["\']'),
    ('style',  r'<link\b[^>]*\bhref=["\']([^"\']+)["\'][^>]*\brel=["\']stylesheet["\']'),
]
seen = set()
for kind, pat in patterns:
    for m in re.finditer(pat, html, flags=re.IGNORECASE):
        url = m.group(1).strip()
        if url.startswith('//') or url.startswith('http://') or url.startswith('https://'):
            key = (kind, url)
            if key not in seen:
                seen.add(key)
                print(f'{kind}\t{url}')
PY
)"

  if [[ -z "$urls" ]]; then
    echo "localize: no external script/stylesheet references found"
    return 0
  fi

  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' RETURN

  while IFS=$'\t' read -r kind url; do
    [[ -z "$url" ]] && continue
    local fetch_url="$url"
    [[ "$fetch_url" == //* ]] && fetch_url="https:${fetch_url}"

    echo "localize: fetching $fetch_url -> inline <$kind>"
    if ! curl -fsSL --max-time 60 -o "$body_file" "$fetch_url"; then
      echo "localize: failed to download $fetch_url" >&2
      return 1
    fi
    if [[ ! -s "$body_file" ]]; then
      echo "localize: downloaded body for $fetch_url is empty" >&2
      return 1
    fi

    python3 - "$html" "$kind" "$url" "$body_file" <<'PY'
import re, sys
path, kind, url, body_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    html = f.read()
with open(body_path, 'r', encoding='utf-8', errors='replace') as f:
    body = f.read()

# Anchor matches to attribute-quoted context (=["']URL["']) so we never
# rewrite inline JS string literals that happen to contain the same URL.
url_attr = r'=(["\'])' + re.escape(url) + r'\1'

if kind == 'script':
    # Match the entire `<script ...src="URL"...></script>` element,
    # including any whitespace between the open tag and `</script>`.
    elem_re = re.compile(
        r'<script\b[^>]*?' + url_attr + r'[^>]*>\s*</script>',
        flags=re.IGNORECASE | re.DOTALL,
    )
    # Escape any literal `</script` in the bundle (e.g. inside string
    # literals or regex bodies) so the HTML parser does not terminate
    # the inlined element prematurely. `<\/script` is equivalent under
    # JS string/regex parsing but invisible to the HTML tokenizer.
    safe_body = re.sub(r'(?i)</(script)', r'<\\/\1', body)
    replacement = f'<script>/* tweaktrak: inlined from {url} */\n{safe_body}</script>'
elif kind == 'style':
    # `<link ...>` is a void element: match through the closing `>`,
    # tolerating an optional self-closing slash.
    elem_re = re.compile(
        r'<link\b[^>]*?' + url_attr + r'[^>]*?/?>',
        flags=re.IGNORECASE | re.DOTALL,
    )
    # Same hazard for `</style` appearing inside CSS string literals.
    safe_body = re.sub(r'(?i)</(style)', r'<\\/\1', body)
    replacement = f'<style>/* tweaktrak: inlined from {url} */\n{safe_body}</style>'
else:
    sys.stderr.write(f'localize: unknown kind {kind}\n')
    sys.exit(2)

# count=0 (unlimited): if the same external URL is referenced by more
# than one element the body is inlined into each, matching the
# pre-inline behaviour where every reference was rewritten.
new_html, n = elem_re.subn(lambda _m: replacement, html)
if n == 0:
    sys.stderr.write(f'localize: no {kind} element matched for {url}\n')
    sys.exit(2)
with open(path, 'w', encoding='utf-8') as f:
    f.write(new_html)
print(f'localize: inlined {kind} body from {url} ({len(body)} bytes)')
PY
  done <<< "$urls"
}

localize_externals

# Patch Alpine event-handler / directive attributes whose expression
# starts with `var ` so it starts with `let ` instead.
#
# Alpine evaluates attribute expressions by splicing them into
# `with (scope) { __self.result = <expr> }` inside a `new AsyncFunction`.
# A leading `var x = …; …` becomes `__self.result = var x = …` which is a
# SyntaxError. Alpine's own heuristic auto-wraps expressions starting with
# `let ` / `const ` in `(async()=>{ … })()`, so rewriting `var ` → `let `
# at attribute-start lets Alpine apply that wrap. Inside a single attribute
# expression the `var`/`let` distinction is behaviourally inert (the binding
# is only referenced in the same statement sequence), so this rewrite is
# semantically safe for the upstream content we mirror.
patch_alpine_var_attrs() {
  local html="$SITE_DIR/index.html"
  python3 - "$html" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    html = f.read()

# Match Alpine-evaluated attributes:
#   @event="…", x-on:event="…", x-init="…", x-effect="…",
#   x-data="…", and any other x-* directive that takes an expression.
# Only rewrite when the attribute value begins with `var ` (or `var\t`).
attr_re = re.compile(
    r'''(?P<prefix>(?:@[a-zA-Z][\w:.-]*|x-[a-zA-Z][\w:.-]*)\s*=\s*)(?P<q>["'])var\s''',
)
def repl(m):
    return f'{m.group("prefix")}{m.group("q")}let '

new_html, n = attr_re.subn(repl, html)
if n:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(new_html)
print(f'patch-alpine-var: rewrote {n} attribute(s) `var ` -> `let `')
PY
}

patch_alpine_var_attrs

rm -rf "$TMP_DIR"
echo "Site mirror ready at $SITE_DIR"
