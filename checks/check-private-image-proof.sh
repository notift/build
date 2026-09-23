#!/usr/bin/env bash
# Tegenproef voor de afschermingsmeting in ../verify.sh.
#
# static-base is met opzet een bestaand, publiek CONTAINERpakket van Notift;
# mod_00002 is het private tegenbeeld. Deze proef verandert niets bij GitHub,
# maar bewijst beide kanten van dezelfde meting: publiek moet rood, privaat
# moet op alle zes projectstappen groen zijn.
# Een apart script is hier helderder dan een geval in check-output-proof.sh:
# die test een lokale Python-keuring en praat uitdrukkelijk met niets; deze proef
# moet juist de echte GitHub- en registry-meting uitvoeren.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/../verify.sh"

if [ -t 1 ]; then C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else C_OK=""; C_ERR=""; C_BOLD=""; C_OFF=""; fi

fail() { printf '  %sFOUT%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
pass() { printf '  %sok%s   %s\n' "$C_OK" "$C_OFF" "$*"; }

command -v gh >/dev/null || fail "gh ontbreekt; deze proef kan GitHub niet meten."
gh auth status >/dev/null 2>&1 || fail "Niet ingelogd bij GitHub; draai eerst gh auth login."
[ -x "$VERIFY" ] || fail "verify.sh ontbreekt of is niet uitvoerbaar."

printf '\n%s== Tegenproef: een publiek image komt niet door de privecontrole ==%s\n\n' "$C_BOLD" "$C_OFF"

UIT="$("$VERIFY" static-base 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || fail "verify.sh gaf groen; stap 5 heeft het publieke image niet gezien."

eis() { # eis <uitvoer> <omschrijving> <letterlijke uitvoer>
  local out="$1" what="$2" want="$3"
  case "$out" in
    *"$want"*) pass "$what" ;;
    *) printf '%s\n' "$out" | sed 's/^/      /' >&2; fail "ontbreekt: $what" ;;
  esac
}

eis_public() { # eis_public <omschrijving> <letterlijke uitvoer>
  case "$UIT" in
    *"$2"*) pass "$1" ;;
    *) printf '%s\n' "$UIT" | sed 's/^/      /' >&2; fail "ontbreekt: $1" ;;
  esac
}

eis_public "stap 1 ziet het bestaande containerpakket" "ok   1. klantpakket bestaat"
eis_public "stap 2 geeft rood: GitHub noemt static-base public" "2. GitHub noemt het pakket private"
eis_public "stap 3 vindt een bestaande digest" "ok   3. bestaande digest uit pakketversies"
eis_public "stap 4 haalt die digest ingelogd op" "ok   4. digest met inloggegevens ophalen"
eis_public "stap 5 geeft rood op anonieme HTTP 200" "5. dezelfde digest anoniem ophalen"
eis_public "stap 6 bevestigt dat de anonieme meting echt antwoordde" "ok   6. anonieme meting afgerond"

case "$UIT" in
  *"2. GitHub noemt het pakket private"*"public (verwacht: private)"*) pass "stap 2 is terecht rood: static-base is publiek" ;;
  *) fail "stap 2 was niet rood met de gemeten waarde public." ;;
esac
case "$UIT" in
  *"5. dezelfde digest anoniem ophalen"*"HTTP 200 (verwacht: 401, 403 of 404)"*) pass "stap 5 is terecht rood: anoniem ophalen lukt" ;;
  *) fail "stap 5 was niet rood met HTTP 200." ;;
esac

printf '\n  %sDe controle kan een publiek containerpakket zien en afkeuren.%s\n\n' "$C_OK" "$C_OFF"

printf '%s== Tegenproef: een privaat image komt wel door de privecontrole ==%s\n\n' "$C_BOLD" "$C_OFF"
PRIVATE_UIT="$("$VERIFY" mod_00002 2>&1)"; PRIVATE_RC=$?

eis "$PRIVATE_UIT" "stap 1 ziet het private klantpakket" "ok   1. klantpakket bestaat"
eis "$PRIVATE_UIT" "stap 2 is groen: GitHub noemt mod_00002 private" "ok   2. GitHub noemt het pakket private"
eis "$PRIVATE_UIT" "stap 3 vindt een bestaande private digest" "ok   3. bestaande digest uit pakketversies"
eis "$PRIVATE_UIT" "stap 4 haalt de private digest ingelogd op" "ok   4. digest met inloggegevens ophalen"
eis "$PRIVATE_UIT" "stap 5 is groen: tokenpunt weigert de buitenstaander" "ok   5. dezelfde digest anoniem ophalen"
eis "$PRIVATE_UIT" "stap 5 meldt de weg via het tokenpunt" "tokenpunt weigerde anoniem: HTTP"
eis "$PRIVATE_UIT" "stap 6 is groen: geldige tokenweigering" "ok   6. anonieme meting afgerond"
eis "$PRIVATE_UIT" "stap 6 bevestigt de geldige tokenweigering" "geldige weigering bij het tokenpunt"

# verify.sh meet ook de publieke bouwlaag. Die kan terecht rood staan zolang
# release.sh niet gedraaid is; deze proef bewijst alleen de zes projectstappen.
[ "$PRIVATE_RC" -eq 0 ] || pass "stappen 1-6 zijn groen; overige bouwlaagmeldingen horen niet bij deze proef"

printf '\n  %sDe controle kan een privaat containerpakket werkelijk goedkeuren.%s\n\n' "$C_OK" "$C_OFF"
