#!/usr/bin/env python3
"""Keurt de uitvoer van een build. Doel 4 van docs/07-bouwlaag.md.

Gebruik:
    check_output.py <uitvoermap> <manifest.json>

Weigeren op wat SEO of veiligheid breekt, waarschuwen op de rest. Een weigering
geeft afsluitcode 1 en dan wordt er niets gepubliceerd.

Dit script kijkt naar wat er WERKELIJK uit de build kwam, en raadt niets uit de
broncode. Een voorspelling op basis van bestanden in een repo heb je soms mis,
en dan wijs je een klant af die wel gehost had kunnen worden.

Alleen de standaardbibliotheek, want dit draait op een kale runner.
"""

import base64
import json
import os
import re
import sys
from html.parser import HTMLParser

# ---------------------------------------------------------------------------
# Grenzen. Voorlopige waarden, bij te stellen zodra er echte sites doorheen gaan.

MIN_ZICHTBARE_TEKENS = 100        # een pagina die gevonden moet worden
MAX_AFBEELDING_BYTES = 500 * 1024
MAX_PAGINA_BYTES = 1_500 * 1024
MAX_JS_BYTES = 300 * 1024

AFBEELDINGEN = (".png", ".jpg", ".jpeg", ".webp", ".avif", ".gif", ".svg")

# Pagina's die niet gevonden hoeven te worden en dus geen tekst hoeven te hebben.
TECHNISCHE_PAGINAS = {"404.html", "500.html", "offline.html"}

# ---------------------------------------------------------------------------
# Geheimen.
#
# BEWUST GEEN ALGEMENE ENTROPIETOETS. Die vindt ook de gehashte bestandsnamen en
# de brokken minified JavaScript die in elke build zitten, en dan blokkeer je een
# klant op een vals alarm. Wat hier staat zijn vormen die niets anders kunnen
# zijn dan een sleutel.
#
# Wat dit nooit kan: bewijzen dat er GEEN geheim in zit.

GEHEIMEN = [
    ("privesleutel",        re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("aws-sleutel",         re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("stripe geheime sleutel", re.compile(rb"\b[sr]k_(live|test)_[A-Za-z0-9]{16,}")),
    ("github-token",        re.compile(rb"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b")),
    ("github pat",          re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{20,}")),
    ("slack-token",         re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("google api-sleutel",  re.compile(rb"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("anthropic-sleutel",   re.compile(rb"\bsk-ant-[A-Za-z0-9_\-]{20,}")),
    ("openai-sleutel",      re.compile(rb"\bsk-proj-[A-Za-z0-9_\-]{20,}")),
]

JWT = re.compile(rb"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")

# Dit is bewust een korte, expliciete lijst. Een klant beheert zijn manifest en
# mag daarmee dus nooit een uitzondering maken voor een geheim. Voeg later een
# type toe aan deze verzameling, niet een extra uitzondering in een scanlus.
TOEGESTANE_PUBLIEKE_SLEUTELTYPEN = {"supabase_anon_key"}


class Bevindingen:
    def __init__(self):
        self.weigeringen = []
        self.waarschuwingen = []

    def weiger(self, wat, waar=""):
        self.weigeringen.append((wat, waar))

    def waarschuw(self, wat, waar=""):
        self.waarschuwingen.append((wat, waar))


# ---------------------------------------------------------------------------
# HTML lezen zonder browser.

class Pagina(HTMLParser):
    """Haalt uit een pagina wat je nodig hebt om te zien of er inhoud in staat.

    Scripts, stijlen, sjablonen en commentaar tellen niet mee. Wat overblijft is
    wat een bezoeker en een zoekmachine zien zonder JavaScript uit te voeren.
    """

    NEGEER = {"script", "style", "template", "noscript", "svg"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.diepte_negeren = 0
        self.tekst = []
        self.titel = ""
        self._in_titel = False
        self.heeft_kop = False
        self.taal = ""
        self.omschrijving = ""
        self.noindex = False
        self.verwijzingen = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in self.NEGEER:
            self.diepte_negeren += 1
        if tag == "title":
            self._in_titel = True
        if tag in ("h1", "main", "article"):
            self.heeft_kop = True
        if tag == "html" and a.get("lang"):
            self.taal = a["lang"]
        if tag == "meta":
            naam = (a.get("name") or "").lower()
            if naam == "description":
                self.omschrijving = a.get("content", "")
            if naam == "robots" and "noindex" in (a.get("content") or "").lower():
                self.noindex = True
        for attr in ("src", "href"):
            if a.get(attr):
                self.verwijzingen.append(a[attr])

    def handle_endtag(self, tag):
        if tag in self.NEGEER and self.diepte_negeren > 0:
            self.diepte_negeren -= 1
        if tag == "title":
            self._in_titel = False

    def handle_data(self, data):
        if self._in_titel:
            self.titel += data
        elif self.diepte_negeren == 0:
            self.tekst.append(data)


# ---------------------------------------------------------------------------

def lees_manifest(pad):
    with open(pad, "r", encoding="utf-8") as f:
        m = json.load(f)
    if "customer" in m:
        sys.exit("manifestveld 'customer' is vervallen; gebruik organisation, project en module")
    for veld in ("organisation", "project", "module", "plan", "package", "build"):
        if not m.get(veld):
            sys.exit(f"manifest mist het veld '{veld}': {pad}")
    for veld in ("command", "output"):
        if not m["build"].get(veld):
            sys.exit(f"manifest mist het veld 'build.{veld}': {pad}")
    m.setdefault("searchable", True)
    m.setdefault("allowed_public_keys", [])
    if not isinstance(m["allowed_public_keys"], list):
        sys.exit("manifestveld 'allowed_public_keys' moet een lijst zijn")
    for nummer, sleutel in enumerate(m["allowed_public_keys"], start=1):
        waar = f"allowed_public_keys[{nummer}]"
        if not isinstance(sleutel, dict):
            sys.exit(f"manifestveld '{waar}' moet een object zijn")
        sleuteltype = sleutel.get("type")
        waarde = sleutel.get("value")
        if not isinstance(sleuteltype, str) or not sleuteltype:
            sys.exit(f"manifestveld '{waar}.type' ontbreekt")
        if not isinstance(waarde, str) or not waarde:
            sys.exit(f"manifestveld '{waar}.value' ontbreekt")
        if sleuteltype not in TOEGESTANE_PUBLIEKE_SLEUTELTYPEN:
            sys.exit(
                f"manifestveld '{waar}' gebruikt verboden sleuteltype "
                f"'{sleuteltype}': alleen een publiek toegestane sleutel mag "
                "op de uitzonderingenlijst; geheimen falen altijd"
            )

        # Het type is geen etiket dat de klant zelf mag kiezen. Controleer de
        # waarde bij het lezen, zodat een service_role-sleutel niet eerst in een
        # uitvoermap hoeft te belanden voordat de fout zichtbaar wordt.
        rol = jwt_rol(waarde)
        if rol is None:
            sys.exit(
                f"manifestveld '{waar}' heeft type '{sleuteltype}', maar de "
                "waarde is geen leesbare JWT met een rol"
            )
        werkelijk_type = jwt_type(rol)
        if werkelijk_type != sleuteltype:
            sys.exit(
                f"manifestveld '{waar}' zegt type '{sleuteltype}', maar de "
                f"waarde is {werkelijk_type}: een service_role- of andere "
                "niet-publieke sleutel mag nooit op de uitzonderingenlijst"
            )
    vormen = {
        "organisation": r"^org_[0-9]{5}$",
        "project": r"^prj_[0-9]{5}$",
        "module": r"^mod_[0-9]{5}$",
    }
    for veld, patroon in vormen.items():
        if not re.fullmatch(patroon, m[veld]):
            sys.exit(f"manifestveld '{veld}' heeft ongeldige vorm: {m[veld]}")
    verwacht_pakket = f"ghcr.io/notift/{m['module']}"
    if m["package"] != verwacht_pakket:
        sys.exit(f"manifestveld 'package' moet exact '{verwacht_pakket}' zijn, niet '{m['package']}'")
    return m


def bestanden(root):
    for dirpad, _, namen in os.walk(root):
        for naam in namen:
            yield os.path.join(dirpad, naam)


def controleer_geheimen(root, toegestaan, b):
    """Zoekt sleutels in alles wat gepubliceerd wordt."""
    toegestane_waarden = {k.get("value", "") for k in toegestaan if k.get("value")}

    for pad in bestanden(root):
        naam = os.path.basename(pad)
        rel = os.path.relpath(pad, root)

        if naam == ".env" or naam.startswith(".env."):
            b.weiger("een .env-bestand staat in de uitvoer", rel)
            continue

        try:
            with open(pad, "rb") as f:
                inhoud = f.read()
        except OSError:
            continue

        for wat, patroon in GEHEIMEN:
            for treffer in patroon.finditer(inhoud):
                # Deze vormen zijn allemaal geheimen. De oude vorm keek eerst
                # naar de uitzonderingenlijst, waardoor een sk_-sleutel daarin
                # onzichtbaar werd. Een manifest mag die grens nooit verleggen.
                b.weiger(f"{wat} gevonden", rel)
                break

        # Een JWT moet eerst leesbaar en publiek blijken voordat de uitzondering
        # telt. De oude volgorde deed het omgekeerde: een waarde in het manifest
        # sloeg de rolcontrole over en kon zo een service_role-sleutel toelaten.
        for treffer in JWT.findall(inhoud):
            tekst = treffer.decode("utf-8", "ignore")
            rol = jwt_rol(tekst)
            if rol is None:
                b.weiger("een JWT waarvan de rol niet leesbaar is staat in de uitvoer", rel)
            elif rol == "service_role":
                b.weiger("een service_role-sleutel staat in de uitvoer", rel)
            elif jwt_type(rol) not in TOEGESTANE_PUBLIEKE_SLEUTELTYPEN:
                b.weiger(
                    f"een sleutel met rol '{rol}' staat in de uitvoer; die rol mag nooit publiek zijn",
                    rel,
                )
            elif tekst not in toegestane_waarden:
                b.weiger("een publieke sleutel staat in de uitvoer en niet in het manifest", rel)


def jwt_rol(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload))
        rol = data.get("role")
        return str(rol) if isinstance(rol, str) and rol else None
    except Exception:
        return None


def jwt_type(rol):
    """Het type dat de waarde werkelijk heeft, niet wat het manifest beweert."""
    if rol == "anon":
        return "supabase_anon_key"
    if rol == "service_role":
        return "supabase_service_role_key"
    return f"JWT met rol '{rol}'"


def controleer_html(root, doorzoekbaar, b):
    paginas = [p for p in bestanden(root) if p.lower().endswith(".html")]
    if not paginas:
        b.weiger("er staat geen enkele HTML-pagina in de uitvoer")
        return

    index = os.path.join(root, "index.html")
    if not os.path.isfile(index):
        b.weiger("er is geen index.html in de uitvoer")

    for pad in paginas:
        rel = os.path.relpath(pad, root)
        try:
            ruw = open(pad, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue

        p = Pagina()
        try:
            p.feed(ruw)
        except Exception:
            b.weiger("deze pagina is geen leesbare HTML", rel)
            continue

        technisch = os.path.basename(rel) in TECHNISCHE_PAGINAS or p.noindex

        if doorzoekbaar and not technisch:
            tekens = len(" ".join("".join(p.tekst).split()))
            if tekens < MIN_ZICHTBARE_TEKENS:
                b.weiger(
                    f"deze pagina bevat {tekens} tekens zichtbare tekst, "
                    f"minder dan {MIN_ZICHTBARE_TEKENS}. De inhoud komt pas als de "
                    "browser JavaScript uitvoert, en dan ziet Google hem niet",
                    rel,
                )
            if not p.titel.strip():
                b.weiger("deze pagina heeft geen titel", rel)
            if not p.heeft_kop:
                b.waarschuw("deze pagina heeft geen h1, main of article", rel)
            if not p.omschrijving.strip():
                b.waarschuw("deze pagina heeft geen omschrijving", rel)
            if not p.taal:
                b.waarschuw("deze pagina heeft geen taalaanduiding", rel)

        for ref in p.verwijzingen:
            if ref.startswith(("http://", "https://", "//", "data:", "mailto:", "tel:", "#")):
                continue
            doel = ref.split("?")[0].split("#")[0]
            if not doel:
                continue
            if doel.startswith("/"):
                volledig = os.path.join(root, doel.lstrip("/"))
            else:
                volledig = os.path.join(os.path.dirname(pad), doel)
            if not os.path.exists(volledig) and not os.path.exists(volledig + ".html"):
                b.waarschuw(f"verwijzing naar {ref} bestaat niet", rel)


def controleer_omvang(root, b):
    totaal_js = 0
    for pad in bestanden(root):
        rel = os.path.relpath(pad, root)
        grootte = os.path.getsize(pad)

        if pad.lower().endswith(AFBEELDINGEN) and grootte > MAX_AFBEELDING_BYTES:
            b.waarschuw(f"afbeelding van {grootte // 1024} KB, boven de {MAX_AFBEELDING_BYTES // 1024} KB", rel)
        if pad.lower().endswith(".js"):
            totaal_js += grootte
        if pad.lower().endswith(".map"):
            b.waarschuw("bronkaart wordt gepubliceerd, daarmee staat de broncode leesbaar op internet", rel)

    if totaal_js > MAX_JS_BYTES:
        b.waarschuw(f"in totaal {totaal_js // 1024} KB JavaScript, boven de {MAX_JS_BYTES // 1024} KB")

    index = os.path.join(root, "index.html")
    if os.path.isfile(index):
        gewicht = os.path.getsize(index) + totaal_js
        if gewicht > MAX_PAGINA_BYTES:
            b.waarschuw(f"de startpagina weegt met JavaScript ongeveer {gewicht // 1024} KB")


def controleer_vorm(root, b):
    """Alleen gewone bestanden en mappen. Geen verwijzingen naar buiten."""
    for dirpad, mappen, namen in os.walk(root):
        for naam in mappen + namen:
            pad = os.path.join(dirpad, naam)
            if os.path.islink(pad):
                doel = os.path.realpath(pad)
                if not doel.startswith(os.path.realpath(root) + os.sep):
                    b.weiger("een verwijzing die uit de uitvoermap wijst", os.path.relpath(pad, root))
            elif not (os.path.isfile(pad) or os.path.isdir(pad)):
                b.weiger("een bestand dat geen gewoon bestand is", os.path.relpath(pad, root))


def main():
    if len(sys.argv) != 3:
        sys.exit("Gebruik: check_output.py <uitvoermap> <manifest.json>")

    root, manifestpad = sys.argv[1], sys.argv[2]
    manifest = lees_manifest(manifestpad)

    if not os.path.isdir(root):
        print(f"\n  FOUT De build leverde geen map {root} op.")
        print("  Deze build leverde geen statische website op. Stel een statische export in,")
        print("  of dit hoort in het toekomstige serverpakket.\n")
        return 1

    b = Bevindingen()
    controleer_vorm(root, b)
    controleer_html(root, manifest["searchable"], b)
    controleer_geheimen(root, manifest["allowed_public_keys"], b)
    controleer_omvang(root, b)

    print(f"\n== Controle van {root} ==")
    print(f"  project {manifest['project']}, gevonden worden: "
          f"{'ja' if manifest['searchable'] else 'nee'}")

    if b.waarschuwingen:
        print(f"\n  {len(b.waarschuwingen)} waarschuwing(en):")
        for wat, waar in b.waarschuwingen:
            print(f"    let op  {wat}" + (f"  [{waar}]" if waar else ""))

    if b.weigeringen:
        print(f"\n  {len(b.weigeringen)} reden(en) om niet te publiceren:")
        for wat, waar in b.weigeringen:
            print(f"    FOUT    {wat}" + (f"  [{waar}]" if waar else ""))
        print("\n  Er wordt niets gepubliceerd.\n")
        return 1

    print(f"\n  Goedgekeurd, met {len(b.waarschuwingen)} waarschuwing(en).\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
