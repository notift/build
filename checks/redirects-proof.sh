#!/usr/bin/env bash
# Proof for redirects per path (docs/07-bouwlaag.md, "Redirects per pad", besluit 106).
#
# 1. Every kind of error in _redirects refuses the build, with the line in the message: through
#    check_output.py (jobs 1 and 2) and through the generate step of job 2, which then writes no map.
# 2. No _redirects, an empty one, one with only comments, and the default map of the base image all
#    give an empty map that nginx -t accepts.
# 3. The good cases served by nginx with the nginx.conf of the base image: 301, 302, 307 and 308,
#    the query string carried along, a redirect wins from an existing file, the trailing slash does
#    not count, capitals do, and the existing slash and .html rules keep working.
# 4. The gate (base/redirects-gate.sh, in the base image from version 7): nginx -t refuses a broken map,
#    and the include check refuses an nginx.conf that does not load the map. The RUN of site.Dockerfile,
#    taken from the file: green on the new base image, refused with the reason on an older one.
# 5. The size limits: 2000 rules of 1000 characters pass nginx -t; one rule more is refused.
# 6. The check before a DNS cutover (infra/runtime/redirects-check.sh), when it is next to this
#    build layer: green against the good site, red with the path when a rule is not deployed.
#
# Runs on the Mac. Needs bash, python3, curl and nginx (Homebrew). Changes nothing outside its temp dir,
# and stops every nginx it starts. External network only for the external destination in part 6.
#
# REDIRECTS_PROOF_BUILD points at another build layer (for the red run before the change and for
# sabotage runs); REDIRECTS_PROOF_NGINX_CONF at another nginx.conf.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(cd "${REDIRECTS_PROOF_BUILD:-$HERE/..}" && pwd)"
CONF="${REDIRECTS_PROOF_NGINX_CONF:-$BUILD/base/nginx.conf}"
PARSER="$BUILD/checks/redirects.py"
CHECK="$BUILD/checks/check_output.py"
CHECKER="$BUILD/../runtime/redirects-check.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/redirects-proof.XXXXXX")"
NGINX_PIDS=""
cleanup() {
  for p in $NGINX_PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT
GOED=0; FOUT=0; FOUTEN=""
pass() { printf '  ok   %s\n' "$1"; GOED=$((GOED + 1)); }
fail() { printf '  FOUT %s\n' "$1"; FOUT=$((FOUT + 1)); FOUTEN="${FOUTEN}  FOUT $1
"; }
conf_dir="$(nginx -V 2>&1 | tr ' ' '\n' | sed -n 's/^--conf-path=\(.*\)nginx\.conf$/\1/p')"

cat > "$WORK/notift.json" <<'JSON'
{"organisation": "org_99001", "project": "prj_99001", "module": "mod_99001", "plan": "websites-1",
 "package": "ghcr.io/notift/mod_99001",
 "build": {"command": "npm run build", "output": "dist", "node": "22", "manager": "npm"},
 "searchable": true, "allowed_public_keys": []}
JSON

page() { # page <file> <title>
  mkdir -p "$(dirname "$1")"
  printf '<!doctype html><html lang="nl"><head><title>%s</title><meta name="description" content="%s"></head><body><h1>%s</h1><p>Dit is de pagina %s van de proefsite. Er staat genoeg tekst op om door de controle van de uitvoer te komen.</p></body></html>\n' "$2" "$2" "$2" "$2" > "$1"
}
site() { # site <dir>: the same small site every time
  page "$1/index.html" Home
  page "$1/over-ons.html" "Over ons"
  page "$1/contact.html" Contact
  page "$1/team/index.html" Team
  page "$1/klachten.html" Klachten
  page "$1/klachten/rugpijn.html" Rugpijn
  page "$1/oud-bestand.html" "Oud bestand"
  mkdir -p "$1/files"; printf '%%PDF-1.4 brochure\n' > "$1/files/brochure.pdf"
  printf '20261022-1200-abcdef0' > "$1/_health"
}

# ---------------------------------------------------------------------------------------------
printf '\n== 1. Elke soort fout weigert de build, met de regel in de melding ==\n\n'
N=0
# refuse <name> <line> <expected fragment> <content of _redirects, printf format>
refuse() {
  local naam="$1" regel="$2" stuk="$3" inhoud="$4" d out rc
  N=$((N + 1)); d="$WORK/fout$N"; site "$d/dist"
  printf "$inhoud" > "$d/dist/_redirects"
  out="$(cd "$d" && python3 -I "$CHECK" dist "$WORK/notift.json" 2>&1)"; rc=$?
  if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -F "FOUT" | grep -F "_redirects regel $regel:" | grep -qF -- "$stuk"; then
    pass "$naam: check_output.py weigert, regel $regel"
  else
    fail "$naam: check_output.py gaf rc=$rc zonder 'regel $regel: ...$stuk'"; printf '%s\n' "$out" | grep -E 'FOUT|Traceback|Error' | sed 's/^/       /' | head -4
  fi
  out="$(GITHUB_ACTIONS=true python3 -I "$PARSER" generate "$d/dist" "$d/redirects.map" 2>&1)"; rc=$?
  if [ "$rc" = 1 ] && [ ! -e "$d/redirects.map" ] \
     && printf '%s\n' "$out" | grep -qF -- "::error title=_redirects regel $regel::" \
     && printf '%s\n' "$out" | grep -F "::error" | sed 's/%25/%/g' | grep -qF -- "$stuk"; then
    pass "$naam: generate weigert, geen map, annotatie met regel $regel"
  else
    fail "$naam: generate gaf rc=$rc, map $( [ -e "$d/redirects.map" ] && echo wel || echo niet) geschreven"; printf '%s\n' "$out" | head -3 | sed 's/^/       /'
  fi
}
refuse "syntaxis, alleen een bron"      2 "een bron en een bestemming nodig"     '# lijst\n/alleen-bron\n'
refuse "syntaxis, te veel velden"        1 "te veel velden"                       '/oud /over-ons 301 Country=nl\n'
refuse "statuscode 200"                  1 "onbekende statuscode '200'"           '/oud /over-ons 200\n'
refuse "statuscode 404"                  1 "onbekende statuscode '404'"           '/oud /over-ons 404\n'
refuse "statuscode tekst"                1 "onbekende statuscode 'permanent'"     '/oud /over-ons permanent\n'
refuse "statuscode 301!"                 1 "met ! is niet nodig"                  '/oud /over-ons 301!\n'
refuse "bron zonder /"                   1 "een bron begint met /"                'oud /over-ons\n'
refuse "bron als URL"                    1 "geen volledige URL"                   'https://oud.example.nl/a /over-ons\n'
refuse "wildcard"                        1 "wildcards (*)"                        '/blog/* /over-ons\n'
refuse "placeholder"                     1 "placeholders (:naam)"                 '/blog/:slug /over-ons\n'
refuse "querystring in de bron"          1 "querystring in de bron"               '/oud?id=3 /over-ons\n'
refuse "querystring in de bestemming"    1 "querystring in de bestemming"         '/oud /over-ons?x=1\n'
refuse "aanhalingsteken"                 1 "mag niet in de bron"                  '/a"b /over-ons\n'
refuse "dollarteken"                     1 "mag niet in de bestemming"            '/oud /over$ons\n'
refuse "puntkomma"                       1 "mag niet in de bron"                  '/a;b /over-ons\n'
refuse "backslash"                       1 "mag niet in de bron"                  '/a\\b /over-ons\n'
refuse "accolade"                        1 "mag niet in de bron"                  '/a{b} /over-ons\n'
refuse "buiten ASCII"                    1 "/%C3%BCber"                           '/über /over-ons\n'
refuse "halve procentcodering"               1 "twee hexadecimale cijfers"            '/a%%2 /over-ons\n'
refuse "/../ in de bron"                 1 "/./ of /../"                          '/a/../b /over-ons\n'
refuse "protocolrelatief"                1 "met // beginnen"                      '/oud //evil.example/x\n'
refuse "geen UTF-8"                      2 "geen UTF-8"                           '/a /over-ons\n/b\xff /contact\n'
refuse "dubbele bron"                    3 "dubbele bron: /oud staat al op regel 1" '/oud /over-ons\n/ander /contact\n/oud /contact\n'
refuse "dubbele bron via de slash"       2 "slash aan het eind telt niet"          '/oud /over-ons\n/oud/ /contact\n'
refuse "dubbele bron in hoofdletters"    2 "alleen in hoofdletters"                '/Oud /over-ons\n/oud /contact\n'
refuse "ketting"                         1 "ketting: de bestemming /b is zelf een bron (regel 2)" '/a /b\n/b /over-ons\n'
refuse "lus van twee"                    1 "lus: /a -> /b -> /a"                   '/a /b\n/b /a\n'
refuse "lus naar zichzelf"               1 "lus: de bestemming /a is de bron zelf" '/a /a 302\n'
refuse "lus via de slash-regel"          1 "slash aan het eind telt niet"          '/a/ /a\n'
refuse "bron /"                          1 "homepagina"                            '/ /over-ons\n'
refuse "bron /index.html"                1 "homepagina"                            '/index.html /over-ons\n'
refuse "bron /_health"                   1 "bedient het platform zelf"             '/_health /over-ons\n'
refuse "bron security.txt"               1 "bedient het platform zelf"             '/.well-known/security.txt /over-ons\n'
refuse "bron /_notift/"                  1 "bedient het platform zelf"             '/_notift/embed/forms.js /over-ons\n'
refuse "bestemming .html"                1 "de .html-regel stuurt /over-ons.html door naar /over-ons" '/oud /over-ons.html\n'
refuse "bestemming /index.html"          1 "de .html-regel stuurt /team/index.html door naar /team/" '/oud /team/index.html\n'
refuse "bestemming met slash"            1 "de slash-regel stuurt /over-ons/ door naar /over-ons" '/oud /over-ons/\n'
refuse "bestemming map zonder slash"     1 "nginx stuurt /team door naar /team/"   '/oud /team\n'
refuse "bestemming bestaat niet"         1 "de bestemming /bestaat-niet bestaat niet" '/oud /bestaat-niet\n'
refuse "fout op een latere regel"        4 "onbekende statuscode '300'"            '# kop\n/a /over-ons\n\n/b /contact 300\n'

N=$((N + 1)); d="$WORK/fout$N"; site "$d/dist"; mkdir -p "$d/dist/_redirects"
out="$(cd "$d" && python3 -I "$CHECK" dist "$WORK/notift.json" 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qF "_redirects moet een gewoon bestand zijn" \
  && pass "_redirects als map: geweigerd" || fail "_redirects als map: rc=$rc"
N=$((N + 1)); d="$WORK/fout$N"; site "$d/dist"; printf '/a /over-ons\n' > "$WORK/elders"; ln -s "$WORK/elders" "$d/dist/_redirects"
out="$(python3 -I "$PARSER" generate "$d/dist" "$d/redirects.map" 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ ! -e "$d/redirects.map" ] && printf '%s\n' "$out" | grep -qF "gewoon bestand" \
  && pass "_redirects als symlink: geweigerd, geen map" || fail "_redirects als symlink: rc=$rc"
N=$((N + 1)); d="$WORK/fout$N"; site "$d/dist"
python3 -c 'print("\n".join(f"/oud-{i} /over-ons" for i in range(2001)))' > "$d/dist/_redirects"
out="$(python3 -I "$PARSER" check "$d/dist" 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qF "meer dan 2000 regels" && pass "2001 regels: geweigerd" || fail "2001 regels: rc=$rc"

# ---------------------------------------------------------------------------------------------
printf '\n== nginx met de nginx.conf van het basisimage ==\n\n'
# nginx_conf <dir> <port> <map> [conf]: the base nginx.conf with Mac paths, as forms-embed-proof.sh does.
nginx_conf() {
  local dir="$1" port="$2" map="$3" src="${4:-$CONF}"
  mkdir -p "$dir/nginx"
  printf 'Contact: mailto:info@notift.nl\n' > "$dir/nginx/security.txt"
  # /tmp/ first: the paths put in after it may themselves contain /tmp/.
  sed -e "s#/tmp/#$dir/nginx/#g" \
      -e "s#include       /etc/nginx/mime.types;#include       ${conf_dir}mime.types;#" \
      -e "s#root /usr/share/nginx/html;#root $dir/site;#" \
      -e "s#listen 8080;#listen 127.0.0.1:$port;#" \
      -e "s#/etc/nginx/notift/redirects.map#$map#" \
      -e "s#/etc/nginx/notift/security.txt#$dir/nginx/security.txt#" \
      -e "s#access_log    /dev/stdout combined;#access_log    $dir/nginx/access.log combined;#" \
      "$src" > "$dir/nginx/nginx.conf"
}
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
start_nginx() { # start_nginx <dir> <port>
  nginx -c "$1/nginx/nginx.conf" -e "$1/nginx/error.log" -g 'daemon off;' 2>>"$1/nginx/error.log" &
  NGINX_PIDS="$NGINX_PIDS $!"
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$2/_health" && return 0; sleep 0.1; done
  return 1
}
expect() { # expect <port> <path> <code> <location>
  local kop got
  kop="$(curl -s -o /dev/null -D - --max-time 5 "http://127.0.0.1:$1$2" | tr -d '\r')"
  got="$(printf '%s\n' "$kop" | awk 'NR==1{print $2}') $(printf '%s\n' "$kop" | awk 'tolower($1)=="location:"{print $2}')"
  if [ "$got" = "$3 $4" ]; then pass "$2 geeft $3${4:+ $4}"; else fail "$2 geeft '$got', verwacht '$3${4:+ $4}'"; fi
}

printf '\n== 2. Geen lijst, een lege lijst, alleen commentaar, en de standaard van het basisimage ==\n\n'
for geval in geen leeg commentaar; do
  d="$WORK/leeg-$geval"; site "$d/site"
  case "$geval" in leeg) : > "$d/site/_redirects" ;; commentaar) printf '# nog niets\n\n   # ook niets\n' > "$d/site/_redirects" ;; esac
  if python3 -I "$PARSER" generate "$d/site" "$d/redirects.map" >/dev/null 2>&1 && [ -f "$d/redirects.map" ] \
     && [ "$(grep -vc '^#' "$d/redirects.map")" = 0 ]; then
    pass "$geval _redirects: een map zonder regels"
  else fail "$geval _redirects: geen lege map"; fi
  port="$(free_port)"; nginx_conf "$d" "$port" "$d/redirects.map"
  if nginx -t -q -c "$d/nginx/nginx.conf" -e "$d/nginx/error.log" 2>/dev/null; then pass "$geval _redirects: nginx -t groen"
  else fail "$geval _redirects: nginx -t rood"; fi
done
d="$WORK/basis"; site "$d/site"; port="$(free_port)"; nginx_conf "$d" "$port" "$BUILD/base/redirects.map"
if [ -f "$BUILD/base/redirects.map" ] && nginx -t -q -c "$d/nginx/nginx.conf" -e "$d/nginx/error.log" 2>/dev/null; then
  pass "de standaardmap van het basisimage: nginx -t groen"
  start_nginx "$d" "$port" || fail "nginx start niet"
  expect "$port" /oud-1 404 ""
  expect "$port" /over-ons 200 ""
else fail "de standaardmap van het basisimage ontbreekt of nginx -t is rood"; fi

# ---------------------------------------------------------------------------------------------
printf '\n== 3. De goede gevallen ==\n\n'
G="$WORK/goed"; site "$G/site"
cat > "$G/site/_redirects" <<'EOF'
# Oude adressen van de vorige site.
/oud-1                  /over-ons
/oud-2/                 /contact            308
	/Oud-Hoofdletter    /team/              302
/oud-bestand.html       /over-ons           307
/oud-pdf                /files/brochure.pdf
/over%20ons             /over-ons           301
/klachten/rugpijn-oud   /klachten/rugpijn
/extern                 https://example.com/
EOF
printf '\r\n' >> "$G/site/_redirects"
out="$(cd "$G" && python3 -I "$CHECK" site "$WORK/notift.json" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "check_output.py keurt de goede lijst goed" || { fail "check_output.py weigert de goede lijst (rc=$rc)"; printf '%s\n' "$out" | grep FOUT | head -5; }
printf '%s\n' "$out" | grep -qF "_redirects regel 5: /oud-bestand.html bestaat ook in de site; de redirect wint" \
  && pass "waarschuwing: de bron bestaat ook als bestand" || fail "geen waarschuwing voor /oud-bestand.html"
python3 -I "$PARSER" generate "$G/site" "$G/redirects.map" > "$G/gen.txt" 2>&1 && pass "generate: $(grep -o '[0-9]* redirect(s)' "$G/gen.txt")" || fail "generate faalt op de goede lijst"
port="$(free_port)"; nginx_conf "$G" "$port" "$G/redirects.map"
if nginx -t -q -c "$G/nginx/nginx.conf" -e "$G/nginx/error.log" 2>"$G/t.txt"; then pass "nginx -t groen"; else fail "nginx -t rood: $(cat "$G/t.txt")"; fi
start_nginx "$G" "$port" || fail "nginx start niet"
P="$port"
expect $P /oud-1                     301 /over-ons
expect $P /oud-1/                    301 /over-ons
expect $P "/oud-1?utm_source=x&b=2"  301 "/over-ons?utm_source=x&b=2"
expect $P "/oud-1/?a=1"              301 "/over-ons?a=1"
expect $P /oud-2                     308 /contact
expect $P /oud-2/                    308 /contact
expect $P "/oud-2?a=1"               308 "/contact?a=1"
expect $P /Oud-Hoofdletter           302 /team/
expect $P /oud-hoofdletter           404 ""
expect $P /OUD-1                     404 ""
expect $P /oud-bestand.html          307 /over-ons
expect $P /oud-pdf                   301 /files/brochure.pdf
expect $P /over%20ons                301 /over-ons
expect $P /klachten/rugpijn-oud      301 /klachten/rugpijn
expect $P /extern                    301 https://example.com/
expect $P "/extern?q=1"              301 "https://example.com/?q=1"
printf '\n  -- de bestemmingen zelf --\n'
expect $P /over-ons                  200 ""
expect $P /contact                   200 ""
expect $P /team/                     200 ""
expect $P /files/brochure.pdf        200 ""
expect $P /klachten/rugpijn          200 ""
printf '\n  -- de bestaande regels van het basisimage --\n'
expect $P /                          200 ""
expect $P "/?a=1"                    200 ""
expect $P /index.html                301 /
expect $P /over-ons/                 301 /over-ons
expect $P /over-ons.html             301 /over-ons
expect $P "/contact/?a=1"            301 "/contact?a=1"
expect $P /team                      301 /team/
expect $P /team/index.html           301 /team/
expect $P /klachten                  200 ""
expect $P /klachten/                 301 /klachten
expect $P /oud-bestand               200 ""
expect $P /_health                   200 ""
expect $P /.well-known/security.txt  200 ""
expect $P /oud-3                     404 ""
expect $P /bestaat-niet.html         404 ""

# ---------------------------------------------------------------------------------------------
printf '\n== 4. De poort: base/redirects-gate.sh in het basisimage, aangeroepen door site.Dockerfile ==\n\n'
DOCKERFILE="$BUILD/base/site.Dockerfile"
GATE="$BUILD/base/redirects-gate.sh"
grep -qF 'COPY redirects.map /etc/nginx/notift/redirects.map' "$DOCKERFILE" 2>/dev/null \
  && pass "site.Dockerfile zet de map op de plek die nginx.conf laadt" || fail "site.Dockerfile kopieert de map niet"
grep -qF 'COPY redirects-gate.sh /usr/local/lib/notift/redirects-gate.sh' "$BUILD/base/Dockerfile" 2>/dev/null \
  && pass "het basisimage draagt de poort" || fail "base/Dockerfile kopieert redirects-gate.sh niet"
grep -qF '&& sh /usr/local/lib/notift/redirects-gate.sh' "$DOCKERFILE" 2>/dev/null \
  && pass "site.Dockerfile draait de poort uit het basisimage" || fail "site.Dockerfile draait de poort niet"
gate() { # gate <conf> <map>: the real gate script, with the Mac paths for nginx
  NOTIFT_REDIRECTS_MAP="$2" sh "$GATE" -c "$1" -e "$WORK/gate.log" 2>"$WORK/gate.err"
}
gate "$G/nginx/nginx.conf" "$G/redirects.map" && pass "de poort is groen op de goede site" || fail "de poort is rood op de goede site: $(head -1 "$WORK/gate.err")"
d="$WORK/kapot"; mkdir -p "$d"; site "$d/site"
printf '"/a" "/a 301 /over-ons"\n' > "$d/redirects.map"
port="$(free_port)"; nginx_conf "$d" "$port" "$d/redirects.map"
if gate "$d/nginx/nginx.conf" "$d/redirects.map"; then fail "de poort laat een kapotte map door"
else grep -qF 'redirects: nginx -t is rood' "$WORK/gate.err" && pass "een kapotte map: nginx -t rood, de build stopt" \
  || fail "een kapotte map: rood, maar niet om nginx -t: $(head -1 "$WORK/gate.err")"; fi
# A base image whose nginx.conf does not load the map (as before the redirects): nginx -t alone is green,
# so only the include check can stop it.
d="$WORK/oud"; mkdir -p "$d"; site "$d/site"; cp "$G/redirects.map" "$d/redirects.map"
grep -v 'include  /etc/nginx/notift/redirects.map;' "$CONF" > "$d/oud-nginx.conf"
port="$(free_port)"; nginx_conf "$d" "$port" "$d/redirects.map" "$d/oud-nginx.conf"
if nginx -t -q -c "$d/nginx/nginx.conf" -e "$d/nginx/error.log" 2>/dev/null; then
  if gate "$d/nginx/nginx.conf" "$d/redirects.map"; then fail "de poort laat een nginx.conf zonder include door"
  else grep -qF 'laadt' "$WORK/gate.err" && pass "nginx.conf die de map niet laadt: nginx -t groen, maar de include-eis stopt de build" \
    || fail "nginx.conf zonder include: rood, maar niet om de include: $(head -1 "$WORK/gate.err")"; fi
else
  fail "nginx.conf zonder include is al rood bij nginx -t; de include-eis is zo niet getoetst"
fi

# The RUN of site.Dockerfile itself, taken from the file (not retyped), on a fake image root: the backslash
# continuations joined as Docker does, /tmp/ and /usr/local/lib/notift/ moved into the root, and an nginx
# on PATH that adds the Mac config. New base: the gate is in the root. Old base (BASE before version 7):
# no gate and an nginx.conf without the include; the build has to stop with the reason.
run_text="$(sed -n '/^RUN test -f \/usr\/local\/lib\/notift\/redirects-gate.sh/,/rm -rf \/tmp\/body/p' "$DOCKERFILE" \
  | sed -e '1s/^RUN //' -e 's/\\$//' | tr '\n' ' ')"
run_site_dockerfile() { # run_site_dockerfile <root> <conf> <map>: rc of the RUN, stderr in <root>/run.err
  local root="$1" text
  mkdir -p "$root/bin" "$root/tmp/body"
  printf '#!/bin/sh\nexec %s "$@" -c %s -e %s\n' "$(command -v nginx)" "$2" "$root/error.log" > "$root/bin/nginx"
  chmod +x "$root/bin/nginx"
  text="$(printf '%s' "$run_text" | sed -e "s#/tmp/#$root/tmp/#g" -e "s#/usr/local/lib/notift/#$root/usr/local/lib/notift/#g")"
  PATH="$root/bin:$PATH" NOTIFT_REDIRECTS_MAP="$3" /bin/sh -c "$text" >"$root/run.out" 2>"$root/run.err"
}
if [ -z "$run_text" ]; then
  fail "de RUN met de poort staat niet in site.Dockerfile"
else
  r="$WORK/basis-nieuw"; mkdir -p "$r/usr/local/lib/notift"; cp "$GATE" "$r/usr/local/lib/notift/redirects-gate.sh" 2>/dev/null
  run_site_dockerfile "$r" "$G/nginx/nginx.conf" "$G/redirects.map" \
    && [ ! -e "$r/tmp/body" ] && pass "de RUN van site.Dockerfile op het nieuwe basisimage: groen, /tmp opgeruimd" \
    || fail "de RUN van site.Dockerfile op het nieuwe basisimage: rood: $(head -1 "$r/run.err")"
  r="$WORK/basis-oud"; mkdir -p "$r"
  if run_site_dockerfile "$r" "$d/nginx/nginx.conf" "$d/redirects.map"; then
    fail "de RUN van site.Dockerfile op een basisimage van voor de redirects is groen"
  else
    grep -qF 'zet BASE op versie 7 of later' "$r/run.err" \
      && pass "de RUN van site.Dockerfile op een basisimage van voor de redirects: geweigerd, met de reden" \
      || fail "op het oude basisimage rood, maar zonder de reden: $(head -1 "$r/run.err")"
  fi
fi

# ---------------------------------------------------------------------------------------------
printf '\n== 5. De grenzen: 2000 regels van 1000 tekens ==\n\n'
d="$WORK/groot"; site "$d/site"
python3 - "$d/site/_redirects" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(2000):
        bron = f"/{i:04d}-" + "x" * 994
        f.write(f"{bron} /over-ons\n")
PY
if python3 -I "$PARSER" generate "$d/site" "$d/redirects.map" >/dev/null 2>&1; then
  pass "2000 regels van 1000 tekens: generate groen"
  port="$(free_port)"; nginx_conf "$d" "$port" "$d/redirects.map"
  nginx -t -q -c "$d/nginx/nginx.conf" -e "$d/nginx/error.log" 2>"$d/t.txt" && pass "en nginx -t groen" || fail "nginx -t rood: $(head -1 "$d/t.txt")"
  start_nginx "$d" "$port" || fail "nginx start niet"
  lang="/1999-$(printf 'x%.0s' $(seq 1 994))"
  got="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 5 "http://127.0.0.1:$port$lang")"
  [ "$got" = "301 http://127.0.0.1:$port/over-ons" ] && pass "de laatste bron van 1000 tekens geeft 301 /over-ons" \
    || fail "de laatste bron van 1000 tekens geeft '$got'"
else fail "2000 regels van 1000 tekens: generate rood"; fi
d2="$WORK/groot-zonder"; mkdir -p "$d2"; cp -R "$d/site" "$d2/site"
grep -v 'map_hash_' "$CONF" > "$d2/conf"
port="$(free_port)"; nginx_conf "$d2" "$port" "$d/redirects.map" "$d2/conf"
nginx -t -q -c "$d2/nginx/nginx.conf" -e "$d2/nginx/error.log" 2>"$d2/t.txt" \
  && fail "zonder map_hash_* is nginx -t ook groen: de instellingen zijn niet nodig" \
  || pass "zonder map_hash_* is nginx -t rood: $(sed 's/.*\] //' "$d2/t.txt" | head -1)"

# ---------------------------------------------------------------------------------------------
printf '\n== 6. De proef voor de DNS-omzet (redirects-check.sh) ==\n\n'
if [ -f "$CHECKER" ]; then
  out="$(REDIRECTS_CHECK_PARSER="$PARSER" REDIRECTS_CHECK_IP=127.0.0.1 REDIRECTS_CHECK_SCHEME=http REDIRECTS_CHECK_PORT="$P" \
         bash "$CHECKER" www.proef.invalid "$G/site/_redirects" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^[0-9]+ regel' | sed 's/^/  > /'
  [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'Alles OK.' && pass "groen tegen de goede site" \
    || { fail "rood tegen de goede site (rc=$rc)"; printf '%s\n' "$out" | grep FOUT | head -5; }
  # Sabotage: a rule in the list that is not deployed.
  cp "$G/site/_redirects" "$WORK/sabotage"; printf '/niet-uitgerold /over-ons\n' >> "$WORK/sabotage"
  out="$(REDIRECTS_CHECK_PARSER="$PARSER" REDIRECTS_CHECK_IP=127.0.0.1 REDIRECTS_CHECK_SCHEME=http REDIRECTS_CHECK_PORT="$P" \
         bash "$CHECKER" www.proef.invalid "$WORK/sabotage" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^FOUT  regel 11: /niet-uitgerold geeft' \
    && pass "sabotage (een regel niet uitgerold): rood, met het pad" || fail "sabotage niet rood (rc=$rc)"
  # Sabotage: a rule deployed with another destination.
  sed 's#^/oud-pdf .*#/oud-pdf /contact#' "$G/site/_redirects" > "$WORK/sabotage2"
  out="$(REDIRECTS_CHECK_PARSER="$PARSER" REDIRECTS_CHECK_IP=127.0.0.1 REDIRECTS_CHECK_SCHEME=http REDIRECTS_CHECK_PORT="$P" \
         bash "$CHECKER" www.proef.invalid "$WORK/sabotage2" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qF "FOUT  regel 6: /oud-pdf geeft '301 /files/brochure.pdf', verwacht '301 /contact'" \
    && pass "sabotage (andere bestemming): rood, met het pad" || fail "sabotage andere bestemming niet rood (rc=$rc)"
  # A list without rules measures nothing, and that is never green.
  printf '# niets\n' > "$WORK/leeg-lijst"
  out="$(REDIRECTS_CHECK_PARSER="$PARSER" REDIRECTS_CHECK_IP=127.0.0.1 REDIRECTS_CHECK_SCHEME=http REDIRECTS_CHECK_PORT="$P" \
         bash "$CHECKER" www.proef.invalid "$WORK/leeg-lijst" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qF 'Geen enkele regel gemeten' \
    && pass "een lege lijst is geen bewijs: rood" || fail "een lege lijst gaf rc=$rc"
else
  printf '  --   %s staat niet naast deze bouwlaag (in notift/build hoort hij niet); overgeslagen\n' "$CHECKER"
fi

printf '\n== 7. Geen bijproduct in de bouwlaag ==\n\n'
# release.sh copies checks/ as a whole to the public notift/build: an import must not leave __pycache__ behind.
[ ! -e "$BUILD/checks/__pycache__" ] && pass "geen __pycache__ in checks/ na alle aanroepen" || fail "checks/__pycache__ is aangemaakt"

printf '\n  %s goed, %s fout\n' "$GOED" "$FOUT"
[ "$FOUT" = 0 ] || printf '\n%s' "$FOUTEN"
printf '\n'
[ "$FOUT" = 0 ]
