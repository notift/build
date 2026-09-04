#!/usr/bin/env bash
# Het bewijs van doel 4: de controle weigert wat hij moet weigeren.
#
# Bouwt een reeks nepuitvoeren in /tmp en kijkt of de controle ze accepteert of
# afwijst. Zoals overal in dit project: eerst aantonen dat de toets iets KAN
# zien, dan pas geloven wat hij zegt.
#
# Draait op de Mac, praat met niets. Gebruik: ./check-output-proof.sh

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check_output.py"

if [ -t 1 ]; then C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else C_OK=""; C_ERR=""; C_BOLD=""; C_OFF=""; fi
FAILED=0
pass() { printf '  %sok%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
bad()  { printf '  %sFOUT%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; FAILED=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Twee sleutels in JWT-vorm, zoals Supabase ze uitgeeft.
ANON="$(python3 -c '
import base64, json
def d(o): return base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
print(d({"alg":"HS256"}) + "." + d({"role":"anon","iss":"supabase"}) + ".handtekeningXYZ123")')"
SERVICE="$(python3 -c '
import base64, json
def d(o): return base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
print(d({"alg":"HS256"}) + "." + d({"role":"service_role","iss":"supabase"}) + ".handtekeningXYZ123")')"

# manifest <naam> <doorzoekbaar> [toegestane sleutel]
manifest() {
  local naam="$1" zoek="$2" sleutel="${3:-}"
  local keys="[]"
  [ -n "$sleutel" ] && keys="[{\"type\": \"supabase_anon_key\", \"value\": \"$sleutel\"}]"
  cat > "$WORK/$naam.json" <<JSON
{
  "project": "prj_proof",
  "customer": "cus_proof",
  "plan": "websites-1",
  "package": "ghcr.io/notift/prj_proof",
  "build": { "command": "npm run build", "output": "dist", "node": "22", "manager": "npm" },
  "searchable": $zoek,
  "allowed_public_keys": $keys
}
JSON
}

# goede_site <map>
goede_site() {
  mkdir -p "$1"
  cat > "$1/index.html" <<'HTML'
<!doctype html>
<html lang="nl">
<head>
<meta charset="utf-8">
<title>Bakkerij Jansen</title>
<meta name="description" content="Ambachtelijk brood uit Amersfoort, elke ochtend vers.">
</head>
<body>
<main>
<h1>Bakkerij Jansen</h1>
<p>Wij bakken sinds 1974 ambachtelijk brood in Amersfoort. Elke ochtend vers uit
de oven, met meel van de molen om de hoek. Kom langs in de winkel of bestel
online voor de volgende dag.</p>
</main>
</body>
</html>
HTML
  printf 'console.log("hallo");' > "$1/app-a1b2c3d4.js"
}

# verwacht <weigeren|toelaten> <omschrijving> <map> <manifest>
verwacht() {
  local want="$1" wat="$2" map="$3" man="$4" uit rc=0
  uit="$(python3 "$CHECK" "$map" "$WORK/$man.json" 2>&1)" || rc=$?
  case "$want" in
    weigeren)
      if [ "$rc" -ne 0 ]; then pass "geweigerd: $wat"
      else bad "TOEGELATEN terwijl het geweigerd moest worden: $wat"; fi ;;
    toelaten)
      if [ "$rc" -eq 0 ]; then pass "toegelaten: $wat"
      else bad "geweigerd terwijl het mocht: $wat"; printf '%s\n' "$uit" | sed 's/^/      /' >&2; fi ;;
  esac
}

printf '\n%s== Het bewijs van doel 4: wat weigert en wat waarschuwt ==%s\n\n' "$C_BOLD" "$C_OFF"

manifest gewoon true
manifest dashboard false
manifest metsleutel true "$ANON"

# 0. De toets moet iets kunnen zien.
goede_site "$WORK/goed"
verwacht toelaten "een gewone site met tekst, titel en taal" "$WORK/goed" gewoon

# 1. Een schil zonder inhoud.
mkdir -p "$WORK/schil"
printf '<!doctype html><html><head><title>App</title></head><body><div id="root"></div><script src="/app.js"></script></body></html>' > "$WORK/schil/index.html"
printf 'console.log(1);' > "$WORK/schil/app.js"
verwacht weigeren "een lege schil waar HTML hoort" "$WORK/schil" gewoon

# 2. Diezelfde schil mag wel als hij niet gevonden hoeft te worden.
verwacht toelaten "dezelfde schil, maar als dashboard achter een login" "$WORK/schil" dashboard

# 3. Geen index.html.
mkdir -p "$WORK/geenindex"
cp "$WORK/goed/index.html" "$WORK/geenindex/over.html"
verwacht weigeren "geen index.html in de uitvoer" "$WORK/geenindex" gewoon

# 4. De uitvoermap bestaat niet.
verwacht weigeren "de build leverde geen uitvoermap op" "$WORK/bestaatniet" gewoon

# 5. Een .env in de uitvoer.
cp -R "$WORK/goed" "$WORK/metenv"
printf 'API_KEY=geheim\n' > "$WORK/metenv/.env"
verwacht weigeren "een .env-bestand in de uitvoer" "$WORK/metenv" gewoon

# 6. Een geheime sleutel van Stripe.
cp -R "$WORK/goed" "$WORK/metstripe"
printf 'const k = "sk_live_51H8xQ2eZvKYlo2CabcdefghijK";' > "$WORK/metstripe/betalen.js"
verwacht weigeren "een geheime sleutel van Stripe in een JavaScript-bestand" "$WORK/metstripe" gewoon

# 7. Een service_role-sleutel.
cp -R "$WORK/goed" "$WORK/metservice"
printf 'const s = "%s";' "$SERVICE" > "$WORK/metservice/db.js"
verwacht weigeren "een service_role-sleutel" "$WORK/metservice" gewoon

# 8. Een anon key die niet in het manifest staat.
cp -R "$WORK/goed" "$WORK/metanon"
printf 'const s = "%s";' "$ANON" > "$WORK/metanon/db.js"
verwacht weigeren "een publieke sleutel die niet in het manifest staat" "$WORK/metanon" gewoon

# 9. Diezelfde sleutel, wel in het manifest.
verwacht toelaten "diezelfde sleutel, wel in het manifest" "$WORK/metanon" metsleutel

# 10. Een privesleutel.
cp -R "$WORK/goed" "$WORK/metprive"
printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEow==\n-----END RSA PRIVATE KEY-----\n' > "$WORK/metprive/sleutel.txt"
verwacht weigeren "een privesleutel in de uitvoer" "$WORK/metprive" gewoon

# 11. Een pagina zonder titel.
cp -R "$WORK/goed" "$WORK/geentitel"
python3 - "$WORK/geentitel/index.html" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("<title>Bakkerij Jansen</title>", "")
open(p, "w").write(s)
PY
verwacht weigeren "een pagina zonder titel" "$WORK/geentitel" gewoon

# 12. Waarschuwingen blokkeren niet.
cp -R "$WORK/goed" "$WORK/metwaarschuwing"
python3 -c "open('$WORK/metwaarschuwing/foto.jpg','wb').write(b'x' * 900 * 1024)"
printf '{"version":3}' > "$WORK/metwaarschuwing/app-a1b2c3d4.js.map"
printf '<a href="/bestaat-niet.html">meer</a>' >> "$WORK/metwaarschuwing/index.html"
verwacht toelaten "een grote foto, een bronkaart en een kapotte verwijzing" "$WORK/metwaarschuwing" gewoon

UIT="$(python3 "$CHECK" "$WORK/metwaarschuwing" "$WORK/gewoon.json" 2>&1)"
for w in "afbeelding van" "bronkaart" "bestaat niet"; do
  case "$UIT" in
    *"$w"*) pass "gewaarschuwd over: $w" ;;
    *) bad "geen waarschuwing over: $w" ;;
  esac
done

printf '\n'
if [ "$FAILED" -ne 0 ]; then
  printf '  %sEr klopt iets niet aan de controle zelf.%s\n\n' "$C_ERR" "$C_OFF" >&2
  exit 1
fi
printf '  %sAlles wat geweigerd moest worden is geweigerd, en waarschuwingen blokkeren niet.%s\n\n' "$C_OK" "$C_OFF"
