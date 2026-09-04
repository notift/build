<!-- Deze map is een kopie. Bewerk hem niet hier. -->

> **Dit is een gepubliceerde kopie.** De bron is `infra/build/` in de prive repo
> `notift/notift-hosting`, en die wordt hierheen gezet met `release.sh`. Een wijziging
> die je hier maakt, is bij de volgende publicatie weg.
>
> Verwijzingen naar `docs/...` hieronder wijzen naar die bron en werken hier niet.

# infra/build

De bouwlaag als code. Het ontwerp staat in `docs/07-bouwlaag.md`.

Deze laag draait niet op onze machines. Hij draait op een tijdelijke machine van GitHub die na de
build wordt weggegooid. Wat hij aflevert is een image op `ghcr.io` dat het artefactcontract uit
`docs/06-runtime.md` nakomt.

| Bestand | Wat |
|---|---|
| `base/Dockerfile` | Het basisimage van Notift: nginx, alleen-lezen, als gewone gebruiker |
| `base/nginx.conf` | De webserverconfiguratie. Schrijft alleen naar `/tmp`, en serveert vooraf gecomprimeerde bestanden |
| `base/404.html` | De standaardpagina voor niet gevonden. Een klant kan hem overschrijven |
| `base/site.Dockerfile` | Het image van een site: het basisimage plus de gebouwde map, met de labels |
| `checks/check_output.py` | Doel 4: keurt de uitvoer van de build. Weigert of waarschuwt |
| `checks/check-output-proof.sh` | Het bewijs dat die controle werkelijk weigert. Draait op de Mac |
| `workflow/build-and-publish.yml` | De herbruikbare workflow die elk project aanroept. Twee jobs, en dat is een grens |
| `notift.example.json` | Het manifest dat in de repo van een project komt |

```
./checks/check-output-proof.sh                       zestien gevallen, weigeren en waarschuwen
python3 checks/check_output.py dist notift.json      een echte uitvoer keuren
```

## Hoe het loopt

| | Job | Stap |
|---|---|---|
| 1 | | Iemand pusht naar de repo van een project |
| 2 | | De workflow van dat project roept die van Notift aan, vastgezet op een versie |
| 3 | `bouwen` | Het manifest zegt wat er gebouwd moet worden en waar de uitvoer komt |
| 4 | `bouwen` | De build draait, en daarna wordt **de werkelijke uitvoer** gekeurd |
| 5 | `bouwen` | Die uitvoer gaat als artefact naar de volgende job |
| 6 | `publiceren` | De uitvoer wordt **opnieuw gekeurd**, gecomprimeerd en gestempeld met het buildnummer |
| 7 | `publiceren` | Het basisimage plus die map wordt gepubliceerd op `ghcr.io`, met alle labels |
| 8 | `publiceren` | De samenvatting toont de digest en het commando om uit te rollen |

Stap 4 raadt niets uit de broncode. Een voorspelling op basis van bestanden in een repo heb je
soms mis, en dan wijs je een klant af die wel gehost had kunnen worden.

## Waarom twee jobs

**Dit is een grens en geen opmaak.** In `bouwen` draait de code van de klant: een `npm install`
voert scripts uit die hij geschreven heeft. Die job heeft daarom alleen `contents: read` en ziet
het publicatietoken nooit.

In `publiceren` draait geen enkele regel van de klant. Daar ligt `packages: write`, en verder
alleen dingen uit onze eigen repo.

| | Wat dat oplevert |
|---|---|
| 1 | Code van een klant kan het token waarmee gepubliceerd wordt niet lezen |
| 2 | De Dockerfile komt uit onze repo en niet uit het artefact, want dat artefact komt uit een job waar vreemde code in draaide |
| 3 | Het buildnummer wordt in job 2 gestempeld, dus de klant kan het niet schrijven |
| 4 | Het manifest wordt in job 2 vers uit de repo gelezen, niet doorgegeven via job 1 |

**Waarom de uitvoer twee keer gekeurd wordt:** het artefact is de brug tussen de twee jobs. Wat in
job 1 goedgekeurd is, hoeft niet te zijn wat er in job 2 uit komt. Dat kost een paar seconden.

**De prijs:** ongeveer een minuut extra per build, want GitHub rondt per job af naar hele minuten.
Plus de tijd om het artefact heen en weer te zetten. Dat is meegerekend in de kostentabel in
`docs/07-bouwlaag.md`.

Dit is ook de voorwaarde voor variant C en voor een eigen bouwmachine. Zie "Waar deze laag naartoe
groeit" in `docs/07-bouwlaag.md`.

## Wat weigert en wat waarschuwt

**Weigert:** geen uitvoermap of geen `index.html`, een pagina zonder zichtbare tekst terwijl hij
gevonden moet worden, een pagina zonder titel, een `.env` in de uitvoer, een geheime sleutel, een
`service_role`-sleutel, een publieke sleutel die niet in het manifest staat, en een privesleutel.

**Waarschuwt:** een afbeelding boven een half MB, meer dan 300 KB JavaScript, een gepubliceerde
bronkaart, een verwijzing naar een bestand dat niet bestaat, en een ontbrekende omschrijving, kop
of taalaanduiding.

**Waarom geen algemene entropietoets op geheimen:** die vindt ook de gehashte bestandsnamen en de
brokken minified JavaScript die in elke build zitten. Dan blokkeer je een klant op een vals alarm,
en dat is erger dan de dekking die je ermee wint. Wat hier gezocht wordt zijn vormen die niets
anders kunnen zijn dan een sleutel.

**Wat deze controle nooit kan:** bewijzen dat er geen geheim in zit. Hij vindt bekende vormen, niet
alles.

## Wat Leon nog moet doen voordat dit voor het eerst draait

| | Wat | Waar |
|---|---|---|
| 1 | Een repo `notift/build` aanmaken en deze map erin zetten, met een tag `v1`. **Prive**, en de workflow moet in `.github/workflows/` in de wortel komen te staan, niet in `workflow/`. Waarom een aparte repo: zie "Waar deze laag naartoe groeit" in `docs/07-bouwlaag.md` | GitHub |
| 2 | ~~Elke `uses:` vastzetten op een commit-hash~~ **Gedaan 2026-09-04.** Alle vier de actions staan vast op een hash, met de versie als commentaar erachter. Meteen ook naar de actuele hoofdversie, want alle vier stonden een major achter en draaien nu op node24. Nagekeken dat elke invoerwaarde die wij gebruiken daar nog bestaat | `workflow/build-and-publish.yml` |
| 3 | Het basisimage bouwen en publiceren als `ghcr.io/notift/static-base:1` | Eenmalig |
| 4 | Een deployeraccount met leesrecht op de pakketten, en dat token op `web-01` zetten | GitHub plus de machine |
| 5 | Per project een `notift.json` en een workflow van drie regels die de onze aanroept | Per klant |

Punt 4 is een bewuste keuze en geen gemak: zie doel 3 in `docs/07-bouwlaag.md`, met de reden en de
trigger om het later strakker te zetten.

## Wat hier nog niet staat

Opruimen van oude versies op `ghcr.io` en het intrekken bij vertrek, doel 8. En de proef op de
echte keten: een push die tot een draaiende site leidt. Dat is de volgende stap, en die vraagt
GitHub-toegang.
