#!/usr/bin/env bash
# Proef van security.txt met een Expires die de build zet (Leon, 19 oktober 2026): de builddatum plus 365 dagen,
# ISO 8601 in UTC, en het vangnet van 180 dagen. Meet de echte security-txt.sh, de echte RUN-regel uit de
# Dockerfile (paden naar een werkmap) en de aansluiting in base-image.yml. Elke tegenproef moet rood zijn.
#   bash infra/build/checks/security-txt-proof.sh
set -uo pipefail
B="$(cd "$(dirname "$0")/.." && pwd)"
S="$B/base/security-txt.sh"; T="$B/base/security.txt"; D="$B/base/Dockerfile"; WF="$B/workflow/base-image.yml"
W="$(mktemp -d "${PROOF_TMP:-$B/checks}/.sectxt.XXXXXX")"; trap 'rm -rf "$W"' EXIT
OK=0; FAIL=0
ok() { printf 'OK   %s\n' "$*"; OK=$((OK + 1)); }
bad() { printf 'FOUT %s\n' "$*"; FAIL=$((FAIL + 1)); }
red() { if "$@" >"$W/red.out" 2>&1; then return 1; fi; return 0; }  # red <cmd>: waar als de opdracht faalt

# 1. De datum: builddatum plus 365 dagen, los nagerekend met Python.
want="$(python3 -c 'import datetime as d; print((d.datetime(2026,10,19)+d.timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')"
got="$(sh "$S" expires 2026-10-19)"
[ "$got" = "$want" ] && ok "expires 2026-10-19: $got" || bad "expires 2026-10-19: $got, verwacht $want"
want="$(python3 -c 'import datetime as d; t=d.datetime.now(d.timezone.utc).date(); print((d.datetime(t.year,t.month,t.day)+d.timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')"
GEN="$(sh "$S" expires)"
[ "$GEN" = "$want" ] && ok "expires vandaag (UTC): $GEN" || bad "expires vandaag: $GEN, verwacht $want"
got="$(sh "$S" expires 2028-02-29)"; [ "$got" = 2029-02-28T00:00:00.000Z ] && ok "schrikkeldag: 2028-02-29 plus 365 dagen is $got" || bad "schrikkeldag: $got"

# 2. Het sjabloon en de render.
[ "$(grep -c '^Expires: @EXPIRES@$' "$T")" = 1 ] && ! grep -Eq '^Expires: [0-9]' "$T" && ok "base/security.txt is een sjabloon, geen datum met de hand" || bad "base/security.txt heeft geen sjabloonregel of nog een vaste datum"
sh "$S" render "$T" "$GEN" > "$W/sec.txt" && [ "$(sed -n 's/^Expires: //p' "$W/sec.txt")" = "$GEN" ] && grep -qx 'Contact: mailto:info@notift.nl' "$W/sec.txt" \
  && ok "render: Contact info@notift.nl, Expires $GEN" || bad "render: $(tr '\n' ' ' < "$W/sec.txt")"
out="$(sh "$S" check "$W/sec.txt" 2>&1)" && ok "controle op de gegenereerde datum: $out" || bad "controle op de gegenereerde datum rood: $out"

# 3. De RUN-regel uit de Dockerfile zelf, met de paden naar de werkmap. Zonder build-arg faalt de build.
grep -qx 'ARG SECURITY_TXT_EXPIRES' "$D" && ok "Dockerfile: ARG SECURITY_TXT_EXPIRES" || bad "Dockerfile: geen ARG SECURITY_TXT_EXPIRES"
awk '/^RUN mkdir -p \/etc\/nginx\/notift/ {on=1} on {l=$0; sub(/^RUN /, "", l); c=(l ~ /\\$/); sub(/\\$/, "", l); printf "%s ", l; if (!c) exit}' "$D" > "$W/run.sh"
grep -q 'security-txt.sh render' "$W/run.sh" || bad "RUN-regel met security-txt.sh niet gevonden in de Dockerfile"
mkdir -p "$W/img/tmp/notift-security"; cp "$T" "$S" "$W/img/tmp/notift-security/"
sed -i '' -e "s|/tmp/notift-security|$W/img/tmp/notift-security|g" -e "s|/etc/nginx/notift|$W/img/etc|g" "$W/run.sh"
SECURITY_TXT_EXPIRES="$GEN" sh -c ". '$W/run.sh'" > "$W/run.out" 2>&1 \
  && [ "$(sed -n 's/^Expires: //p' "$W/img/etc/security.txt")" = "$GEN" ] && [ ! -d "$W/img/tmp/notift-security" ] \
  && ok "Dockerfile-RUN met de build-arg: /etc/nginx/notift/security.txt met Expires $GEN, sjabloon weg" || bad "Dockerfile-RUN: $(cat "$W/run.out")"
rm -rf "$W/img"; mkdir -p "$W/img/tmp/notift-security"; cp "$T" "$S" "$W/img/tmp/notift-security/"
red env SECURITY_TXT_EXPIRES= sh -c ". '$W/run.sh'" && ok "tegenproef: build zonder SECURITY_TXT_EXPIRES faalt ($(head -1 "$W/red.out"))" || bad "build zonder Expires liep door"

# 4. De workflow: de datum gaat als build-arg mee, en de controle meet precies die datum en het vangnet.
grep -q 'EXPIRES="$(sh base/security-txt.sh expires)"' "$WF" && grep -q 'build-args: SECURITY_TXT_EXPIRES=${{ steps.securitytxt.outputs.expires }}' "$WF" \
  && grep -q 'EXPIRES: ${{ steps.securitytxt.outputs.expires }}' "$WF" && grep -q 'sh base/security-txt.sh check security-served.txt' "$WF" \
  && grep -q '= "$EXPIRES"' "$WF" && ok "base-image.yml: datum berekend, als build-arg mee, en gemeten in het gepubliceerde image" || bad "base-image.yml mist een schakel"
! grep -q 'date -u -d "$exp"' "$WF" && ok "base-image.yml: de oude losse datumcontrole is weg (één controle: security-txt.sh)" || bad "oude datumcontrole staat er nog"

# 5. Tegenproeven op de controle: elk moet rood zijn.
mk() { sed "s/^Expires: .*/Expires: $1/" "$W/sec.txt" > "$W/t.txt"; }
mk 2026-01-01T00:00:00.000Z; red sh "$S" check "$W/t.txt" && ok "tegenproef: vaste oude datum 2026-01-01 is rood ($(cat "$W/red.out"))" || bad "oude datum groen"
soon="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(days=179)).strftime("%Y-%m-%dT00:00:00.000Z"))')"
mk "$soon"; red sh "$S" check "$W/t.txt" && ok "tegenproef: over 179 dagen is rood (vangnet 180)" || bad "179 dagen groen"
ok180="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(days=182)).strftime("%Y-%m-%dT00:00:00.000Z"))')"
mk "$ok180"; sh "$S" check "$W/t.txt" >/dev/null 2>&1 && ok "grens: over 182 dagen is groen" || bad "182 dagen rood"
red sh "$S" check "$T" && ok "tegenproef: het sjabloon zonder render (@EXPIRES@) is rood" || bad "ongerenderd sjabloon groen"
mk 2027-10-19; red sh "$S" check "$W/t.txt" && ok "tegenproef: Expires zonder tijd en zone is rood" || bad "datum zonder tijd groen"
red sh "$S" render "$T" "" && ok "tegenproef: render zonder datum weigert" || bad "render zonder datum liep door"
red sh "$S" render "$T" "2027-10-19 00:00" && ok "tegenproef: render met een datum die geen ISO 8601 in UTC is weigert" || bad "render met vrije datum liep door"
printf 'Contact: mailto:info@notift.nl\nExpires: 2027-10-18T00:00:00.000Z\n' > "$W/hand.txt"
red sh "$S" render "$W/hand.txt" "$GEN" && ok "tegenproef: een sjabloon met een datum met de hand weigert de render" || bad "render op een handdatum liep door"
sed 's/info@notift.nl/klant@example.invalid/' "$W/sec.txt" > "$W/t.txt"; red sh "$S" check "$W/t.txt" && ok "tegenproef: een ander Contact is rood" || bad "ander Contact groen"
: > "$W/leeg.txt"; red sh "$S" check "$W/leeg.txt" && ok "tegenproef: een leeg bestand is rood" || bad "leeg bestand groen"
red sh "$S" check "$W/bestaat-niet.txt" && ok "tegenproef: geen bestand is rood" || bad "geen bestand groen"

printf '\nEindlijst: %d OK, %d FOUT\n' "$OK" "$FAIL"
[ "$FAIL" -eq 0 ]
