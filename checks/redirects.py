#!/usr/bin/env python3
"""Redirects per pad: `_redirects` in de uitvoer van een site wordt een nginx-map in het image.

Ontwerp en besluiten: docs/07-bouwlaag.md, "Redirects per pad".

Gebruik:
    redirects.py check <sitemap>               keuren, afsluitcode 1 bij een fout
    redirects.py generate <sitemap> <map-uit>  keuren en de map schrijven (leeg zonder _redirects)
    redirects.py list <_redirects>             alleen de syntaxis; per regel: regelnummer, bron, bestemming, code

Het formaat is een strikte deelverzameling van `_redirects` van Netlify:

    # commentaar
    /oud-adres        /nieuw-adres
    /oude-pagina.html /nieuw  308
    /elders           https://example.org/pad  302

Een regel is `bron bestemming [301|302|307|308]`, standaard 301. Alleen exacte paden; een slash aan het
eind van de bron telt niet (`/oud` vangt ook `/oud/`). Hoofdletters tellen wel. De querystring van het
verzoek gaat mee naar de bestemming. Wildcards, placeholders, voorwaarden en een querystring in de bron
of bestemming kan het platform nog niet: die geven een fout met de reden.

Een fout weigert de build (Leon, 22 oktober 2026), met de regel in de melding. Een build die niet
gebouwd wordt, raakt de draaiende site niet: de oude versie blijft live.

Alleen de standaardbibliotheek, want dit draait op een kale runner.
"""

import os
import re
import sys
import tempfile
import urllib.parse

BESTAND = "_redirects"
CODES = ("301", "302", "307", "308")
STANDAARD_CODE = "301"
MAX_BYTES = 4 * 1024 * 1024   # 2000 regels van twee keer 1000 tekens passen erin
MAX_REGELS = 2000          # zoals de statische regels van Cloudflare Pages; daarboven een trigger
MAX_PAD = 1000             # tekens per bron of bestemming; nginx.conf zet de hashgrootte daarop

# Wat in een pad mag: de tekens van RFC 3986 voor een pad, zonder de tekens die in nginx iets betekenen
# (", \, $, ;, {, }, ') of in _redirects van Netlify (*, :). %XX voor de rest.
PAD = re.compile(r"(?:[A-Za-z0-9._~!&()+,=@/-]|%[0-9A-Fa-f]{2})*")
HOST = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+")
URL = re.compile(r"(https?)://([^/?#]+)(/.*)?")

# Wat het platform zelf bedient. Een redirect zou de uitrol (_health), security.txt of de formulieren
# breken, en /_redirects en /404.html horen bij de bouwlaag.
GERESERVEERD = ("/_health", "/_redirects", "/404.html")
GERESERVEERDE_MAPPEN = ("/_notift", "/.well-known")


class Regel:
    def __init__(self, nummer, tekst, bron, doel, code):
        self.nummer = nummer
        self.tekst = tekst
        self.bron = bron
        self.doel = doel
        self.code = code

    @property
    def sleutel(self):
        """De bron zonder slash aan het eind. Dat is wat nginx straks in twee vormen vangt."""
        return self.bron.rstrip("/") or "/"

    @property
    def sleutels(self):
        return (self.sleutel, self.sleutel + "/")

    @property
    def lokaal(self):
        return self.doel.startswith("/")


class Fout:
    def __init__(self, nummer, wat, tekst=""):
        self.nummer = nummer
        self.wat = wat
        self.tekst = tekst

    def __str__(self):
        waar = f"{BESTAND} regel {self.nummer}" if self.nummer else BESTAND
        return f"{waar}: {self.wat}" + (f"  [{self.tekst}]" if self.tekst else "")


def toon(tekst):
    """Een regel uit het bestand, veilig om te tonen: geen stuurtekens, niet eindeloos lang."""
    schoon = "".join(c if c.isprintable() else "?" for c in tekst)
    return schoon if len(schoon) <= 200 else schoon[:200] + "..."


def keur_pad(pad, soort):
    """Een fouttekst, of None als het pad mag. soort is 'bron' of 'bestemming'."""
    if not pad.startswith("/"):
        return f"een {soort} begint met /"
    if pad.startswith("//"):
        return f"een {soort} mag niet met // beginnen"
    if len(pad) > MAX_PAD:
        return f"de {soort} is langer dan {MAX_PAD} tekens"
    if "?" in pad:
        if soort == "bron":
            return "een querystring in de bron kan het platform nog niet; de querystring van het verzoek gaat vanzelf mee"
        return "een querystring in de bestemming kan het platform nog niet; de querystring van het verzoek gaat vanzelf mee"
    if "#" in pad:
        return f"een # in de {soort} kan niet; een anker komt nooit bij de server"
    if soort == "bron":
        if "*" in pad:
            return "wildcards (*) kan het platform nog niet; zet elk adres op een eigen regel"
        if any(deel.startswith(":") for deel in pad.split("/")):
            return "placeholders (:naam) kan het platform nog niet; zet elk adres op een eigen regel"
    if any(ord(c) > 127 for c in pad):
        gecodeerd = urllib.parse.quote(pad, safe="/%!&()+,=@~-._")
        return f"codeer tekens buiten ASCII als %XX, dus {gecodeerd}"
    if not PAD.fullmatch(pad):
        teken = next((c for c in pad if not PAD.fullmatch(c) and c != "%"), "%")
        if teken == "%":
            return f"een % in de {soort} moet gevolgd worden door twee hexadecimale cijfers"
        return f"het teken {teken!r} mag niet in de {soort}"
    if "//" in pad:
        return f"een dubbele slash in de {soort} kan niet"
    delen = urllib.parse.unquote(pad).split("/")
    if "." in delen or ".." in delen:
        return f"een {soort} met /./ of /../ kan niet"
    return None


def keur_doel(doel):
    if doel.startswith("/"):
        return keur_pad(doel, "bestemming")
    m = URL.fullmatch(doel)
    if not m:
        return "een bestemming is een pad dat met / begint, of een volledige URL met http:// of https://"
    host, pad = m.group(2), m.group(3)
    hostdeel, _, poort = host.partition(":")
    if not HOST.fullmatch(hostdeel) or (poort and not (poort.isdigit() and 0 < int(poort) < 65536)):
        return f"de host {host!r} van de bestemming is geen geldige hostnaam"
    if pad:
        return keur_pad(pad, "bestemming")
    if "?" in doel or "#" in doel:
        return "een querystring of anker in de bestemming kan het platform nog niet"
    return None


def lees(data):
    """De regels uit de bytes van _redirects. Geeft (regels, fouten)."""
    regels, fouten = [], []
    if len(data) > MAX_BYTES:
        return [], [Fout(0, f"het bestand is groter dan {MAX_BYTES // 1024} KB")]
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    for nummer, ruw in enumerate(data.split(b"\n"), start=1):
        try:
            tekst = ruw.decode("utf-8").rstrip("\r")
        except UnicodeDecodeError:
            fouten.append(Fout(nummer, "deze regel is geen UTF-8"))
            continue
        kaal = tekst.strip()
        if not kaal or kaal.startswith("#"):
            continue
        velden = kaal.split()
        if len(velden) < 2:
            fouten.append(Fout(nummer, "een regel heeft een bron en een bestemming nodig", toon(kaal)))
            continue
        if len(velden) > 3:
            fouten.append(Fout(nummer, "te veel velden; voorwaarden, opties en querystrings in de bron kan het "
                                       "platform nog niet. Een regel is: bron bestemming [301|302|307|308]",
                               toon(kaal)))
            continue
        bron, doel = velden[0], velden[1]
        code = velden[2] if len(velden) == 3 else STANDAARD_CODE
        reden = None
        if code not in CODES:
            if code.endswith("!") and code[:-1] in CODES:
                reden = f"{code} met ! is niet nodig: bij Notift wint een redirect altijd van een bestand. Schrijf {code[:-1]}"
            else:
                reden = f"onbekende statuscode {code!r}; alleen 301, 302, 307 of 308"
        elif bron.startswith(("http://", "https://")):
            reden = "een bron is een pad, geen volledige URL. Een hele host doorsturen gaat met CANONICAL_HOST"
        else:
            reden = keur_pad(bron, "bron") or keur_doel(doel)
        if reden:
            fouten.append(Fout(nummer, reden, toon(kaal)))
            continue
        regels.append(Regel(nummer, toon(kaal), bron, doel, code))
    if len(regels) > MAX_REGELS:
        fouten.append(Fout(0, f"meer dan {MAX_REGELS} regels; daarvoor zijn patronen nodig, en die kan het platform nog niet"))
    return regels, fouten


def bestand_in(root, pad):
    """Bestaat dit pad (zoals nginx het decodeert) als gewoon bestand in de site?"""
    rel = urllib.parse.unquote(pad).lstrip("/")
    volledig = os.path.join(root, rel)
    return bool(rel) and os.path.isfile(volledig)


def keur_lokaal_doel(root, doel):
    """Geeft de bestemming op deze site 200, zonder tweede stap via de slash- of .html-regel van nginx.conf?"""
    if doel == "/":
        return None if bestand_in(root, "/index.html") else "de bestemming / bestaat niet: er is geen index.html"
    if doel.endswith("/index.html"):
        return f"de .html-regel stuurt {doel} door naar {doel[:-len('index.html')]}; verwijs daar direct heen"
    if doel.endswith(".html"):
        return f"de .html-regel stuurt {doel} door naar {doel[:-5]}; verwijs daar direct heen"
    if doel.endswith("/"):
        zonder = doel.rstrip("/")
        if bestand_in(root, zonder + ".html"):
            return f"de slash-regel stuurt {doel} door naar {zonder}; verwijs daar direct heen"
        if bestand_in(root, zonder + "/index.html"):
            return None
        return f"de bestemming {doel} bestaat niet in de site"
    if bestand_in(root, doel) or bestand_in(root, doel + ".html"):
        return None
    if bestand_in(root, doel + "/index.html"):
        return f"nginx stuurt {doel} door naar {doel}/; verwijs daar direct heen"
    return f"de bestemming {doel} bestaat niet in de site"


def keur_samen(regels, root):
    """Wat alleen over de hele lijst en de site te zeggen is. Geeft (fouten, waarschuwingen)."""
    fouten, waarschuwingen = [], []

    # Dubbele bron. nginx zoekt in de map zonder op hoofdletters te letten (gemeten op 22 oktober 2026),
    # en nginx.conf maakt het daarna exact. Twee bronnen die alleen in hoofdletters verschillen kan de
    # hashtabel dus niet uit elkaar houden.
    gezien = {}
    goed = []
    for r in regels:
        eerder = gezien.get(r.sleutel.lower())
        if eerder is None:
            gezien[r.sleutel.lower()] = r
            goed.append(r)
        elif eerder.sleutel == r.sleutel:
            extra = "" if eerder.bron == r.bron else " (een slash aan het eind telt niet)"
            fouten.append(Fout(r.nummer, f"dubbele bron: {r.sleutel} staat al op regel {eerder.nummer}{extra}", r.tekst))
        else:
            fouten.append(Fout(r.nummer, f"de bron {r.bron} verschilt alleen in hoofdletters van regel {eerder.nummer}; "
                                         "dat kan nginx niet uit elkaar houden", r.tekst))

    per_sleutel = {}
    for r in goed:
        for s in r.sleutels:
            per_sleutel[s] = r

    for r in goed:
        # Een bron die het platform zelf bedient, of die de homepagina en de .html-regel raakt.
        if r.sleutel in ("/", "/index.html"):
            fouten.append(Fout(r.nummer, f"de bron {r.bron} kan niet: dat is de homepagina, en nginx leidt / intern door "
                                         "naar /index.html. Een hele site doorsturen gaat met CANONICAL_HOST", r.tekst))
            continue
        if r.sleutel in GERESERVEERD or any(r.sleutel == m or r.sleutel.startswith(m + "/") for m in GERESERVEERDE_MAPPEN):
            fouten.append(Fout(r.nummer, f"de bron {r.bron} bedient het platform zelf en kan geen redirect zijn", r.tekst))
            continue

        if r.lokaal:
            # Lus en ketting: komt de bezoeker na deze redirect weer op een bron uit?
            if r.doel in per_sleutel:
                pad, huidig = [r], per_sleutel[r.doel]
                while huidig not in pad and huidig.lokaal and huidig.doel in per_sleutel:
                    pad.append(huidig)
                    huidig = per_sleutel[huidig.doel]
                if huidig is r:
                    if len(pad) == 1:
                        fouten.append(Fout(r.nummer, f"lus: de bestemming {r.doel} is de bron zelf"
                                                     + (" (een slash aan het eind telt niet)" if r.doel != r.bron else ""),
                                           r.tekst))
                    else:
                        via = " -> ".join([p.bron for p in pad] + [r.bron])
                        fouten.append(Fout(r.nummer, f"lus: {via}", r.tekst))
                elif huidig in pad:
                    fouten.append(Fout(r.nummer, f"ketting naar een lus: de bestemming {r.doel} is zelf een bron (regel "
                                                 f"{per_sleutel[r.doel].nummer})", r.tekst))
                else:
                    eind = huidig.doel
                    fouten.append(Fout(r.nummer, f"ketting: de bestemming {r.doel} is zelf een bron (regel "
                                                 f"{per_sleutel[r.doel].nummer}); verwijs direct naar {eind}", r.tekst))
                continue
            reden = keur_lokaal_doel(root, r.doel)
            if reden:
                fouten.append(Fout(r.nummer, reden, r.tekst))
                continue

        # Wint van een bestaand bestand, met opzet (Cloudflare Pages en Vercel doen het ook zo). Wel melden.
        if any(bestand_in(root, p) for p in (r.sleutel, r.sleutel + ".html", r.sleutel + "/index.html")):
            waarschuwingen.append(Fout(r.nummer, f"{r.sleutel} bestaat ook in de site; de redirect wint", r.tekst))

    return fouten, waarschuwingen


def keur_site(root):
    """Leest <root>/_redirects als die er is. Geeft (regels, fouten, waarschuwingen)."""
    pad = os.path.join(root, BESTAND)
    if not os.path.lexists(pad):
        return [], [], []
    if os.path.islink(pad) or not os.path.isfile(pad):
        return [], [Fout(0, "_redirects moet een gewoon bestand zijn")], []
    with open(pad, "rb") as f:
        regels, fouten = lees(f.read(MAX_BYTES + 1))
    if fouten:
        return regels, fouten, []
    fouten, waarschuwingen = keur_samen(regels, root)
    return regels, fouten, waarschuwingen


def map_tekst(regels):
    """De inhoud van redirects.map. Wordt in nginx.conf binnen een map-blok geladen."""
    uit = [f"# Generated by checks/redirects.py from {BESTAND}: {len(regels)} rule(s). Do not edit.\n"]
    for r in regels:
        for s in r.sleutels:
            uit.append(f'"{s}" "{s} {r.code} {r.doel}";\n')
    return "".join(uit)


def annotatie(fout):
    """Een GitHub-annotatie: de regel staat bovenaan de mislukte run. De mail van GitHub over die run gaat
    naar wie pushte en linkt naar de run; dat de mail de regel zelf toont, is niet gemeten (besluit 106)."""
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    tekst = str(fout).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    titel = f"{BESTAND} regel {fout.nummer}" if fout.nummer else BESTAND
    print(f"::error title={titel}::{tekst}")


def meld(fouten, waarschuwingen):
    for w in waarschuwingen:
        print(f"    let op  {w}")
    for f in fouten:
        print(f"    FOUT    {f}")
        annotatie(f)
    if fouten:
        print(f"\n  {len(fouten)} fout(en) in {BESTAND}. Er wordt niets gepubliceerd; de site blijft op de vorige versie.\n")


def schrijf(pad, tekst):
    """Via een tijdelijk bestand en een wissel: een half bestand bestaat nooit onder de echte naam."""
    map_ = os.path.dirname(os.path.abspath(pad))
    fd, tijdelijk = tempfile.mkstemp(dir=map_, prefix=".redirects.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(tekst)
        os.chmod(tijdelijk, 0o644)
        os.replace(tijdelijk, pad)
    except BaseException:
        if os.path.exists(tijdelijk):
            os.unlink(tijdelijk)
        raise


def main(argv):
    if len(argv) == 3 and argv[1] == "check":
        if not os.path.isdir(argv[2]):
            print(f"  FOUT geen map {argv[2]}")
            return 1
        regels, fouten, waarschuwingen = keur_site(argv[2])
        meld(fouten, waarschuwingen)
        if not fouten:
            print(f"  ok   {BESTAND}: {len(regels)} redirect(s)")
        return 1 if fouten else 0
    if len(argv) == 4 and argv[1] == "generate":
        if not os.path.isdir(argv[2]):
            print(f"  FOUT geen map {argv[2]}")
            return 1
        regels, fouten, waarschuwingen = keur_site(argv[2])
        meld(fouten, waarschuwingen)
        if fouten:
            return 1
        schrijf(argv[3], map_tekst(regels))
        print(f"  ok   {BESTAND}: {len(regels)} redirect(s) naar {argv[3]}")
        return 0
    if len(argv) == 3 and argv[1] == "list":
        with open(argv[2], "rb") as f:
            regels, fouten = lees(f.read(MAX_BYTES + 1))
        if fouten:
            meld(fouten, [])
            return 1
        for r in regels:
            print(f"{r.nummer}\t{r.bron}\t{r.doel}\t{r.code}")
        return 0
    print("Gebruik: redirects.py check <sitemap> | generate <sitemap> <map-uit> | list <_redirects>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
