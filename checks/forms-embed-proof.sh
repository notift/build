#!/usr/bin/env bash
# Proof for the forms script on the site's own domain (docs/prompts/geheel-build-23-oplevering.md).
#
# Runs the real step "Het formulierscript van het platform" and the compression step from
# build-and-publish.yml, as text taken from the workflow, against a customer output that tries to
# plant its own /_notift/embed/forms.js. Then serves the result with the nginx.conf of the base
# image and measures what a browser would get.
#
# Runs on the Mac. Needs bash, python3, curl, nginx and shasum. Changes nothing outside a temp dir.
#
# Usage: ./forms-embed-proof.sh            the proof
#        ./forms-embed-proof.sh --serve    the proof, then keep nginx running for a browser check
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(cd "$HERE/.." && pwd)"
# FORMS_PROOF_WORKFLOW is only for a sabotage run: a broken copy of the workflow must make this fail.
WORKFLOW="${FORMS_PROOF_WORKFLOW:-$BUILD/workflow/build-and-publish.yml}"
SOURCE="$BUILD/embed/forms.js"
SERVE="${1:-}"
WORK="$(mktemp -d)"
NGINX_PID=""
cleanup() { [ -z "$NGINX_PID" ] || kill "$NGINX_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
GOED=0; FOUT=0
pass(){ printf '  ok   %s\n' "$1"; GOED=$((GOED + 1)); }
fail(){ printf '  FOUT %s\n' "$1" >&2; FOUT=$((FOUT + 1)); }
sha(){ shasum -a 256 "$1" | awk '{print $1}'; }

# The run block of a step, by its name, without a YAML library (same approach as build-layer-proof.sh).
step_run() {
  python3 - "$WORKFLOW" "$1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split('\n')
name = sys.argv[2]
start = next(i for i, l in enumerate(lines) if re.match(r'^\s*- name: ' + re.escape(name) + r'\s*$', l))
run = next(i for i in range(start + 1, len(lines)) if re.match(r'^\s*run: \|\s*$', lines[i]))
indent = None
out = []
for l in lines[run + 1:]:
    if l.strip() == '':
        out.append(''); continue
    cur = len(l) - len(l.lstrip())
    if indent is None: indent = cur
    if cur < indent: break
    out.append(l[indent:])
print('\n'.join(out).rstrip())
PY
}

STEP_EMBED="$(step_run 'Het formulierscript van het platform')"
STEP_GZIP="$(step_run 'Vooraf comprimeren')"
SOURCE_SHA="$(sha "$SOURCE")"

printf '\n== Formulierscript: bron ==\n\n'
node --check "$SOURCE" && pass "embed/forms.js is geldig JavaScript" || fail "embed/forms.js heeft een syntaxfout"
hosts="$(grep -o 'https://[^/"]*' "$SOURCE" | sort -u | tr '\n' ' ')"
[ "$hosts" = "https://challenges.cloudflare.com " ] && pass "de enige externe host is Turnstile: $hosts" || fail "externe hosts in embed/forms.js: $hosts"
grep -q 'dataset\.sitekey' "$SOURCE" && pass "de sitesleutel komt van de scripttag" || fail "geen data-sitekey in het script"
printf '  bron sha256 %s\n' "$SOURCE_SHA"

# A fake build layer and a customer output, laid out as job 2 sees them.
layer="$WORK/layer"; mkdir -p "$layer/embed"; cp "$SOURCE" "$layer/embed/forms.js"
evil='window.__evil = "planted by the customer build";'

run_case() { # run_case <dir>: the two workflow steps, in the order of the workflow
  ( cd "$1" && BUILD_LAYER_DIR="$layer" bash -c "$STEP_EMBED" && bash -c "$STEP_GZIP" )
}

printf '\n== Klantuitvoer met een eigen /_notift/embed/forms.js ==\n\n'
c1="$WORK/case1"; s1="$c1/.notift-context/site"
mkdir -p "$s1/_notift/embed" "$s1/_notift/forms"
printf '%s\n' "$evil" > "$s1/_notift/embed/forms.js"
printf '%s\n' "$evil" | gzip -9 > "$s1/_notift/embed/forms.js.gz"
printf 'x' > "$s1/_notift/forms/contact"
printf '<!doctype html><html><head><title>Home</title></head><body><a href="/contact">Contact</a></body></html>\n' > "$s1/index.html"
cat > "$s1/contact.html" <<'HTML'
<!doctype html>
<html lang="nl">
<head>
  <meta charset="utf-8">
  <title>Contact</title>
  <script src="/_notift/embed/forms.js" data-sitekey="1x00000000000000000000AA" defer></script>
</head>
<body>
  <form action="/_notift/forms/contact" method="post">
    <input name="naam" required>
    <input name="email" type="email" required>
    <textarea name="bericht"></textarea>
    <button type="submit">Versturen</button>
  </form>
  <div id="contact-verzonden" style="display:none">Bedankt</div>
  <div id="contact-mislukt" style="display:none">Mislukt</div>
</body>
</html>
HTML
run_case "$c1"
[ "$(sha "$s1/_notift/embed/forms.js")" = "$SOURCE_SHA" ] && pass "het geplante script is vervangen door de bron" || fail "forms.js in de site is niet de bron"
grep -q '__evil' "$s1/_notift/embed/forms.js" && fail "de tekst van de klant staat er nog" || pass "geen regel van de klant in forms.js"
[ "$(gunzip -c "$s1/_notift/embed/forms.js.gz" | shasum -a 256 | awk '{print $1}')" = "$SOURCE_SHA" ] && pass "forms.js.gz is de gecomprimeerde bron, niet die van de klant" || fail "forms.js.gz is niet de bron"
[ ! -e "$s1/_notift/forms" ] && pass "de rest van /_notift/ van de klant is weg" || fail "/_notift/forms van de klant bleef staan"

printf '\n== Klantuitvoer met /_notift als symlink ==\n\n'
c2="$WORK/case2"; s2="$c2/.notift-context/site"
mkdir -p "$s2/assets/embed"; printf '%s\n' "$evil" > "$s2/assets/embed/forms.js"
ln -s assets "$s2/_notift"
run_case "$c2"
[ -d "$s2/_notift" ] && [ ! -L "$s2/_notift" ] && pass "/_notift is een gewone map geworden" || fail "/_notift is nog een symlink"
[ "$(sha "$s2/_notift/embed/forms.js")" = "$SOURCE_SHA" ] && pass "forms.js is de bron" || fail "forms.js is niet de bron"
grep -q '__evil' "$s2/assets/embed/forms.js" && pass "de map waar de symlink heen wees is niet aangeraakt" || fail "het doel van de symlink is overschreven"

printf '\n== Klantuitvoer zonder /_notift ==\n\n'
c3="$WORK/case3"; s3="$c3/.notift-context/site"; mkdir -p "$s3"; printf '<p>x</p>\n' > "$s3/index.html"
run_case "$c3"
[ "$(sha "$s3/_notift/embed/forms.js")" = "$SOURCE_SHA" ] && pass "ook een site zonder formulier krijgt het script" || fail "forms.js ontbreekt"
[ "$(stat -f '%Lp' "$s3/_notift/embed/forms.js" 2>/dev/null || stat -c '%a' "$s3/_notift/embed/forms.js")" = 644 ] && pass "rechten 644, leesbaar voor nginx" || fail "rechten van forms.js kloppen niet"

printf '\n== Geserveerd met de nginx.conf van het basisimage ==\n\n'
conf_dir="$(nginx -V 2>&1 | tr ' ' '\n' | sed -n 's/^--conf-path=\(.*\)nginx\.conf$/\1/p')"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
mkdir -p "$WORK/nginx"
sed -e "s#include       /etc/nginx/mime.types;#include       ${conf_dir}mime.types;#" \
    -e "s#root /usr/share/nginx/html;#root $s1;#" \
    -e "s#listen 8080;#listen 127.0.0.1:$port;#" \
    -e "s#/tmp/#$WORK/nginx/#g" \
    -e "s#access_log    /dev/stdout combined;#access_log    $WORK/nginx/access.log combined;#" \
    "$BUILD/base/nginx.conf" > "$WORK/nginx/nginx.conf"
nginx -t -q -c "$WORK/nginx/nginx.conf" -e "$WORK/nginx/error.log"
nginx -c "$WORK/nginx/nginx.conf" -e "$WORK/nginx/error.log" -g 'daemon off;' 2>>"$WORK/nginx/error.log" &
NGINX_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done
base="http://127.0.0.1:$port"
hdr="$(curl -s -D - -o "$WORK/got.js" "$base/_notift/embed/forms.js" | tr -d '\r')"
printf '%s\n' "$hdr" | sed -n '1p;/^[Cc]ontent-[Tt]ype/p;/^[Cc]ache-[Cc]ontrol/p' | sed 's/^/  > /'
printf '%s\n' "$hdr" | head -1 | grep -q ' 200' && pass "GET /_notift/embed/forms.js geeft 200" || fail "geen 200"
printf '%s\n' "$hdr" | grep -qi '^content-type: application/javascript' && pass "content-type is JavaScript" || fail "verkeerde content-type"
[ "$(sha "$WORK/got.js")" = "$SOURCE_SHA" ] && pass "de browser krijgt precies de bron" || fail "de inhoud wijkt af van de bron"
ghdr="$(curl -s -D - -o /dev/null -H 'Accept-Encoding: gzip' "$base/_notift/embed/forms.js" | tr -d '\r')"
printf '%s\n' "$ghdr" | grep -qi '^content-encoding: gzip' && pass "met gzip uit gzip_static" || fail "geen gzip"
curl -s "$base/contact" > "$WORK/contact.html"
grep -q 'src="/_notift/embed/forms.js"' "$WORK/contact.html" && pass "/contact laadt het script van het eigen domein" || fail "/contact laadt het script niet"
grep -q 'app\.notift\.nl' "$WORK/contact.html" && fail "/contact noemt app.notift.nl" || pass "/contact noemt app.notift.nl niet"

printf '\n  %s goed, %s fout\n\n' "$GOED" "$FOUT"
if [ "$SERVE" = "--serve" ] && [ "$FOUT" = 0 ]; then
  printf '  Serving %s until this script is stopped (Ctrl-C).\n  Site root: %s\n\n' "$base" "$s1"
  wait "$NGINX_PID"
fi
[ "$FOUT" = 0 ]
