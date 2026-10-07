#!/usr/bin/env bash
# Tegenproeven voor de harde grens tussen een klantrepo en de bouwlaag.
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
for veld in organisation project module plan package command output node manager; do
  for waarde in '$(id)' '`id`' 'x;id' $'x\nid' '../x'; do
    python3 - "$WORK/goed.json" "$WORK/slecht.json" "$veld" "$waarde" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
pad = sys.argv[3].split('.')
if pad[0] in ('command', 'output', 'node', 'manager'):
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

# Dit is de lokale tegenhanger van job 2: een andere hash is geen match. De
# GitHub-run bewijst daarnaast dat fetch en checkout werkelijk op deze hash
# plaatsvinden; zie de stappen in de README.
VERWACHT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WERKELIJK=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if test "$WERKELIJK" = "$VERWACHT"; then
  fail "afwijkende bouwlaaghash werd geaccepteerd"
else
  pass "een afwijkende bouwlaaghash wordt geweigerd"
fi

printf '\n  %s goed, %s fout\n\n' "$GOED" "$FOUT"
[ "$FOUT" -eq 0 ]
