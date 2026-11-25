#!/usr/bin/env bash
# Tegenproeven voor de harde grens tussen een klantrepo en de bouwlaag, en tussen job 1 en job 2.
# Elk geval draait het echte script of het echte run-blok uit de workflow; een geweigerde fixture maakt
# deze proef rood. Draait op macOS (BSD) en Linux (GNU). Vraagt de check-bestanden van de keuringsronde
# (install_mode en install_packages in check_output.py en install_deps.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check_output.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
GOED=0; FOUT=0

pass(){ printf '  ok   %s\n' "$1"; GOED=$((GOED + 1)); }
fail(){ printf '  FOUT %s\n' "$1" >&2; FOUT=$((FOUT + 1)); }

manifest() {
  cat > "$1" <<'JSON'
{"organisation":"org_00001","project":"prj_00001","module":"mod_00001","plan":"websites-1","package":"ghcr.io/notift/mod_00001","build":{"command":"npm run build","output":"dist","node":"22","manager":"npm"},"searchable":true,"allowed_public_keys":[]}
JSON
}

printf '\n== Tegenproef bouwlaag: manifest en werkmap ==\n\n'
manifest "$WORK/goed.json"
python3 "$CHECK" --github-output "$WORK/goed.json" >/dev/null && pass "een geldig manifest levert alleen getoetste uitvoer" || fail "geldig manifest werd geweigerd"

# Elke vorm die in een shell betekenis heeft moet bij het lezen falen. De test
# wijzigt ieder veld apart; een geslaagde parse zou dus een route naar de
# workflowomgeving openen.
for veld in organisation project module plan package command output node manager bun profile trigger; do
  for waarde in '$(id)' '`id`' 'x;id' $'x\nid' '../x'; do
    python3 - "$WORK/goed.json" "$WORK/slecht.json" "$veld" "$waarde" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
pad = sys.argv[3].split('.')
if pad[0] in ('command', 'output', 'node', 'manager', 'bun', 'profile', 'trigger'):
    m['build'][pad[0]] = sys.argv[4]
else:
    m[pad[0]] = sys.argv[4]
json.dump(m, open(sys.argv[2], 'w'))
PY
    if python3 "$CHECK" --github-output "$WORK/slecht.json" >/dev/null 2>&1; then
      fail "$veld liet $waarde door"
    else
      pass "$veld weigert shellvorm"
    fi
  done
done

# Workflowexpressies worden alleen door Actions geëvalueerd in declaratieve
# velden (zoals env en with). Een expressie midden in een shellblok zou weer
# een injectiepad maken, dus bewaak beide workflows zonder YAML-afhankelijkheid.
if python3 - "$HERE/../workflow/build-and-publish.yml" "$HERE/../workflow/base-image.yml" <<'PY'
import re, sys

for name in sys.argv[1:]:
    run_indent = None
    for nummer, regel in enumerate(open(name), 1):
        inspringing = len(regel) - len(regel.lstrip())
        if run_indent is not None and regel.strip() and inspringing <= run_indent:
            run_indent = None
        if run_indent is not None and '${{' in regel:
            raise SystemExit(f'{name}:{nummer}: workflowexpressie in run-blok')
        if re.match(r'^\s*run:\s*[>|][+-]?\s*$', regel):
            run_indent = inspringing
        elif re.match(r'^\s*run:.*\$\{\{', regel):
            raise SystemExit(f'{name}:{nummer}: workflowexpressie in korte run')
PY
then
  pass "geen workflowexpressie staat in een run-blok"
else
  fail "een run-blok bevatte een workflowexpressie"
fi

# ---------------------------------------------------------------------------
# Lovable-profiel: bun met vaste lockfile, alleen .output/public, bouwen op verzoek.
# Optioneel: LOVABLE_FIXTURE=<kopie van een Lovable-project> gebruikt de echte uitvoer van dat project
# (.output/public en .output/server). Zonder die variabele maakt de proef een kleine eigen fixture.
printf '\n== Tegenproef bouwlaag: Lovable-profiel ==\n\n'
WF="$HERE/../workflow/build-and-publish.yml"

lovable_manifest() {
  python3 -I - "$@" <<'PY2'
import json, sys
m = {"organisation":"org_00001","project":"prj_00001","module":"mod_00001","plan":"websites-1",
     "package":"ghcr.io/notift/mod_00001",
     "build":{"$commentaar":"proef","profile":"lovable","manager":"bun","bun":"1.4.4",
              "command":"bun run build","output":".output/public","node":"22"},
     "searchable":True,"allowed_public_keys":[]}
for wijziging in sys.argv[2:]:
    pad, waarde = wijziging.split("=", 1)
    if waarde in ("<weg>", "\"<weg>\""):
        m["build"].pop(pad, None)
    else:
        m["build"][pad] = json.loads(waarde)
json.dump(m, open(sys.argv[1], "w"))
PY2
}

lovable_manifest "$WORK/lovable.json"
if UIT="$(python3 "$CHECK" --github-output "$WORK/lovable.json")" \
  && grep -qx 'manager=bun' <<< "$UIT" && grep -qx 'bun=1.4.4' <<< "$UIT" \
  && grep -qx 'output=.output/public' <<< "$UIT" && grep -qx 'profile=lovable' <<< "$UIT" \
  && grep -qx 'trigger=manual' <<< "$UIT" && grep -qx 'install_mode=none' <<< "$UIT" \
  && grep -qx 'install_packages=' <<< "$UIT" && ! grep -q '^install_scripts=' <<< "$UIT" \
  && grep -qx 'cache=' <<< "$UIT"; then
  pass "lovable-manifest: bun 1.4.4, .output/public, op verzoek, geen install-scripts, geen cache"
else
  fail "lovable-manifest gaf niet de verwachte uitvoer"
fi

UIT="$(python3 "$CHECK" --github-output "$WORK/goed.json" 2>/dev/null)"
if grep -qx 'trigger=push' <<< "$UIT" && grep -qx 'install_mode=legacy-all' <<< "$UIT" && grep -qx 'install_packages=' <<< "$UIT" && grep -qx 'profile=static' <<< "$UIT" && grep -qx 'cache=npm' <<< "$UIT"; then
  pass "een bestaand manifest bouwt ongewijzigd: op push, install-scripts zoals voorheen, npm-cache"
else
  fail "een bestaand manifest veranderde van gedrag"
fi

# weiger_manifest <beschrijving> <verwachte reden> <wijziging>...: weigert, en om de goede reden.
weiger_manifest() {
  local wat="$1" reden="$2"; shift 2
  lovable_manifest "$WORK/l.json" "$@"
  if FOUTTEKST="$(python3 "$CHECK" --github-output "$WORK/l.json" 2>&1 >/dev/null)"; then
    fail "$wat werd geaccepteerd"
  elif grep -qF -- "$reden" <<< "$FOUTTEKST"; then
    pass "$wat geweigerd: $FOUTTEKST"
  else
    fail "$wat geweigerd om een andere reden: $FOUTTEKST"
  fi
}
weiger_manifest "onbekende pakketmanager deno" "'build.manager' heeft ongeldige vorm: deno" \
  'profile="static"' 'bun="<weg>"' 'manager="deno"' 'command="npm run build"'
weiger_manifest "profiel lovable met npm" "profiel lovable bouwt met bun" \
  'bun="<weg>"' 'manager="npm"' 'command="npm run build"'
weiger_manifest "profiel lovable met uitvoer dist" "zet build.output op .output/public" 'output="dist"'
weiger_manifest "profiel lovable met de hele .output (servermap erin)" "zet build.output op .output/public" 'output=".output"'
weiger_manifest "bun zonder versie" "'build.bun' ontbreekt" 'bun="<weg>"'
weiger_manifest "bun latest" "'build.bun' heeft ongeldige vorm: latest" 'bun="latest"'
weiger_manifest "bun als bereik" "'build.bun' heeft ongeldige vorm: 1.x" 'bun="1.x"'
weiger_manifest "bun met een npm-commando" "moet bij manager bun beginnen" 'command="npm run build"'
weiger_manifest "onbekend profiel" "'build.profile' heeft ongeldige vorm: nextjs" 'profile="nextjs"'
weiger_manifest "onbekende trigger" "'build.trigger' heeft ongeldige vorm: schedule" 'trigger="schedule"'
weiger_manifest "install_scripts all, uitdrukkelijk" "is 'none' of een lijst" 'install_scripts="all"'
weiger_manifest "een opt-in-lijst bij bun" "kan nog niet bij bun" 'install_scripts=["esbuild"]'
weiger_manifest "een onbekende sleutel (tikfout)" "kent deze sleutel niet: instal_scripts" 'instal_scripts="none"'
weiger_manifest "uitvoer in .git" "gewone relatieve map" \
  'profile="static"' 'bun="<weg>"' 'manager="npm"' 'command="npm run build"' 'output=".git/x"'

# Opt-in bij npm: alleen pakketten op de lijst van Notift (install-scripts-allowed.txt, begint leeg), en
# alleen echte pakketnamen. De volledige installproef staat in install-deps-proof.sh.
python3 -I - "$WORK/goed.json" "$WORK/optin.json" '["esbuild","@swc/core"]' <<'PY2'
import json, sys
m = json.load(open(sys.argv[1])); m["build"]["install_scripts"] = json.loads(sys.argv[3]); json.dump(m, open(sys.argv[2], "w"))
PY2
if python3 "$CHECK" --github-output "$WORK/optin.json" >/dev/null 2>&1; then
  fail "een opt-in buiten de lijst van Notift werd geaccepteerd"
else
  pass "een opt-in buiten de lijst van Notift geweigerd"
fi
for slecht in '["*"]' '["esbuild; id"]' '["../x"]' '[]' '["a","a"]' '["a","b","c","d","e","f","g","h","i","j","k"]'; do
  python3 -I - "$WORK/goed.json" "$WORK/optin.json" "$slecht" <<'PY2'
import json, sys
m = json.load(open(sys.argv[1])); m["build"]["install_scripts"] = json.loads(sys.argv[3]); json.dump(m, open(sys.argv[2], "w"))
PY2
  if python3 "$CHECK" --github-output "$WORK/optin.json" >/dev/null 2>&1; then fail "opt-in $slecht werd geaccepteerd"; else pass "opt-in $slecht geweigerd"; fi
done

# Installeren: de echte opdrachten, zonder netwerk (NOTIFT_DRY_RUN).
INSTALL="$HERE/install_deps.sh"
mkdir -p "$WORK/inst-bun" "$WORK/inst-npm" "$WORK/inst-leeg"
: > "$WORK/inst-bun/bun.lock"; : > "$WORK/inst-npm/package-lock.json"
dry() { (cd "$1" && MANAGER="$2" INSTALL_MODE="$3" INSTALL_PACKAGES="${4:-}" NOTIFT_DRY_RUN=1 bash "$INSTALL" 2>&1); }
[ "$(dry "$WORK/inst-bun" bun none)" = "bun install --frozen-lockfile --ignore-scripts" ] \
  && pass "bun installeert met vaste lockfile en zonder install-scripts" || fail "bun-installatie wijkt af"
dry "$WORK/inst-leeg" bun none >/dev/null && fail "bun zonder bun.lock werd geinstalleerd" || pass "bun zonder bun.lock geweigerd"
dry "$WORK/inst-bun" bun legacy-all >/dev/null && fail "bun met install-scripts werd uitgevoerd" || pass "bun met install-scripts geweigerd"
[ "$(dry "$WORK/inst-npm" npm none)" = "npm ci --ignore-scripts" ] && pass "npm none: npm ci --ignore-scripts" || fail "npm none wijkt af"
[ "$(dry "$WORK/inst-npm" npm legacy-all)" = "npm ci" ] && pass "npm bestaand: npm ci zoals voorheen" || fail "npm bestaand wijkt af"
dry "$WORK/inst-npm" npm named esbuild >/dev/null && fail "npm opt-in buiten de lijst van Notift liep door" || pass "npm opt-in buiten de lijst van Notift geweigerd bij installeren"
dry "$WORK/inst-npm" deno none >/dev/null && fail "onbekende manager werd geinstalleerd" || pass "onbekende manager geweigerd bij installeren"
dry "$WORK/inst-npm" npm named 'x;id' >/dev/null && fail "shellvorm in opt-in liep door" || pass "shellvorm in opt-in geweigerd bij installeren"
(cd "$WORK/inst-npm" && MANAGER=npm INSTALL_SCRIPTS=all NOTIFT_DRY_RUN=1 bash "$INSTALL" >/dev/null 2>&1) \
  && fail "de oude INSTALL_SCRIPTS werd nog gelezen" || pass "de oude INSTALL_SCRIPTS weigert luid"

# ---------------------------------------------------------------------------
# From here: the boundary between job 1 and job 2 (Codex audit 25 November 2026, findings 1, 2, 3, 6, 7, 12).
# Every case runs the real script or the real run block from the workflow; a refused fixture makes this red.
# Portable: no stat -f/-c, no sed -i, no shasum; cmp, find, ln, mkfifo and python3 -I only.
STAGE="$HERE/stage_output.py"
TRANSFER="$HERE/transfer.py"
POLICY="$HERE/publish_policy.py"
LOVABLE="$HERE/check_lovable.py"
LAYER="$(cd "$HERE/.." && pwd)"

# expect_rc <expected rc> <description> <command...>: runs the command, the exit code must match.
expect_rc() {
  local want="$1" wat="$2"; shift 2
  local rc=0
  "$@" >"$WORK/last.out" 2>"$WORK/last.err" || rc=$?
  if [ "$rc" = "$want" ]; then pass "$wat"; else fail "$wat (exit $rc, verwacht $want): $(tr '\n' ' ' < "$WORK/last.err" | cut -c1-200)"; fi
}
# expect_refused <description> <expected reason> <command...>: exit 1, and for the stated reason.
expect_refused() {
  local wat="$1" reden="$2"; shift 2
  local rc=0
  "$@" >"$WORK/last.out" 2>"$WORK/last.err" || rc=$?
  if [ "$rc" != 1 ]; then fail "$wat werd niet geweigerd (exit $rc)"
  elif grep -qF -- "$reden" "$WORK/last.err"; then pass "$wat geweigerd"
  else fail "$wat geweigerd om een andere reden: $(tr '\n' ' ' < "$WORK/last.err" | cut -c1-200)"; fi
}

# The run block of a step by its name, without a YAML library (as forms-embed-proof.sh does).
step_run() {
  python3 -I - "$WF" "$1" <<'PY2'
import re, sys
lines = open(sys.argv[1]).read().split('\n')
start = [i for i, l in enumerate(lines) if re.match(r'^\s*- name: ' + re.escape(sys.argv[2]) + r'\s*$', l)]
if len(start) != 1:
    raise SystemExit(f"step {sys.argv[2]!r} found {len(start)} times")
run = next(i for i in range(start[0] + 1, len(lines)) if re.match(r'^\s*run: \|\s*$', lines[i]))
indent, out = None, []
for l in lines[run + 1:]:
    if l.strip() == '':
        out.append(''); continue
    cur = len(l) - len(l.lstrip())
    if indent is None: indent = cur
    if cur < indent: break
    out.append(l[indent:])
print('\n'.join(out).rstrip())
PY2
}

# ---------------------------------------------------------------------------
printf '\n== Job 1: alleen build.output wordt klaargezet ==\n\n'
PROJ="$WORK/lproj"
SRC="$WORK/lsrc"
if [ -n "${LOVABLE_FIXTURE:-}" ]; then
  if [ -d "$LOVABLE_FIXTURE/.output/public" ] && [ -d "$LOVABLE_FIXTURE/.output/server" ]; then
    mkdir -p "$PROJ"; cp -R "$LOVABLE_FIXTURE/.output" "$PROJ/.output"
    SRC="$LOVABLE_FIXTURE"
    printf '  (fixture: %s)\n' "$LOVABLE_FIXTURE"
  else
    fail "LOVABLE_FIXTURE mist .output/public of .output/server"
    mkdir -p "$PROJ/.output/public" "$PROJ/.output/server"
  fi
else
  # A small Lovable-shaped project that follows every hosting rule (as check-lovable-proof.sh's green).
  mkdir -p "$SRC/src/routes" "$PROJ/.output/public/assets" "$PROJ/.output/public/.well-known" "$PROJ/.output/server"
  cat > "$SRC/vite.config.ts" <<'TS'
import { defineConfig } from "@lovable.dev/vite-tanstack-config";
export default defineConfig({ tanstackStart: { prerender: { enabled: true, crawlLinks: true } } });
TS
  printf 'import { Outlet } from "@tanstack/react-router";\n' > "$SRC/src/routes/__root.tsx"
  printf 'export const Route = createFileRoute("/")({ component: Home });\n' > "$SRC/src/routes/index.tsx"
  printf '{"name":"proef","devDependencies":{"@lovable.dev/vite-tanstack-config":"2.27.2"}}\n' > "$SRC/package.json"
  cat > "$PROJ/.output/public/index.html" <<'HTML'
<!doctype html>
<html lang="nl">
<head>
<meta charset="utf-8">
<title>Proef - Sportschool</title>
<meta name="description" content="Een proefpagina van de bouwlaag, met genoeg tekst om gevonden te worden.">
<link rel="canonical" href="https://example.nl/">
<link rel="stylesheet" href="/assets/app.css">
</head>
<body>
<main>
<h1>Proef</h1>
<p>Een gewone pagina met genoeg zichtbare tekst om gevonden te worden, zoals een echte statische uitvoer
van een Lovable-project. Wij trainen in De Bilt, kom langs voor een gratis proefweek.</p>
</main>
</body>
</html>
HTML
  python3 -I -c 'import sys; open(sys.argv[1], "w").write("body{margin:0}\n" * 200)' "$PROJ/.output/public/assets/app.css"
  printf 'User-agent: *\nAllow: /\n' > "$PROJ/.output/public/robots.txt"
  printf 'proef\n' > "$PROJ/.output/public/.well-known/proef.txt"
  printf 'export default {}\n' > "$PROJ/.output/server/index.mjs"
fi
printf 'SERVERGEHEIM_PROEF\n' > "$PROJ/.output/server/proef-geheim.mjs"
printf '{"preset":"cloudflare"}\n' > "$PROJ/.output/nitro.json"
printf 'verborgen\n' > "$PROJ/.output/public/.DS_Store"
mkdir -p "$PROJ/.output/public/.well-known"; printf 'proef\n' > "$PROJ/.output/public/.well-known/proef.txt"

expect_rc 0 "de uitvoermap wordt klaargezet" python3 -I "$STAGE" "$PROJ" .output/public "$WORK/stage1"
VERWACHT_N="$(cd "$PROJ/.output/public" && find . -type f ! -name .DS_Store | wc -l | tr -d ' ')"
GEKREGEN_N="$(find "$WORK/stage1" -type f | wc -l | tr -d ' ')"
if [ "$VERWACHT_N" = "$GEKREGEN_N" ] && diff -rq -x .DS_Store "$PROJ/.output/public" "$WORK/stage1" >/dev/null; then
  pass "klaargezet is precies .output/public zonder verborgen bestanden ($GEKREGEN_N bestanden)"
else
  fail "klaargezet wijkt af van .output/public"
fi
[ -f "$WORK/stage1/.well-known/proef.txt" ] && [ ! -e "$WORK/stage1/.DS_Store" ] \
  && pass "verborgen paden: .well-known/ gaat mee, .DS_Store niet" || fail "beleid voor verborgen paden klopt niet in job 1"
if grep -rq SERVERGEHEIM_PROEF "$WORK/stage1" || find "$WORK/stage1" -name 'nitro.json' -o -name 'index.mjs' -o -name 'wrangler.json' | grep -q .; then
  fail "iets uit .output/server of .output zelf kwam mee"
else
  pass "de serverbundel en .output/nitro.json komen niet mee"
fi
ln -s ../server "$PROJ/.output/public/server-link"
expect_refused "een mapverwijzing naar .output/server" "mapverwijzing" python3 -I "$STAGE" "$PROJ" .output/public "$WORK/stage2"
rm "$PROJ/.output/public/server-link"
ln -s ../server/proef-geheim.mjs "$PROJ/.output/public/geheim.js"
expect_refused "een bestandsverwijzing naar .output/server" "uit de uitvoermap wijst" python3 -I "$STAGE" "$PROJ" .output/public "$WORK/stage3"
rm "$PROJ/.output/public/geheim.js"
ln "$PROJ/.output/server/proef-geheim.mjs" "$PROJ/.output/public/geheim.js"
expect_refused "een hardlink naar de serverbundel" "hardlink" python3 -I "$STAGE" "$PROJ" .output/public "$WORK/stage3b"
rm "$PROJ/.output/public/geheim.js"
mkfifo "$PROJ/.output/public/pijp"
expect_refused "een fifo in de uitvoer" "geen gewoon bestand" python3 -I "$STAGE" "$PROJ" .output/public "$WORK/stage3c"
rm "$PROJ/.output/public/pijp"
expect_refused "een ontbrekende uitvoermap" "geen map" python3 -I "$STAGE" "$PROJ" .output/missing "$WORK/stage4"
expect_refused "een uitvoer buiten de repo" "gewone relatieve map" python3 -I "$STAGE" "$PROJ" ../x "$WORK/stage5"
mkdir -p "$WORK/elders"; ln -s "$WORK/elders" "$PROJ/via-link"
expect_refused "een uitvoer via een verwijzing" "via een verwijzing" python3 -I "$STAGE" "$PROJ" via-link "$WORK/stage6"
expect_refused "een bestaande klaarzetmap" "bestaat al" python3 -I "$STAGE" "$PROJ" .output/public "$WORK/stage1"

# ---------------------------------------------------------------------------
printf '\n== Overdracht: begrensd uitpakken, alleen gewone bestanden ==\n\n'
mkdir -m 0700 "$WORK/t1"
expect_rc 0 "job 1 pakt de klaarzetmap in als een gewoon tar-bestand" python3 -I "$TRANSFER" pack "$WORK/stage1" "$WORK/t1/site.tar"
mkdir -p "$WORK/bad"
python3 -I - "$WORK/bad" <<'PY2'
import io, os, sys, tarfile
out = sys.argv[1]

def make(name, members, fmt=tarfile.PAX_FORMAT, mode="w"):
    d = os.path.join(out, name); os.mkdir(d)
    with tarfile.open(os.path.join(d, "site.tar"), mode, format=fmt) as tf:
        for m in members:
            if isinstance(m, tuple):
                info, data = m
                tf.addfile(info, io.BytesIO(data))
            else:
                tf.addfile(m)

def reg(name, data=b"x"):
    i = tarfile.TarInfo(name); i.size = len(data); i.mode = 0o644; return (i, data)

def special(name, kind, **kw):
    i = tarfile.TarInfo(name); i.type = kind
    for k, v in kw.items(): setattr(i, k, v)
    return i

ok = reg("index.html", b"<p>x</p>")
make("symlink", [ok, special("geheim.js", tarfile.SYMTYPE, linkname="/etc/passwd")])
make("hardlink", [ok, special("geheim.js", tarfile.LNKTYPE, linkname="index.html")])
make("fifo", [ok, special("pijp", tarfile.FIFOTYPE)])
make("chardev", [ok, special("nul", tarfile.CHRTYPE, devmajor=1, devminor=3)])
make("dotdot", [ok, reg("../ontsnapt.txt")])
make("absolute", [ok, reg("/etc/ontsnapt.txt")])
make("dotsegment", [ok, reg("a/./b.txt")])
make("duplicate", [ok, reg("index.html", b"tweede")])
make("filedir", [ok, reg("a"), reg("a/b")])
make("hidden", [ok, reg(".env", b"GEHEIM=1")])
make("hiddenwk", [ok, reg(".well-known/.verborgen", b"x")])
make("dockerignore", [ok, reg(".dockerignore", b"*")])
make("control", [ok, reg("a\nb.txt")])
make("backslash", [ok, reg("a\\b.txt")])
make("count", [reg(f"f{i}.txt") for i in range(4)])
make("filesize", [ok, reg("groot.bin", b"0" * 64)])
make("total", [reg(f"f{i}.bin", b"0" * 30) for i in range(3)])
make("gzipped", [ok], mode="w:gz")
make("empty", [special("leeg", tarfile.DIRTYPE)])
make("wellknown", [ok, reg(".well-known/security-proef.txt", b"x")])
# A download folder with more than the one tar, and one whose tar is a symlink.
d = os.path.join(out, "extra"); os.mkdir(d); open(os.path.join(d, "site.tar"), "wb").close(); open(os.path.join(d, "x"), "w").close()
d = os.path.join(out, "linked"); os.mkdir(d); os.symlink(os.path.join(out, "symlink", "site.tar"), os.path.join(d, "site.tar"))
PY2
unpack_refused() { expect_refused "uitpakken: $1" "$2" env "${@:3}" python3 -I "$TRANSFER" unpack "$WORK/bad/$1" "$WORK/bad-out-$1"; }
unpack_refused symlink "verwijzing in het pakket"
unpack_refused hardlink "verwijzing in het pakket"
unpack_refused fifo "anders dan een gewoon bestand"
unpack_refused chardev "anders dan een gewoon bestand"
unpack_refused dotdot "'..'"
unpack_refused absolute "absoluut pad"
unpack_refused dotsegment "'..'"
unpack_refused duplicate "twee keer"
unpack_refused filedir "dezelfde naam"
unpack_refused hidden "alleen .well-known/ mag mee"
unpack_refused hiddenwk "alleen .well-known/ mag mee"
unpack_refused dockerignore "alleen .well-known/ mag mee"
unpack_refused control "stuurteken"
unpack_refused backslash "backslash"
unpack_refused count "meer dan 3 bestanden" NOTIFT_TRANSFER_MAX_FILES=3
unpack_refused filesize "boven 32 bytes" NOTIFT_TRANSFER_MAX_FILE_BYTES=32
unpack_refused total "samen meer dan 80 bytes" NOTIFT_TRANSFER_MAX_TOTAL_BYTES=80
unpack_refused gzipped "geen leesbaar tar-pakket"
unpack_refused empty "geen bestanden"
unpack_refused extra "precies site.tar"
unpack_refused linked "site.tar"
expect_refused "uitpakken: een limiet hoger dan de standaard" "meer dan 3 bestanden" \
  env NOTIFT_TRANSFER_MAX_FILES=3 NOTIFT_TRANSFER_MAX_DIRS=999999999 python3 -I "$TRANSFER" unpack "$WORK/bad/count" "$WORK/bad-out-count2"
if NOTIFT_TRANSFER_MAX_FILES=999999999 python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import transfer; sys.exit(0 if transfer.MAX_FILES == 10000 else 1)' "$HERE"; then
  pass "de omgeving kan een limiet alleen strenger maken"
else
  fail "de omgeving maakte een limiet ruimer"
fi
expect_rc 0 "uitpakken: .well-known/ komt door" python3 -I "$TRANSFER" unpack "$WORK/bad/wellknown" "$WORK/wk-out"
mkdir -p "$WORK/bestaat"
expect_refused "uitpakken in een bestaande map" "bestaat al" python3 -I "$TRANSFER" unpack "$WORK/bad/wellknown" "$WORK/bestaat"
if find "$WORK" -name ontsnapt.txt | grep -q . || [ -e /etc/ontsnapt.txt ]; then
  fail "een geweigerd pakket schreef iets buiten de uitpakmap"
else
  pass "een geweigerd pakket schreef niets buiten de uitpakmap"
fi

# Audit 3b, N7: every message of transfer.py that carries a name from the artifact goes through the single-line
# formatter of check_output.py. Codex's two logs (a dropped .gz and an unexpected name in the download folder),
# an OSError path and a refused name with a line break: outside the fixed annotation prefix no '::' and no '##['.
MARKER='lab::sample::mid##[audit-marker]end'
transfer_log() {  # transfer_log <description> <expected rc> <command...>
  local wat="$1" want="$2"; shift 2
  local rc=0
  "$@" >"$WORK/tl.out" 2>"$WORK/tl.err" || rc=$?
  if [ "$rc" = "$want" ] && python3 -I - "$WORK/tl.out" "$WORK/tl.err" <<'PY2'
import sys
lines = [l for p in sys.argv[1:] for l in open(p, encoding="utf-8", errors="replace").read().splitlines()]
assert any(r"lab:\x3asample:\x3amid#\x23[audit-marker]end" in l for l in lines), lines
for l in lines:
    for prefix in ("::warning title=Overdracht::", "::error title=Overdracht::", "::notice title=Overdracht::"):
        if l.startswith(prefix):
            l = l[len(prefix):]
            break
    assert "::" not in l and "##[" not in l, l
PY2
  then pass "$wat"; else fail "$wat (exit $rc): $(cat "$WORK/tl.out" "$WORK/tl.err" | tr '\n' ' ' | cut -c1-300)"; fi
}
mkdir -p "$WORK/tl-gz" "$WORK/tl-dl" "$WORK/tl-nl"
printf '<!doctype html><title>x</title>' > "$WORK/tl-gz/index.html"
printf 'lokale data' > "$WORK/tl-gz/$MARKER.gz"
transfer_log "overdracht: de waarschuwing over een weggelaten .gz is inert" 0 \
  python3 -I "$TRANSFER" assemble "$WORK/tl-gz" "$WORK/tl-gz-ctx"
: > "$WORK/tl-dl/$MARKER.txt"
transfer_log "overdracht: een onverwachte naam in de downloadmap is inert" 1 \
  python3 -I "$TRANSFER" unpack "$WORK/tl-dl" "$WORK/tl-dl-out"
transfer_log "overdracht: het pad van een OSError is inert" 1 \
  python3 -I "$TRANSFER" unpack "$WORK/bad/wellknown" "$WORK/geen-$MARKER/uit"
printf '<!doctype html><title>x</title>' > "$WORK/tl-nl/index.html"
python3 -I -c 'import sys; open(sys.argv[1] + "/" + sys.argv[2] + "\n::error::regel.gz", "w").close()' "$WORK/tl-nl" "$MARKER"
transfer_log "overdracht: een geweigerde naam met een regeleinde blijft één inerte regel" 1 \
  python3 -I "$TRANSFER" assemble "$WORK/tl-nl" "$WORK/tl-nl-ctx"

# ---------------------------------------------------------------------------
printf '\n== Job 2 nagespeeld: verse map, eigen context, keuring op wat naar Docker gaat ==\n\n'
lovable_manifest "$WORK/lovable.json"
RT="$WORK/runner-temp"; mkdir -p "$RT/notift-transfer/in"
cp "$WORK/t1/site.tar" "$RT/notift-transfer/in/site.tar"
# Plant what a client build might leave: a gzip that would be served instead of the checked file, and
# files in the paths reserved for Notift.
mkdir -p "$WORK/stage1/assets"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("p{margin:0}\n" * 200)' "$WORK/stage1/assets/proef-groot.css"
printf 'body{color:red}\n' | gzip -9 > "$WORK/stage1/assets/proef-groot.css.gz"
mkdir -p "$WORK/stage1/_notift/embed"; printf 'window.__evil=1;\n' > "$WORK/stage1/_notift/embed/forms.js"
printf 'nep\n' > "$WORK/stage1/_health"
rm -f "$RT/notift-transfer/in/site.tar"
expect_rc 0 "job 1 pakt ook geplante bestanden in (job 2 moet ze weghalen)" python3 -I "$TRANSFER" pack "$WORK/stage1" "$RT/notift-transfer/in/site.tar"
CTX="$RT/.notift-context"
expect_rc 0 "job 2 pakt uit in een verse map" python3 -I "$TRANSFER" unpack "$RT/notift-transfer/in" "$RT/notift-transfer/site"
expect_rc 0 "job 2 stelt een eigen bouwcontext samen" python3 -I "$TRANSFER" assemble "$RT/notift-transfer/site" "$CTX"
grep -q 'proef-groot.css.gz' "$WORK/last.err" && pass "een .gz van de build wordt gemeld en weggelaten" || fail "geen melding over de .gz van de build"
expect_refused "een bestaande bouwcontext" "bestaat al" python3 -I "$TRANSFER" assemble "$RT/notift-transfer/site" "$CTX"
expect_rc 0 "check_output.py keurt de map die naar Docker gaat goed" python3 -I "$CHECK" "$CTX/site" "$WORK/lovable.json"
if [ -f "$LOVABLE" ]; then
  expect_rc 0 "check_lovable.py keurt dezelfde map goed, alleen de uitvoer (job 2 leest geen bron)" \
    python3 -I "$LOVABLE" --output-only --output "$CTX/site"
else
  fail "check_lovable.py ontbreekt in de bouwlaag"
fi
( cd "$RT" && BUILD_LAYER_DIR="$LAYER" bash -c "$(step_run 'De redirects van de site')" ) >/dev/null 2>&1 \
  && pass "workflowstap: redirects" || fail "workflowstap redirects faalde"
( cd "$RT" && BUILD_LAYER_DIR="$LAYER" bash -c "$(step_run 'Het formulierscript van het platform')" ) >/dev/null 2>&1 \
  && pass "workflowstap: formulierscript" || fail "workflowstap formulierscript faalde"
( cd "$RT" && bash -c "$(step_run 'Vooraf comprimeren')" ) >/dev/null 2>&1 \
  && pass "workflowstap: vooraf comprimeren" || fail "workflowstap comprimeren faalde"
printf '20261125-1200-abcdef0' > "$CTX/site/_health"
install -m 0644 "$LAYER/base/site.Dockerfile" "$CTX/Dockerfile"
expect_rc 0 "de bouwcontext is precies Dockerfile, redirects.map en site/" python3 -I "$TRANSFER" verify-context "$CTX"
if [ -f "$CTX/site/assets/proef-groot.css.gz" ] && python3 -I -c 'import gzip, sys; sys.exit(gzip.open(sys.argv[1]).read() != open(sys.argv[2], "rb").read())' "$CTX/site/assets/proef-groot.css.gz" "$CTX/site/assets/proef-groot.css"; then
  pass "de .gz is gemaakt door job 2, uit het gekeurde bestand, niet die van de build"
else
  fail "de .gz is niet de gecomprimeerde vorm van het gekeurde bestand"
fi
cmp -s "$LAYER/embed/forms.js" "$CTX/site/_notift/embed/forms.js" && pass "/_notift/ komt uit de bouwlaag" || fail "/_notift/ komt niet uit de bouwlaag"
[ -f "$CTX/site/.well-known/proef.txt" ] && pass ".well-known/ zit in het image" || fail ".well-known/ ontbreekt in het image"
[ ! -e "$CTX/site/.DS_Store" ] && [ "$(cat "$CTX/site/_health")" = 20261125-1200-abcdef0 ] \
  && pass "geen verborgen bestand, en _health is van job 2" || fail "verborgen bestand of _health van de klant"
# The client bytes in the image are exactly the checked ones: same set, same content.
if python3 -I - "$RT/notift-transfer/site" "$CTX/site" <<'PY2'
import filecmp, os, sys
src, ctx = sys.argv[1], sys.argv[2]
def files(root):
    out = set()
    for d, _, names in os.walk(root):
        for n in names:
            out.add(os.path.relpath(os.path.join(d, n), root))
    return out
ours = lambda r: r.endswith(".gz") or r.startswith("_notift/") or r in ("_health", "_redirects")
a = {r for r in files(src) if not ours(r)}
b = {r for r in files(ctx) if not ours(r)}
assert a == b, (a ^ b)
for r in a:
    assert filecmp.cmp(os.path.join(src, r), os.path.join(ctx, r), shallow=False), r
PY2
then pass "de klantbestanden in de context zijn byte voor byte de gekeurde"; else fail "de context wijkt af van de gekeurde bestanden"; fi

# The context check itself must refuse what Docker could otherwise read.
cp -R "$CTX" "$WORK/ctx-a"; printf '*\n' > "$WORK/ctx-a/.dockerignore"
expect_refused "context: een .dockerignore" "iets anders dan Dockerfile" python3 -I "$TRANSFER" verify-context "$WORK/ctx-a"
cp -R "$CTX" "$WORK/ctx-b"; ln -s /etc/passwd "$WORK/ctx-b/site/passwd.txt"
expect_refused "context: een symlink in site/" "verwijzing" python3 -I "$TRANSFER" verify-context "$WORK/ctx-b"
cp -R "$CTX" "$WORK/ctx-c"; ln "$WORK/ctx-c/site/index.html" "$WORK/ctx-c/site/kopie.html"
expect_refused "context: een hardlink in site/" "hardlink" python3 -I "$TRANSFER" verify-context "$WORK/ctx-c"
cp -R "$CTX" "$WORK/ctx-d"; printf 'body{color:red}\n' | gzip -9 > "$WORK/ctx-d/site/assets/proef-groot.css.gz"
expect_refused "context: een .gz die niet bij zijn buur hoort" "gecomprimeerde vorm" python3 -I "$TRANSFER" verify-context "$WORK/ctx-d"
cp -R "$CTX" "$WORK/ctx-e"; rm "$WORK/ctx-e/site/_health"
expect_refused "context: zonder _health" "_health ontbreekt" python3 -I "$TRANSFER" verify-context "$WORK/ctx-e"
cp -R "$CTX" "$WORK/ctx-f"; printf 'x' > "$WORK/ctx-f/site/.env"
expect_refused "context: een verborgen bestand" "verborgen pad" python3 -I "$TRANSFER" verify-context "$WORK/ctx-f"

# A tampered job 1 that sends Lovable storage past its own check: job 2's Lovable check refuses it.
if [ -f "$LOVABLE" ]; then
  cp -R "$WORK/stage1" "$WORK/stage-boos"
  printf '{"url":"https://example.lovable.app/x.png"}\n' > "$WORK/stage-boos/assets/foto.asset.json"
  mkdir -p "$WORK/rt-boos/notift-transfer/in"
  python3 -I "$TRANSFER" pack "$WORK/stage-boos" "$WORK/rt-boos/notift-transfer/in/site.tar" >/dev/null 2>&1
  python3 -I "$TRANSFER" unpack "$WORK/rt-boos/notift-transfer/in" "$WORK/rt-boos/notift-transfer/site" >/dev/null 2>&1
  python3 -I "$TRANSFER" assemble "$WORK/rt-boos/notift-transfer/site" "$WORK/rt-boos/.notift-context" >/dev/null 2>&1
  expect_rc 1 "job 2: Lovable-opslag die job 1 doorliet, weigert in de Lovable-keuring van job 2" \
    python3 -I "$LOVABLE" --output-only --output "$WORK/rt-boos/.notift-context/site"
fi

# ---------------------------------------------------------------------------
printf '\n== Beleid: welke run mag publiceren, en met welke gegevens ==\n\n'
REPO="$WORK/beleid-repo"; mkdir -p "$REPO"
cp "$WORK/goed.json" "$REPO/static.json"
lovable_manifest "$REPO/lovable.json"
lovable_manifest "$REPO/lovable-push.json" 'trigger="push"'
gate() { # gate <expected go> <description> <manifest> <event> <ref> [policy]
  local want="$1" wat="$2" m="$3" ev="$4" ref="$5" pol="${6:-}" uit rc=0
  uit="$(EVENT="$ev" REF="$ref" POLICY="$pol" python3 -I "$POLICY" gate "$REPO" "$m" 2>/dev/null)" || rc=$?
  if [ "$rc" = 0 ] && [ "$uit" = "go=$want" ]; then pass "job 1: $wat: go=$want"; else fail "job 1: $wat: exit $rc, '$uit', verwacht go=$want"; fi
}
publish() { # publish <description> <manifest> <event> <ref> [policy] (env COMMIT/RUN_ID/RUN_ATTEMPT from caller)
  local wat="$1" m="$2" ev="$3" ref="$4" pol="${5:-}"
  expect_refused "job 2: $wat" "Publicatiebeleid" env EVENT="$ev" REF="$ref" POLICY="$pol" \
    COMMIT=0123456789abcdef0123456789abcdef01234567 RUN_ID=42 RUN_ATTEMPT=1 python3 -I "$POLICY" publish "$REPO" "$m"
}
MAIN=refs/heads/main
gate true  "bestaande site, push op main" static.json push "$MAIN"
gate true  "bestaande site, handmatig op main" static.json workflow_dispatch "$MAIN"
gate false "bestaande site, push op een neventak" static.json push refs/heads/feature
gate false "bestaande site, pull_request" static.json pull_request "$MAIN"
gate false "lovable op verzoek, push op main" lovable.json push "$MAIN"
gate true  "lovable op verzoek, handmatig op main" lovable.json workflow_dispatch "$MAIN"
gate false "lovable, handmatig op een neventak" lovable.json workflow_dispatch refs/heads/lovable-sync
gate false "beleid lovable-on-request wint van trigger push in het manifest" lovable-push.json push "$MAIN" lovable-on-request
gate true  "beleid lovable-on-request, handmatig op main" lovable-push.json workflow_dispatch "$MAIN" lovable-on-request
gate true  "zonder beleid beslist het manifest (DWY variant A met trigger push)" lovable-push.json push "$MAIN"
expect_refused "job 1: beleid lovable-on-request met een static-manifest" "beleid van deze repo is lovable-on-request" \
  env EVENT=workflow_dispatch REF="$MAIN" POLICY=lovable-on-request python3 -I "$POLICY" gate "$REPO" static.json
# Audit 2, finding N2: a manifest over 64 KiB is refused before parsing, in both readers.
# Finding N7: client text in a refusal (here a manifest key with a line break and '::') stays one inert line.
python3 -I - "$REPO" <<'PY2'
import json, sys
repo = sys.argv[1]
m = json.load(open(f"{repo}/lovable.json"))
m["build"]["x\n::error title=Injected::manifest key"] = 1
m["build"]["k::warning::midden ##[error]sleutel"] = 1  # audit 3, N7: both syntaxes mid-line
json.dump(m, open(f"{repo}/inject.json", "w"))
big = json.load(open(f"{repo}/lovable.json"))
big["build"]["$commentaar"] = "x" * (70 * 1024)
json.dump(big, open(f"{repo}/big.json", "w"))
PY2
expect_refused "publish_policy.py: een manifest boven 64 KiB" "groter dan 64 KiB" \
  env EVENT=workflow_dispatch REF="$MAIN" python3 -I "$POLICY" gate "$REPO" big.json
expect_refused "check_output.py --github-output: een manifest boven 64 KiB" "groter dan 64 KiB" \
  python3 -I "$CHECK" --github-output "$REPO/big.json"
expect_refused "check_output.py: een manifest boven 64 KiB" "groter dan 64 KiB" \
  python3 -I "$CHECK" "$WORK/stage1" "$REPO/big.json"
inert() {  # inert <description> <allowed annotation prefix> <command...>: exit 1, no client text starts a line
  local wat="$1" prefix="$2" rc=0 uit; shift 2
  uit="$(GITHUB_ACTIONS=true "$@" 2>&1)" || rc=$?
  if [ "$rc" = 1 ] && ! grep -v "^$prefix" <<< "$uit" | grep -q '^::' \
      && ! sed "s/^$prefix//" <<< "$uit" | grep -qF '::' && ! grep -qF '##[' <<< "$uit" \
      && grep -qF 'x\x0a:\x3aerror title=Injected:\x3amanifest key' <<< "$uit" \
      && grep -qF 'k:\x3awarning:\x3amidden #\x23[error]sleutel' <<< "$uit" && ! grep -q '^Traceback' <<< "$uit"; then
    pass "$wat: sleutels met regelovergang, '::warning::' en '##[error]' blijven data op één regel"
  else
    fail "$wat: klanttekst begon een eigen logregel of werd niet getoond (exit $rc): $(tr '\n' '|' <<< "$uit" | cut -c1-300)"
  fi
}
inert "publish_policy.py gate" "::error title=Publicatiebeleid::" \
  env EVENT=workflow_dispatch REF="$MAIN" python3 -I "$POLICY" gate "$REPO" inject.json
inert "check_output.py" "::error title=Controle van de uitvoer::" python3 -I "$CHECK" "$WORK/stage1" "$REPO/inject.json"
expect_refused "job 1: onbekend beleid" "onbekend beleid" \
  env EVENT=push REF="$MAIN" POLICY=alles python3 -I "$POLICY" gate "$REPO" static.json
publish "push op een neventak" static.json push refs/heads/feature
publish "een handmatige start op een neventak" lovable.json workflow_dispatch refs/heads/feature
publish "push bij op verzoek" lovable.json push "$MAIN"
publish "push bij beleid lovable-on-request" lovable-push.json push "$MAIN" lovable-on-request
publish "pull_request" static.json pull_request "$MAIN"
publish "beleid lovable-on-request met een static-manifest" static.json workflow_dispatch "$MAIN" lovable-on-request
publish "een manifestpad met .." ../static.json push "$MAIN"
publish "een manifestpad dat geen .json is" static.txt push "$MAIN"
ln -s static.json "$REPO/link.json"
publish "een manifest dat een symlink is" link.json push "$MAIN"
python3 -I - "$REPO/static.json" "$REPO/ander-pakket.json" <<'PY2'
import json, sys
m = json.load(open(sys.argv[1])); m["package"] = "ghcr.io/notift/mod_00002"; json.dump(m, open(sys.argv[2], "w"))
PY2
publish "een pakket dat niet bij de module hoort" ander-pakket.json push "$MAIN"
expect_refused "job 2: een ongeldige commit" "geen volledige commit" env EVENT=push REF="$MAIN" COMMIT=abc RUN_ID=42 RUN_ATTEMPT=1 \
  python3 -I "$POLICY" publish "$REPO" static.json
# PACKAGE, MODULE and BUILD as a tampered job 1 might hand them over: job 2 must not read any of them.
pub() { PACKAGE=ghcr.io/notift/mod_99999 MODULE=mod_99999 BUILD=nep TAG=nep \
  EVENT=workflow_dispatch REF="$MAIN" POLICY=lovable-on-request COMMIT=0123456789abcdef0123456789abcdef01234567 \
  NOTIFT_BUILD_TIME=20261125-1200 RUN_ID="$1" RUN_ATTEMPT="$2" python3 -I "$POLICY" publish "$REPO" lovable.json 2>/dev/null; }
UIT1="$(pub 42 1)"; UIT2="$(pub 42 2)"; UIT3="$(pub 43 1)"
if grep -qx 'package=ghcr.io/notift/mod_00001' <<< "$UIT1" && grep -qx 'module=mod_00001' <<< "$UIT1" \
  && grep -qx 'profile=lovable' <<< "$UIT1" && grep -qx 'build=20261125-1200-0123456' <<< "$UIT1" \
  && grep -qx 'tag=20261125-1200-0123456-42-1' <<< "$UIT1"; then
  pass "job 2 leest module, pakket, profiel en buildnummer zelf uit zijn eigen manifest"
else
  fail "job 2 gaf niet de verwachte publicatiegegevens: $(tr '\n' ' ' <<< "$UIT1")"
fi
T1="$(grep '^tag=' <<< "$UIT1")"; T2="$(grep '^tag=' <<< "$UIT2")"; T3="$(grep '^tag=' <<< "$UIT3")"
[ -n "$T1" ] && [ "$T1" != "$T2" ] && [ "$T1" != "$T3" ] && [ "$T2" != "$T3" ] \
  && pass "zelfde commit en minuut: elke run en poging een eigen tag" || fail "twee runs kregen dezelfde tag"

# ---------------------------------------------------------------------------
printf '\n== Lovable-sync: waarschuwen, nooit falen ==\n\n'
SYNC="$HERE/warn_lovable_sync.sh"
git init -q --bare "$WORK/remote.git"
git init -q "$WORK/kloon"; git -C "$WORK/kloon" remote add origin "$WORK/remote.git"
git -C "$WORK/kloon" -c user.email=p@p -c user.name=p commit -q --allow-empty -m proef
git -C "$WORK/kloon" push -q origin HEAD:refs/heads/main HEAD:refs/heads/not-lovable-sync
RC=0; UIT="$(GITHUB_STEP_SUMMARY="$WORK/samenvatting.md" bash "$SYNC" "$WORK/kloon")" || RC=$?
[ "$RC" = 0 ] && [ -z "$UIT" ] && pass "zonder lovable-sync-tak geen melding (not-lovable-sync telt niet)" || fail "melding zonder lovable-sync-tak"
git -C "$WORK/kloon" push -q origin HEAD:refs/heads/lovable-sync HEAD:refs/heads/lovable-sync-1764061234 \
  HEAD:refs/heads/lovable-syncX HEAD:refs/heads/lovable-sync.2 'HEAD:refs/heads/lovable-sync-a|b'
RC=0; UIT="$(GITHUB_STEP_SUMMARY="$WORK/samenvatting.md" bash "$SYNC" "$WORK/kloon")" || RC=$?
if [ "$RC" = 0 ] && grep -q '^::warning title=Lovable-sync::5 ' <<< "$UIT" \
  && grep -q 'lovable-sync-1764061234' "$WORK/samenvatting.md" && grep -q '`lovable-sync`' "$WORK/samenvatting.md" \
  && grep -q '`lovable-syncX`' "$WORK/samenvatting.md" && grep -q '`lovable-sync.2`' "$WORK/samenvatting.md" \
  && grep -q '`lovable-sync-a?b`' "$WORK/samenvatting.md" && ! grep -q 'a|b' "$WORK/samenvatting.md"; then
  pass "elke tak lovable-sync* geeft een waarschuwing, de naam veilig in de tabel, exit 0"
else
  fail "lovable-sync*-takken gaven niet de verwachte waarschuwing"
fi
git -C "$WORK/kloon" remote set-url origin "$WORK/bestaat-niet.git"
GITHUB_STEP_SUMMARY="$WORK/samenvatting.md" bash "$SYNC" "$WORK/kloon" >/dev/null 2>&1 \
  && pass "een mislukte opvraag stopt de build niet" || fail "een mislukte opvraag stopte de build"

# ---------------------------------------------------------------------------
printf '\n== De workflow zelf ==\n\n'
if WF_FOUT="$(python3 -I - "$WF" <<'PY2' 2>&1
import re, sys
tekst = open(sys.argv[1]).read()
job1, job2 = tekst.split("\n  publiceren:\n", 1)
job1 = job1.split("\n  bouwen:\n", 1)[1]

def steps(job):
    parts = re.split(r"\n      - name: ", job)[1:]
    return [(p.split("\n", 1)[0], p) for p in parts]

s1, s2 = steps(job1), steps(job2)
n1, n2 = [n for n, _ in s1], [n for n, _ in s2]
d1, d2 = dict(s1), dict(s2)

# Finding 1: job 2 takes nothing from job 1 but the go flag; the build layer comes from GitHub's job context.
uses = set(re.findall(r"needs\.bouwen\.outputs\.([a-z_]+)", job2))
assert uses == {"go"}, f"job 2 leest uitvoer van job 1: {sorted(uses - {'go'})}"
outs1 = job1.split("    steps:", 1)[0].split("    outputs:", 1)[1]
assert re.findall(r"^      ([a-z_]+):", outs1, re.M) == ["go"], "job 1 geeft meer door dan go"
assert "ls-remote" not in tekst and "refs/tags/v1" not in tekst, "de bouwlaag wordt nog uit een tag opgelost"
for d in (d1, d2):
    blok = d["De vaste bouwlaag ophalen"]
    assert "WORKFLOW_SHA: ${{ job.workflow_sha }}" in blok and "WORKFLOW_REPOSITORY: ${{ job.workflow_repository }}" in blok
    assert '[ "$WORKFLOW_REPOSITORY" = notift/build ]' in blok
assert d1["De vaste bouwlaag ophalen"].split("run: |", 1)[1] == d2["De vaste bouwlaag ophalen"].split("run: |", 1)[1], "de bouwlaagstap verschilt tussen de jobs"
assert n2[0] == "De vaste bouwlaag ophalen", "job 2 doet iets voor hij de bouwlaag heeft"
pub = d2["Publiceren"]
assert "needs." not in pub and "steps.beleid.outputs.tag" in pub and "WORKFLOW=notift/build@${{ steps.bouwlaag.outputs.sha }}" in pub
assert 'publish_policy.py" publish "$GITHUB_WORKSPACE/source" "$MANIFEST_PATH"' in d2["Beleid en publicatiegegevens"]
for v in ("POLICY: ${{ inputs.policy }}", "EVENT: ${{ github.event_name }}", "REF: ${{ github.ref }}", "COMMIT: ${{ github.sha }}"):
    assert v in d2["Beleid en publicatiegegevens"], v
# Finding 6: the same gate in job 1, from GitHub's context and the caller's policy.
assert 'publish_policy.py" gate "$GITHUB_WORKSPACE" "$MANIFEST_PATH"' in d1["Bouwen we nu"]
assert "POLICY: ${{ inputs.policy }}" in d1["Bouwen we nu"] and "REF: ${{ github.ref }}" in d1["Bouwen we nu"]
assert "\n      policy:\n" in tekst.split("\njobs:\n", 1)[0], "geen beleidsinvoer voor de aanroeper"
# Finding 2 and 3: fresh transfer folder, own unpack, own context, Lovable check in job 2 on that context.
dl = d2["Het resultaat ophalen"]
assert "name: site.tar" in dl and "path: ${{ runner.temp }}/notift-transfer/in" in dl and "skip-decompress: true" in dl
assert ".notift-context" not in dl and "GITHUB_WORKSPACE" not in dl
assert '[ ! -e "$TRANSFER_DIR" ]' in d2["Een lege overdrachtsmap"]
sam = d2["Uitpakken en de bouwcontext samenstellen"]
assert 'transfer.py" unpack "$TRANSFER_DIR/in" "$TRANSFER_DIR/site"' in sam and 'transfer.py" assemble "$TRANSFER_DIR/site" "$CONTEXT_DIR"' in sam
assert "CONTEXT_DIR: ${{ runner.temp }}/.notift-context" in sam
lk = d2["De Lovable-keuring"]
assert "if: steps.beleid.outputs.profile == 'lovable'" in lk
assert 'check_lovable.py" --output-only --output "$CONTEXT_DIR/site"' in lk
# Audit 2, finding N1: job 2 holds packages: write and must never hand the client's source tree to the check.
assert "--source" not in lk and "GITHUB_WORKSPACE" not in lk, "job 2 geeft de Lovable-keuring een bronmap"
assert 'check_output.py" "$CONTEXT_DIR/site" "$GITHUB_WORKSPACE/source/$MANIFEST_PATH"' in d2["De uitvoer opnieuw keuren"]
assert 'transfer.py" verify-context "$CONTEXT_DIR"' in d2["De bouwcontext klaarzetten"]
assert "find .notift-context/site -type f -name '*.gz' -exec rm -f {} +" in d2["Vooraf comprimeren"]
for naam in ("De redirects van de site", "Het formulierscript van het platform", "Vooraf comprimeren"):
    assert "working-directory: ${{ runner.temp }}" in d2[naam], naam
assert "context: ${{ runner.temp }}/.notift-context" in pub and "file: ${{ runner.temp }}/.notift-context/Dockerfile" in pub
volgorde = ["De vaste bouwlaag ophalen", "Alleen het manifest van het project", "Beleid en publicatiegegevens", "Een lege overdrachtsmap",
            "Het resultaat ophalen", "Uitpakken en de bouwcontext samenstellen", "De uitvoer opnieuw keuren", "De Lovable-keuring",
            "De redirects van de site", "Het formulierscript van het platform", "Vooraf comprimeren", "Het gezondheidspad stempelen",
            "De bouwcontext klaarzetten", "Inloggen bij ghcr.io", "Publiceren"]
assert [n for n in n2 if n in volgorde] == volgorde, f"volgorde job 2: {n2}"
assert "install_deps" not in job2 and "run build" not in job2 and "setup-node" not in job2 and "setup-bun" not in job2, "klantgerichte stap in job 2"
# Job 1: the transfer is one tar, packed after the checks, uploaded without zip.
up = d1["Het resultaat doorgeven"]
assert "path: ${{ runner.temp }}/notift-transfer/site.tar" in up and "archive: false" in up
assert n1.index("Alleen de uitvoermap klaarzetten") < n1.index("De uitvoer keuren") < n1.index("De Lovable-keuring") < n1.index("De overdracht inpakken") < n1.index("Het resultaat doorgeven")
assert 'check_lovable.py" --source "$GITHUB_WORKSPACE" --output "$STAGE_DIR"' in d1["De Lovable-keuring"]
na = n1.index("Bouwen we nu")
for naam in n1[na + 1:]:
    assert "if: steps.moment.outputs.go == 'true'" in d1[naam], f"stap zonder poort: {naam}"
assert n1.index("Werk van Lovable naast main") < n1.index("Pakketten installeren"), "waarschuwing na klantcode"
assert "if: needs.bouwen.outputs.go == 'true'" in job2.split("steps:", 1)[0], "job 2 zonder poort"
# Finding 7: a concurrency group per module, the event in job 1's group; nothing is cancelled while running.
assert "group: notift-build-${{ github.repository }}-${{ inputs.manifest }}-${{ github.event_name }}" in job1
assert "group: notift-publish-${{ github.repository }}-${{ inputs.manifest }}" in job2
assert tekst.count("cancel-in-progress: false") == 2 and "cancel-in-progress: true" not in tekst
assert "steps.referentie.outputs.image" in d2["Staging aan het platform melden"] and "@$DIGEST" in d2["De onveranderlijke imageverwijzing"]
PY2
)"; then
  pass "workflow: job 2 neemt alleen go van job 1, eigen bouwlaag, beleid, overdracht, context en Lovable-keuring"
else
  fail "workflowstructuur klopt niet: $WF_FOUT"
fi

# Audit 3, N1: job 2 has no checkout of the client repo at all, only the one manifest blob at the exact caller
# commit. Outside the command substitution above: bash 3.2 cannot parse unbalanced parentheses in a heredoc there.
python3 -I - "$WF" <<'PY2' && pass "workflow: job 2 heeft geen checkout van de klantrepo, alleen het manifestpad op de exacte commit" || fail "workflow: job 2 haalt meer op dan het manifest"
import re, sys
tekst = open(sys.argv[1]).read()
job2 = tekst.split("\n  publiceren:\n", 1)[1]
d2 = {p.split("\n", 1)[0]: p for p in re.split(r"\n      - name: ", job2)[1:]}
assert "actions/checkout" not in job2 and "sparse" not in job2, "job 2 haalt nog een checkout van de klantrepo op"
assert len(re.findall(r"^\s+uses: ", job2, re.M)) == 3, "job 2 kreeg een extra action"
mf = d2["Alleen het manifest van het project"]
for v in ("COMMIT: ${{ github.sha }}", "MANIFEST_PATH: ${{ inputs.manifest }}", "SOURCE_DIR: ${{ github.workspace }}/source",
          "MANIFEST_GIT_DIR: ${{ runner.temp }}/notift-manifest.git", "GH_TOKEN: ${{ github.token }}"):
    assert v in mf, v
gits = re.findall(r'git -C "\$MANIFEST_GIT_DIR" (.*)', mf)
assert gits == ["cat-file --batch-all-objects --batch-check='%(objecttype) %(objectname)' | awk '$1 == \"blob\" { print $2 }'; }",
                'remote add origin "https://github.com/$REPOSITORY.git"',
                'fetch --quiet --no-tags --depth=1 --filter=blob:none origin "$COMMIT"',
                'ls-tree --full-tree "$COMMIT" -- "$MANIFEST_PATH")"',
                'cat-file -s "$BLOB")" \\',
                'cat-file blob "$BLOB" | head -c 65536 > "$SOURCE_DIR/$MANIFEST_PATH"'], f"git-aanroepen in job 2: {gits}"
assert 'SIZE="$(ulimit -f 256 && git' in mf and '[ "$SIZE" -le 65536 ]' in mf and 'rm -rf "$MANIFEST_GIT_DIR"' in mf
# Audit 3b, N1: fail closed when the server ignores the filter, and only the manifest blob after reading it.
assert 'FETCHED="$(blobs)"\n          [ -z "$FETCHED" ] || {' in mf, "geen blobtelling direct na de gefilterde fetch"
assert '[ "$(blobs)" = "$BLOB" ] || {' in mf, "geen controle op precies de manifestblob na het lezen"
assert mf.index('[ -z "$FETCHED" ]') < mf.index("ENTRY=") and mf.index('[ "$(blobs)" = "$BLOB" ]') < mf.index("mkdir -p")
assert "git config" not in mf and "extraheader" in mf.split("run: |", 1)[1].split("git init", 1)[0], "het token staat in een bestand"
PY2
# Audit 3, N1: the real run block of job 2's manifest step, against a local repo served over file:// (the only
# change is the transport URL). On disk afterwards: the one manifest, nothing else of the client, and in the object
# store (kept for one run only, to count) exactly one blob. Links, submodule-like paths, size and path are refused.
printf '\n== Job 2: alleen het manifest, geen klantbron ==\n\n'
MF_BLOCK="$(step_run "Alleen het manifest van het project")"
GH="$WORK/gh"; KLANT="$GH/notift/klant.git"
mkdir -p "$KLANT/config" "$KLANT/src" "$KLANT/linkdir-doel"
lovable_manifest "$KLANT/config/notift.json"
printf 'export const geheim = "KLANTBRON-MARKER-7f3a";\n' > "$KLANT/src/app.ts"
printf 'KLANTBRON-MARKER-7f3a\n' > "$KLANT/README.md"
ln -s config/notift.json "$KLANT/link.json"
ln -s config "$KLANT/linkdir"
python3 -I -c 'import json,sys; json.dump({"x": "y" * (70 * 1024)}, open(sys.argv[1], "w"))' "$KLANT/groot.json"
python3 -I -c 'import os,sys; open(sys.argv[1], "wb").write(os.urandom(400 * 1024))' "$KLANT/heel-groot.json"
mkdir -p "$KLANT/map.json"; printf '{}' > "$KLANT/map.json/x.json"
git -C "$KLANT" init -q
git -C "$KLANT" add -A
git -C "$KLANT" -c user.email=p@p -c user.name=p commit -q -m proef
git -C "$KLANT" config uploadpack.allowFilter true
git -C "$KLANT" config uploadpack.allowAnySHA1InWant true
KLANT_SHA="$(git -C "$KLANT" rev-parse HEAD)"
mf_run() {  # mf_run <run-dir> <manifest path> [keep]: the workflow block, in a fresh runner-like folder
  local blok="${MF_BLOCK//https:\/\/github.com\//file://$GH/}"
  [ -n "${3:-}" ] && blok="${blok//rm -rf \"\$MANIFEST_GIT_DIR\"/:}"
  mkdir -p "$1/temp" "$1/workspace"
  printf '%s\n' "$blok" > "$1/blok.sh"
  env REPOSITORY=notift/klant COMMIT="$KLANT_SHA" MANIFEST_PATH="$2" GH_TOKEN=proeftoken \
    MANIFEST_GIT_DIR="$1/temp/notift-manifest.git" SOURCE_DIR="$1/workspace/source" \
    bash --noprofile --norc -eo pipefail "$1/blok.sh"
}
if [ "$MF_BLOCK" = "${MF_BLOCK//https:\/\/github.com\//x}" ]; then
  fail "het run-blok van de manifeststap noemt github.com niet; de proef kan de transport-URL niet vervangen"
fi
RC=0; mf_run "$WORK/mf-goed" config/notift.json keep >"$WORK/mf.out" 2>&1 || RC=$?
BLOBS="$(git -C "$WORK/mf-goed/temp/notift-manifest.git" cat-file --batch-all-objects --batch-check 2>/dev/null | awk '$2 == "blob"' | wc -l | tr -d ' ')"
OP_SCHIJF="$(cd "$WORK/mf-goed/workspace" && find . -mindepth 1 | sort | tr '\n' ' ')"
if [ "$RC" = 0 ] && [ "$OP_SCHIJF" = "./source ./source/config ./source/config/notift.json " ] \
  && cmp -s "$KLANT/config/notift.json" "$WORK/mf-goed/workspace/source/config/notift.json" && [ "$BLOBS" = 1 ] \
  && ! grep -rqa KLANTBRON-MARKER "$WORK/mf-goed"; then
  pass "job 2 haalt precies het manifest van de exacte commit op: één blob, geen ander klantbestand op schijf"
else
  fail "manifeststap: exit $RC, op schijf '$OP_SCHIJF', blobs $BLOBS: $(tr '\n' ' ' < "$WORK/mf.out" | cut -c1-300)"
fi
RC=0; mf_run "$WORK/mf-schoon" config/notift.json >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && [ ! -e "$WORK/mf-schoon/temp/notift-manifest.git" ] && [ -f "$WORK/mf-schoon/workspace/source/config/notift.json" ] \
  && pass "de objectmap van de manifeststap is na afloop weg" || fail "de objectmap bleef staan (exit $RC)"
if UIT="$(EVENT=workflow_dispatch REF=refs/heads/main COMMIT="$KLANT_SHA" RUN_ID=1 RUN_ATTEMPT=1 NOTIFT_BUILD_TIME=20261125-1200 \
    python3 -I "$POLICY" publish "$WORK/mf-schoon/workspace/source" config/notift.json 2>&1)" && grep -qx 'module=mod_00001' <<< "$UIT"; then
  pass "publish_policy.py leest het opgehaalde manifest zoals de workflow het aanroept"
else
  fail "publish_policy.py op het opgehaalde manifest: $UIT"
fi
mf_refused() {  # mf_refused <description> <manifest path> <expected reason>
  local rc=0 uit
  uit="$(mf_run "$WORK/mf-$RANDOM$RANDOM" "$2" 2>&1)" || rc=$?
  if [ "$rc" != 0 ] && grep -qF -- "$3" <<< "$uit"; then pass "manifeststap weigert $1"
  else fail "manifeststap: $1 (exit $rc): $(tr '\n' ' ' <<< "$uit" | cut -c1-300)"; fi
}
mf_refused "een manifest dat een symlink is" link.json "geen gewoon bestand (modus 120000"
mf_refused "een pad door een symlink naar een map" linkdir/notift.json "ontbreekt in deze commit"
mf_refused "een map met de naam van het manifest" map.json "geen gewoon bestand (modus 040000"
mf_refused "een manifest dat ontbreekt" bestaat-niet.json "ontbreekt in deze commit"
mf_refused "een manifest boven 64 KiB" groot.json "groter dan 64 KiB"
mf_refused "een blob boven 256 KiB, de download breekt af" heel-groot.json "niet begrensd worden opgehaald"
mf_refused "een pad met .." ../klant/config/notift.json "geen gewoon relatief .json-pad"
mf_refused "een pad dat geen .json is" src/app.ts "geen gewoon relatief .json-pad"
# Audit 3b, N1: a Git server without filter support only warns and sends every blob. The step must stop before it
# reads the manifest, with nothing of the client in source/. Then the green case once more, with the filter back on.
mf_no_source() {  # mf_no_source <description> <expected reason> <block> : refused, and no source/ written
  local rc=0 uit dir="$WORK/mf-$RANDOM$RANDOM"
  uit="$(MF_BLOCK="$3" mf_run "$dir" config/notift.json 2>&1)" || rc=$?
  if [ "$rc" != 0 ] && grep -qF -- "$2" <<< "$uit" && [ ! -e "$dir/workspace/source" ]; then pass "manifeststap weigert $1"
  else fail "manifeststap: $1 (exit $rc, source/ $(test -e "$dir/workspace/source" && echo aanwezig || echo afwezig)): $(tr '\n' ' ' <<< "$uit" | cut -c1-300)"; fi
}
git -C "$KLANT" config uploadpack.allowFilter false
mf_no_source "een Git-server zonder blobfilter (alle bestanden kwamen mee)" "paste het blobfilter niet toe" "$MF_BLOCK"
git -C "$KLANT" config uploadpack.allowFilter true
RC=0; mf_run "$WORK/mf-filter-weer" config/notift.json >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && cmp -s "$KLANT/config/notift.json" "$WORK/mf-filter-weer/workspace/source/config/notift.json" \
  && pass "met het filter weer aan haalt dezelfde stap het manifest op (exit 0)" || fail "manifeststap met filter: exit $RC"
# A second blob that arrives after the first count (here a forced lazy fetch of another client file, the only
# change to the block) must stop the step too: exactly the manifest blob, nothing more.
EXTRA_OID="$(git -C "$KLANT" rev-parse HEAD:README.md)"
MF_EXTRA="$(python3 -I -c 'import sys
b, oid = sys.argv[1], sys.argv[2]
old = "SIZE=\"$(ulimit"
assert b.count(old) == 1
sys.stdout.write(b.replace(old, "git -C \"$MANIFEST_GIT_DIR\" cat-file -s " + oid + " >/dev/null\n" + old))' "$MF_BLOCK" "$EXTRA_OID")"
mf_no_source "een tweede blob na het lezen van het manifest" "meer dan alleen die ene blob" "$MF_EXTRA"

# De echte bun-installatie, alleen als bun en een fixture er zijn. Draait klantcode niet: --ignore-scripts.
# Audit 2, finding N5: the branch gets the same input as the workflow, the install_mode and install_packages
# that check_output.py --github-output gives for the Lovable manifest, through one function. Without bun the
# same function runs dry, so a wrongly wired branch turns this proof red on every machine.
LOV_GH="$(python3 -I "$CHECK" --github-output "$WORK/lovable.json" 2>/dev/null)"
LOV_MODE="$(sed -n 's/^install_mode=//p' <<< "$LOV_GH")"
LOV_PKGS="$(sed -n 's/^install_packages=//p' <<< "$LOV_GH")"
bun_install() {  # bun_install <dir> [dry]: as the workflow step "Pakketten installeren" calls install_deps.sh
  (cd "$1" && env -u INSTALL_SCRIPTS MANAGER=bun INSTALL_MODE="$LOV_MODE" INSTALL_PACKAGES="$LOV_PKGS" \
    ${2:+NOTIFT_DRY_RUN=1} bash "$INSTALL")
}
python3 -I - "$WF" <<'PY2' && pass "workflow: de installatiestap geeft INSTALL_MODE en INSTALL_PACKAGES uit het manifest, zoals bun_install hier" || fail "de installatiestap van de workflow wijkt af van bun_install"
import re, sys
t = open(sys.argv[1]).read()
assert "INSTALL_MODE: ${{ steps.manifest.outputs.install_mode }}" in t
assert "INSTALL_PACKAGES: ${{ steps.manifest.outputs.install_packages }}" in t
assert "INSTALL_SCRIPTS" not in t
PY2
mkdir -p "$WORK/bun-droog"; : > "$WORK/bun-droog/bun.lock"
if [ "$LOV_MODE" = none ] && UIT="$(bun_install "$WORK/bun-droog" dry 2>&1)" && grep -q 'bun install --frozen-lockfile --ignore-scripts' <<< "$UIT"; then
  pass "bun-tak droog: install_mode=$LOV_MODE uit het manifest, bun install --frozen-lockfile --ignore-scripts"
else
  fail "bun-tak droog faalde met de invoer van de workflow (install_mode=$LOV_MODE): $UIT"
fi
if [ -n "${LOVABLE_FIXTURE:-}" ] && command -v bun >/dev/null 2>&1; then
  cp -R "$LOVABLE_FIXTURE" "$WORK/echt"; rm -rf "$WORK/echt/node_modules"
  bun_install "$WORK/echt" >/dev/null 2>&1 \
    && pass "echte bun install --frozen-lockfile op de fixture" || fail "echte bun install op de fixture mislukte"
else
  printf '  info echte bun-installatie overgeslagen (bun of LOVABLE_FIXTURE ontbreekt); de droge run hierboven toetst de bedrading\n'
fi

# De laag staat in deze proef buiten de projectmap. Een vaak voorkomende
# 'kopieer alles'-build kan dus alleen projectbestanden meenemen.
mkdir -p "$WORK/project" "$WORK/bouwlaag/checks" "$WORK/dist"
printf 'klant\n' > "$WORK/project/index.html"
printf 'niet van de klant\n' > "$WORK/bouwlaag/checks/proefgeheim.txt"
cp -R "$WORK/project/." "$WORK/dist/"
if find "$WORK/dist" -name proefgeheim.txt -print -quit | grep -q .; then
  fail "een brede kopie nam een bouwlaagbestand mee"
else
  pass "een brede kopie kan geen bouwlaagbestand meenemen"
fi

# release.sh copies checks/ as a whole to the public notift/build: no run may leave __pycache__ behind.
[ ! -e "$HERE/__pycache__" ] && pass "geen __pycache__ in checks/ na alle aanroepen" || fail "checks/__pycache__ is aangemaakt"

printf '\n  %s goed, %s fout\n\n' "$GOED" "$FOUT"
[ "$FOUT" -eq 0 ]
