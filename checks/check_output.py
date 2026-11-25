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
import stat
import sys
from html.parser import HTMLParser

# Geen __pycache__ naast de bouwlaag: release.sh kopieert checks/ als geheel naar notift/build.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import redirects  # noqa: E402  (naast dit script, in de bouwlaag)

# ---------------------------------------------------------------------------
# Grenzen. Voorlopige waarden, bij te stellen zodra er echte sites doorheen gaan.

MIN_ZICHTBARE_TEKENS = 100        # een pagina die gevonden moet worden
MAX_AFBEELDING_BYTES = 500 * 1024
MAX_PAGINA_BYTES = 1_500 * 1024
MAX_JS_BYTES = 300 * 1024

AFBEELDINGEN = (".png", ".jpg", ".jpeg", ".webp", ".avif", ".gif", ".svg")

# Pagina's die niet gevonden hoeven te worden en dus geen tekst hoeven te hebben.
TECHNISCHE_PAGINAS = {"404.html", "500.html", "offline.html"}

# The manifest is a small JSON file; anything larger is refused before parsing (audit 2, finding N2).
MAX_MANIFEST_BYTES = 64 * 1024

# One log line of client-derived text, at most this many characters (audit 2, finding N7), and at most
# this many finding lines and error annotations per run (audit 3, N7), as in check_lovable.py.
MAX_LOG_LINE = 400
MAX_PRINTED = 300
MAX_ANNOTATIONS = 10


def safe_line(text, limit=MAX_LOG_LINE):
    """Client-derived text as one inert log line (audit 2, finding N7).

    Every character that is not printable (line breaks, other control characters, Unicode line and
    paragraph separators), every default-ignorable code point and the backslash itself become a visible
    escape. Then both workflow command syntaxes are broken wherever they appear in the line (audit 3, N7):
    '::' (the current form, a command when a line starts with it) becomes ':\\x3a', and '##[' (the legacy
    form, which the runner still finds anywhere in a line) becomes '#\\x23['. The escapes start with a
    backslash, so they cannot form a new '::' or '##['. The result is cut to `limit` characters.
    """
    out = []
    for ch in str(text):
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch.isprintable() and not _ignorable(code):
            out.append(ch)
        else:
            out.append(f"\\x{code:02x}" if code < 0x100 else f"\\u{code:04x}" if code < 0x10000 else f"\\U{code:08x}")
    line = "".join(out).replace("::", ":\\x3a").replace("##[", "#\\x23[")
    return line if len(line) <= limit else line[: limit - 3] + "..."


# Unicode Default_Ignorable_Code_Point ranges that Python still calls printable (most are format characters
# and escaped anyway). A culture-aware string search can skip them, so '#<ignorable>#[' could still read as
# '##[' to the runner; escaped, they are plain ASCII.
_IGNORABLE = ((0x034F, 0x034F), (0x115F, 0x1160), (0x17B4, 0x17B5), (0x180B, 0x180F), (0x3164, 0x3164),
              (0xFE00, 0xFE0F), (0xFFA0, 0xFFA0), (0xE0000, 0xE0FFF))


def _ignorable(code):
    return any(lo <= code <= hi for lo, hi in _IGNORABLE)


def annotation_data(text, limit=MAX_LOG_LINE):
    """safe_line, plus the escape GitHub defines for the data of a workflow command."""
    return safe_line(text, limit).replace("%", "%25")

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

# Deze waarden gaan vanuit het manifest naar een omgeving van de workflow. Ze
# zijn dus geen vrij stuk shelltekst. Een build zelf mag alleen een script van
# de gekozen pakketmanager starten; wie een afwijkende bouwvorm nodig heeft,
# voegt die als script aan package.json toe in plaats van shellsyntaxis aan dit
# contract toe te voegen.
VORMEN = {
    "organisation": r"^org_[0-9]{5}$",
    "project": r"^prj_[0-9]{5}$",
    "module": r"^mod_[0-9]{5}$",
    "plan": r"^[a-z][a-z0-9-]{0,62}$",
    "build.command": r"^(?:npm|pnpm|yarn|bun) run [A-Za-z0-9][A-Za-z0-9:_-]*(?: -- [A-Za-z0-9][A-Za-z0-9._:=@/+,-]*)*$",
    # Segments may start with a dot (.output/public, the TanStack Start/Nitro layout). Each segment is
    # checked separately below: no empty, '.', '..' or '.git' segment, so the output stays inside the repo.
    "build.output": r"^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$",
    "build.node": r"^[0-9]{1,2}(?:\.[0-9]+){0,2}$",
    "build.manager": r"^(?:npm|pnpm|yarn|bun)$",
    # An exact bun release, never a range or 'latest': the same manifest must give the same installer.
    "build.bun": r"^1\.[0-9]{1,2}\.[0-9]{1,3}$",
    "build.profile": r"^(?:static|lovable)$",
    "build.trigger": r"^(?:push|manual)$",
}

# Keys allowed in the build object. Anything else is refused, so a typo (instal_scripts) cannot silently
# fall back to a default. Keys starting with '$' are comments, as in notift.example.json.
BUILD_SLEUTELS = {"command", "output", "node", "manager", "bun", "profile", "trigger", "install_scripts"}

# Opt-in for dependency install scripts: an npm package name, exact, at most this many. Never a pattern.
PAKKETNAAM = r"^(?:@[a-z0-9][a-z0-9._-]{0,100}/)?[a-z0-9][a-z0-9._-]{0,100}$"
MAX_INSTALL_SCRIPTS = 10
# The modes install_deps.sh knows. Never accepted as a package name, even though the two travel apart.
INSTALL_MODI = {"none", "named", "legacy-all", "all"}
# Notift's own list of packages a site may name (audit finding 4: exceptions stay narrow and Notift's).
INSTALL_UITZONDERINGEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "install-scripts-allowed.txt")


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
    # Bounded before parsing, the file itself never through a link, and only a regular file (N2).
    try:
        fd = os.open(pad, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as e:
        sys.exit(f"het manifest is niet te openen als gewoon bestand ({e.strerror}): {pad}")
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            sys.exit(f"het manifest is geen gewoon bestand: {pad}")
        data = f.read(MAX_MANIFEST_BYTES + 1)
    if len(data) > MAX_MANIFEST_BYTES:
        sys.exit(f"het manifest is groter dan {MAX_MANIFEST_BYTES // 1024} KiB en wordt niet gelezen: {pad}")
    try:
        m = json.loads(data.decode("utf-8"))
    except ValueError as e:
        sys.exit(f"het manifest is geen geldige JSON in UTF-8 ({e.__class__.__name__}): {pad}")
    if not isinstance(m, dict):
        sys.exit(f"het manifest is geen JSON-object: {pad}")
    if "customer" in m:
        sys.exit("manifestveld 'customer' is vervallen; gebruik organisation, project en module")
    for veld in ("organisation", "project", "module", "plan", "package", "build"):
        if not m.get(veld):
            sys.exit(f"manifest mist het veld '{veld}': {pad}")
    if not isinstance(m["build"], dict):
        sys.exit("manifestveld 'build' moet een object zijn")
    for veld in ("command", "output"):
        if not m["build"].get(veld):
            sys.exit(f"manifest mist het veld 'build.{veld}': {pad}")
    onbekend = sorted(k for k in m["build"] if not k.startswith("$") and k not in BUILD_SLEUTELS)
    if onbekend:
        sys.exit(f"manifestveld 'build' kent deze sleutel niet: {', '.join(onbekend)}")
    m["build"].setdefault("node", "22")
    m["build"].setdefault("manager", "npm")
    m["build"].setdefault("profile", "static")
    lees_bouwprofiel(m["build"])
    m.setdefault("searchable", True)
    m.setdefault("allowed_public_keys", [])
    if not isinstance(m["searchable"], bool):
        sys.exit("manifestveld 'searchable' moet true of false zijn")
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
    waarden = {
        "organisation": m["organisation"],
        "project": m["project"],
        "module": m["module"],
        "plan": m["plan"],
        "build.command": m["build"]["command"],
        "build.output": m["build"]["output"],
        "build.node": m["build"]["node"],
        "build.manager": m["build"]["manager"],
    }
    for veld, waarde in waarden.items():
        if not isinstance(waarde, str) or not re.fullmatch(VORMEN[veld], waarde):
            sys.exit(f"manifestveld '{veld}' heeft ongeldige vorm: {waarde}")
    if any(deel in ("", ".", "..", ".git") for deel in m["build"]["output"].split("/")):
        sys.exit("manifestveld 'build.output' moet een gewone relatieve map zijn")
    for veld in ("bun", "profile", "trigger"):
        if veld in m["build"] and (
            not isinstance(m["build"][veld], str) or not re.fullmatch(VORMEN[f"build.{veld}"], m["build"][veld])
        ):
            sys.exit(f"manifestveld 'build.{veld}' heeft ongeldige vorm: {m['build'][veld]}")
    verwacht_pakket = f"ghcr.io/notift/{m['module']}"
    if m["package"] != verwacht_pakket:
        sys.exit(f"manifestveld 'package' moet exact '{verwacht_pakket}' zijn, niet '{m['package']}'")
    return m


def lees_bouwprofiel(build):
    """Profile, trigger and install scripts: strict, with defaults that keep existing sites unchanged.

    profile 'static' (default) is every site that built before this field existed. profile 'lovable' is a
    TanStack Start project from Lovable: bun with a pinned version, output exactly .output/public (so the
    server bundle in .output/server is never the output), built on request by default.
    """
    profiel = build["profile"]
    if not isinstance(profiel, str) or not re.fullmatch(VORMEN["build.profile"], profiel):
        sys.exit(f"manifestveld 'build.profile' heeft ongeldige vorm: {profiel}")
    manager = build["manager"]
    if manager == "bun":
        if "bun" not in build:
            sys.exit("manifestveld 'build.bun' ontbreekt: bij manager bun hoort een exacte versie, zoals 1.4.4")
        commando = build.get("command")
        if not isinstance(commando, str) or not commando.startswith("bun run "):
            sys.exit("manifestveld 'build.command' moet bij manager bun beginnen met 'bun run '")
    elif "bun" in build:
        sys.exit("manifestveld 'build.bun' hoort alleen bij manager bun")
    if profiel == "lovable":
        if manager != "bun":
            sys.exit("profiel lovable bouwt met bun en bun.lock: zet build.manager op bun")
        if build.get("output") != ".output/public":
            sys.exit("profiel lovable levert alleen .output/public: zet build.output op .output/public")
    build.setdefault("trigger", "manual" if profiel == "lovable" else "push")

    # Install scripts of dependencies. The manifest field stays 'build.install_scripts' ('none' or a list
    # of package names), but it travels to install_deps.sh as two separate values, so a package name can
    # never be read as a mode (audit finding 4):
    #   install_mode      none | named | legacy-all
    #   install_packages  space-separated names, empty unless install_mode is named
    # legacy-all is the explicit compatibility for a static npm/pnpm/yarn site whose manifest predates
    # the field: it keeps running every install script exactly as before. It cannot be chosen in the
    # manifest, only reached by leaving the field out.
    if "install_scripts" not in build:
        if profiel == "static" and manager != "bun":
            build["install_mode"], build["install_packages"] = "legacy-all", []
        else:
            build["install_mode"], build["install_packages"] = "none", []
        return
    keuze = build["install_scripts"]
    if keuze == "none":
        build["install_mode"], build["install_packages"] = "none", []
        return
    if not isinstance(keuze, list) or not keuze:
        sys.exit("manifestveld 'build.install_scripts' is 'none' of een lijst met pakketnamen")
    if manager == "bun":
        sys.exit("manifestveld 'build.install_scripts': een lijst kan nog niet bij bun; alleen 'none'")
    if len(keuze) > MAX_INSTALL_SCRIPTS or len(set(keuze)) != len(keuze):
        sys.exit(f"manifestveld 'build.install_scripts': hoogstens {MAX_INSTALL_SCRIPTS} verschillende pakketten")
    toegestaan = lees_installatie_uitzonderingen()
    for naam in keuze:
        if not isinstance(naam, str) or not re.fullmatch(PAKKETNAAM, naam) or naam in INSTALL_MODI:
            sys.exit(f"manifestveld 'build.install_scripts' bevat geen geldige pakketnaam: {naam}")
        if naam not in toegestaan:
            sys.exit(
                f"manifestveld 'build.install_scripts': {naam} staat niet op de lijst van Notift "
                f"(checks/{os.path.basename(INSTALL_UITZONDERINGEN)}); een uitzondering voegt Notift toe, niet de site"
            )
    build["install_mode"], build["install_packages"] = "named", list(keuze)


def lees_installatie_uitzonderingen(pad=None):
    """The Notift-owned list of packages whose install scripts a site may opt in to.

    It lives in the build layer (next to this script), so the client repo can only pick from it, never
    widen it. One exact package name per line, '#' starts a comment. Starts empty.
    """
    pad = pad or INSTALL_UITZONDERINGEN
    namen = set()
    try:
        with open(pad, encoding="utf-8") as fh:
            for regel in fh:
                regel = regel.split("#", 1)[0].strip()
                if not regel:
                    continue
                if not re.fullmatch(PAKKETNAAM, regel) or regel in INSTALL_MODI:
                    sys.exit(f"{os.path.basename(pad)} bevat geen geldige pakketnaam: {regel}")
                namen.add(regel)
    except FileNotFoundError:
        pass
    return namen


def github_output(manifestpad):
    """Geeft uitsluitend al op vorm getoetste workflowgegevens terug."""
    m = lees_manifest(manifestpad)
    waarden = {
        "organisation": m["organisation"],
        "project": m["project"],
        "module": m["module"],
        "plan": m["plan"],
        "package": m["package"].lower(),
        "command": m["build"]["command"],
        "output": m["build"]["output"],
        "node": m["build"]["node"],
        "manager": m["build"]["manager"],
        "bun": m["build"].get("bun", ""),
        "profile": m["build"]["profile"],
        "trigger": m["build"]["trigger"],
        # Two fields, never one: see lees_bouwprofiel. install_deps.sh refuses the old single field.
        "install_mode": m["build"]["install_mode"],
        "install_packages": " ".join(m["build"]["install_packages"]),
        # setup-node has no bun cache; an empty value turns caching off for that step.
        "cache": "" if m["build"]["manager"] == "bun" else m["build"]["manager"],
    }
    for naam, waarde in waarden.items():
        print(f"{naam}={waarde}")
    if m["build"]["install_mode"] == "legacy-all":
        # Explicit, so the compatibility is visible in every run until the site's manifest names a mode.
        print("::warning title=Install-scripts::install_scripts ontbreekt in het manifest: deze bestaande "
              "statische site draait alle install-scripts zoals voorheen (legacy-all). Zet 'none' zodra het kan.",
              file=sys.stderr)


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


def controleer_redirects(root, b):
    """Redirects per pad: een fout in _redirects weigert de build (besluit 106, docs/07-bouwlaag.md)."""
    _, fouten, waarschuwingen = redirects.keur_site(root)
    for f in fouten:
        b.weiger(str(f))
    for w in waarschuwingen:
        b.waarschuw(str(w))


def annoteer(soort, tekst):
    """Een GitHub-annotatie: de reden staat dan bovenaan de run. De mail van GitHub over de mislukte run
    gaat naar wie pushte en linkt naar de run (besluit 106)."""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::{soort} title=Controle van de uitvoer::{annotation_data(tekst)}")


def main():
    try:
        return _main()
    except SystemExit as e:
        # The validator reports with sys.exit(<reason>); a reason can carry client text (N7).
        if isinstance(e.code, str):
            print(safe_line(e.code), file=sys.stderr)
            annoteer("error", e.code)
            return 1
        raise


def _main():
    if len(sys.argv) == 3 and sys.argv[1] == "--github-output":
        github_output(sys.argv[2])
        return 0
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
    controleer_redirects(root, b)

    print(f"\n== Controle van {root} ==")
    print(f"  project {manifest['project']}, gevonden worden: "
          f"{'ja' if manifest['searchable'] else 'nee'}")

    regels = [0, 0]  # printed finding lines, annotations

    def meld(prefix, wat, waar, fout):
        tekst = wat + (f"  [{waar}]" if waar else "")
        if regels[0] < MAX_PRINTED:
            print(safe_line(f"    {prefix}  {tekst}"))
            regels[0] += 1
        if fout and regels[1] < MAX_ANNOTATIONS:
            annoteer("error", tekst)
            regels[1] += 1

    if b.waarschuwingen:
        print(f"\n  {len(b.waarschuwingen)} waarschuwing(en):")
        for wat, waar in b.waarschuwingen:
            meld("let op", wat, waar, False)

    if b.weigeringen:
        print(f"\n  {len(b.weigeringen)} reden(en) om niet te publiceren:")
        for wat, waar in b.weigeringen:
            meld("FOUT  ", wat, waar, True)
    totaal = len(b.waarschuwingen) + len(b.weigeringen)
    if totaal > regels[0]:
        print(f"\n  {totaal - regels[0]} melding(en) niet getoond.")
    if b.weigeringen:
        print("\n  Er wordt niets gepubliceerd.\n")
        return 1

    print(f"\n  Goedgekeurd, met {len(b.waarschuwingen)} waarschuwing(en).\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
