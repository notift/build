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
| `checks/check-private-image-proof.sh` | Tegenproef voor doel 3: publiek rood en privaat groen op dezelfde meting |
| `embed/forms.js` | Het formulierscript. Job 2 zet het in elk site-image op `/_notift/embed/forms.js`, over wat de klant daar neerzette (`docs/11-formulieren.md`, build 23) |
| `checks/forms-embed-proof.sh` | Draait die stap uit de workflow tegen een geplant script en meet het resultaat met de nginx.conf van het basisimage |
| `workflow/build-and-publish.yml` | De herbruikbare workflow die elk project aanroept. Twee jobs, en dat is een grens |
| `workflow/base-image.yml` | Het basisimage bouwen en publiceren. Met de hand te starten, niet vanzelf |
| `notift.example.json` | Het manifest dat in de repo van een project komt |
| `release.sh` | Zet deze map in de repo `notift/build`. Gaat zelf niet mee |
| `verify.sh` | De stand bij GitHub, afleesbaar zonder door instellingenpagina's te klikken |

```
./checks/check-output-proof.sh                       eenentwintig gevallen, weigeren en waarschuwen
./checks/check-private-image-proof.sh                publieke en private tegenproef voor de afschermingsmeting
./checks/build-layer-proof.sh                         manifestinjectie, vaste hash en werkmapgrens
./checks/forms-embed-proof.sh                         het formulierscript komt uit de bouwlaag, niet van de klant
./checks/release-signing-proof.sh <map>               release.sh en restore-release.sh pushen alleen een ondertekende commit
python3 checks/check_output.py dist notift.json      een echte uitvoer keuren
./release.sh                                         tonen wat er naar notift/build zou gaan
./release.sh --push v1                               publiceren en de tag verplaatsen
./restore-release.sh <commit> --push v1              een eerdere publicatie terugzetten, ondertekend
./verify.sh                                          de stand bij GitHub
./verify.sh mod_90001                                en die module erbij
```

**Na elke `release.sh --push v1`:** niets met de hand. `release.sh` tekent de commit in `notift/build`
met Leons signeersleutel en pusht alleen als de handtekening klopt. Op `platform-01` haalt
`approve-build.sh` elke vijf minuten `v1` op, controleert de handtekening zelf en zet de commit dan
op de lijst toegestane bouwversies. Zie "Ondertekende releases" hieronder. De oude versie pas
intrekken (`retire_build_workflow`, als admin) als alle sites opnieuw gebouwd zijn; wat er al met de
oude gebouwd is, blijft terugrolbaar.

## Ondertekende releases

Besluit Leon, 19 oktober 2026 (keuze L4 optie c): **een versie van de bouwlaag is vrijgegeven als en
alleen als de commit in `notift/build` ondertekend is met Leons sleutel.** Wie GitHub, deze repo of
`notift/build` overneemt, heeft de privésleutel niet, en een overgenomen dashboard of werker kan de
lijst niet meer bijwerken.

| Stap | Waar | Wat |
|---|---|---|
| 1 | Mac, `release.sh --push v1` | `git commit -S` met de sleutel uit Leons git-config (alleen in een kloon van `notift/build`), daarna dezelfde controle als op de server. Niet goed ondertekend: niets gepusht, ook de tag niet |
| 2 | `platform-01`, cron elke 5 minuten | `approve-build.sh` haalt `refs/tags/v1` op met git (elk object wordt op zijn hash gecontroleerd) |
| 3 | idem, elke ronde, ook als de commit al op de lijst staat | `lib/build_signature.py`: de hash van het ruwe commit-object narekenen, de handtekening eruit halen zoals git dat doet, en `ssh-keygen -Y verify -n git` tegen `/etc/notift/build-signers`. Het veld `verified` van GitHub wordt nergens gelezen |
| 4 | idem | Goed: de database vragen of de commit al bekend is, en zo niet `dashboard.allow_signed_build_workflow` als `dashboard_build_signer` (alleen postgres, dus alleen root, is lid). Fout: een regel in het journaal (`journalctl -t notift-build-approve`) en een mail aan `NOTIFY_EMAIL` via de werker, een keer per versie, code en stand van de versie (onbekend, actief, ingetrokken; bij elke wissel van stand opnieuw) |

**Alleen ondertekende versies op de lijst (Codex-audit 29).** Migratie 019 trekt de versies van voor 019 in (ze
hebben geen ondertekenaar), en een check in de database houdt elke actieve versie ondertekend. Een `v1` die terugwijst
naar zo'n oude commit geeft dus een weigering en een mail, en een build op die versie wordt niet aangenomen. Wat al
draait blijft draaien en blijft terugrolbaar: de werker leest de versie van de release zelf, niet de lijst. De prijs:
tussen migratie 019 en de eerste ondertekende release neemt het platform geen enkele build aan.

**Een sleutel weghalen trekt niets in (Codex-audit 31).** De lijst is het verslag van de controle op het moment van
vrijgeven, zoals bij GitHub een geverifieerde commit geverifieerd blijft als de sleutel later wordt ingetrokken. Zonder
de sleutel in `build-signers` geeft de server niets nieuws meer vrij, maar wat al op de lijst stond blijft vrijgegeven en
`receive_release` neemt er builds mee aan. Intrekken is een aparte handeling: `retire_build_workflow`. Wijst `v1` naar
zo'n versie, dan weigert elke ronde (exit 1), met een tweede journaalregel `... blijft vrijgegeven: een weigering trekt
een eerdere vrijgave niet in` en één mail "bouwversie ... blijft vrijgegeven, controle geweigerd (unknown_key)". Waarom
zo: een intrekking komt via deze weg nooit terug, dus hoort ze niet vast aan het bewerken van een bestand. De prijs: bij
een gelekte sleutel blijft wat die sleutel vrijgaf geldig tot je het intrekt (hieronder, "De Mac is kwijt", stap 2).

**Wat dit niet tegenhoudt:** wie root is op `platform-01`, kan ook zonder handtekening in de database
schrijven. Dat geldt voor elke controle op die machine; de handtekening beschermt tegen GitHub, de
repo's, het dashboard en de werker, niet tegen root.

**Een ingetrokken versie komt via deze weg nooit terug.** Terug naar een oude bouwlaag gaat met
`restore-release.sh <oude commit in notift/build> --push v1`: dat zet precies de boom van die oude commit in een
nieuwe, ondertekende commit, met dezelfde controle als `release.sh`. Niet met `release.sh` vanaf een oude
hostingcommit: die van voor de ondertekende releases tekent niet, en een nieuwe `release.sh` op een oude
`infra/build` stopt op de map `embed` (Codex-audit 29). Verplaats `v1` nooit met de hand naar een oude commit.

### Sleutel wisselen (gepland)

1. Nieuwe sleutel maken zoals bij de eenmalige stappen, met een nieuwe naam.
2. De nieuwe publieke sleutel **erbij** in `infra/dashboard/build-signers` (twee regels), committen.
3. `scp infra/dashboard/build-signers platform-01:`, dan in de sessie
   `sudo bash /opt/notift-dashboard/install-approve-build.sh ~/build-signers`. Die controleert het bestand
   en plaatst het pas daarna.
4. In de git-config van `notift/build` `user.signingkey` naar de nieuwe sleutel, en een release doen.
5. Pas daarna de oude regel weghalen en stap 3 herhalen. Wat met de oude sleutel is vrijgegeven, blijft
   vrijgegeven (een sleutel weghalen trekt niets in). `v1` moet dan al op de release van stap 4 staan:
   `approve-build.sh` controleert `v1` elke ronde, en een `v1` met de oude sleutel geeft na het weghalen
   `unknown_key` en een mail "blijft vrijgegeven, controle geweigerd"; de versie blijft bruikbaar.

### De Mac is kwijt (of de sleutel is misschien gelekt)

1. **Eerst dicht voor nieuwe vrijgaven:** de oude regel uit `/etc/notift/build-signers` halen. Zonder sleutel
   geeft de server niets nieuws meer vrij. **Dit trekt niets in:** wat de oude sleutel al vrijgaf, ook `v1`, blijft
   vrijgegeven en neemt builds aan tot stap 2. Elke ronde meldt dan `unknown_key` voor `v1` (een mail per versie,
   "blijft vrijgegeven"); dat is verwacht tot de release met de nieuwe sleutel. Kan dat niet via `ssh` (de serversleutel zat ook op
   de Mac), dan via de console van Hetzner.
2. Nagaan wat de oude sleutel vrijgaf sinds het verlies:
   `select workflow_sha, added_at from dashboard.build_workflows where signer_fingerprint = '<oude SHA256>' order by added_at;`
   en wat niet van Leon is intrekken met `retire_build_workflow`. Dit is de stap die een gelekte sleutel echt
   dichtzet; stap 1 alleen doet dat niet.
3. Op de nieuwe Mac: een nieuwe signeersleutel (eenmalige stappen), de publieke sleutel in
   `infra/dashboard/build-signers` in plaats van de oude, committen, en installeren zoals bij de wissel.
4. `sudo /opt/notift-dashboard/verify.sh platform-01` meet dat het bestand op de server gelijk is aan de
   repo.

## Waarom er een `verify.sh` is voor deze laag

**Dit is de eerste laag die we niet bezitten.** Bij onze eigen machines is "staat het er echt" een
script; bij GitHub was het een pagina in een browser. Op 4 september 2026 stonden er drie dingen
stil verkeerd, en geen ervan was zichtbaar in de code hier:

| | Wat er stil fout stond |
|---|---|
| 1 | Het deployeraccount had **schrijfrecht** op deze repo in plaats van leesrecht |
| 2 | `access_level` stond op `none`, dus geen enkele repo mocht de workflow aanroepen |
| 3 | De repo was prive, waardoor een projectrepo hem niet kon uitchecken |

En bij de overstap naar de organisatie, diezelfde dag, nog drie:

| | Wat er stil fout stond |
|---|---|
| 4 | De oude pakketten **hielden de pakketnaam bezet**, en de organisatie mocht er niet op publiceren |
| 5 | Een nieuw pakket onder een organisatie staat op **prive**. De build werd groen en het gat bleef |
| 6 | De standaardrechten van de organisatie stonden op **read**, dus een lid zag elke repo |

Alle drie geven nu rood. Wat het script **niet** nakijkt staat onderaan zijn eigen uitvoer, want een
controle die zwijgt over wat hij niet ziet is de gevaarlijkste soort.

## Waar deze map en de repo `notift/build` zich toe verhouden

**Deze map is de bron.** `notift/build` is een kopie, want GitHub kan een herbruikbare workflow
alleen aanroepen als hij in `.github/workflows/` in de wortel van een repo staat. Waarom dat een
aparte repo is en niet `notift-hosting`: zie "Waar deze laag naartoe groeit" in
`docs/07-bouwlaag.md`.

`release.sh` doet die kopie in een keer, en bouwt hem eerst op in een lege map voordat de repo
wordt aangeraakt. Daarna vergelijkt hij een vingerafdruk over alle bestanden en hun paden met een
waarde die vooraf vaststond. Twee plekken die met de hand gelijk gehouden worden, lopen uit elkaar,
en dan bouwt een klant met code die hier niet staat.

| Hier | Daar |
|---|---|
| `base/`, `checks/`, `notift.example.json` | Hetzelfde |
| `workflow/*.yml` | `.github/workflows/*.yml` |
| `README.md` | Hetzelfde, met een kop erboven dat het een kopie is |
| `release.sh` | Gaat niet mee |

**De tag `v1` verplaatsen is een aparte handeling**, en met opzet. Elke projectworkflow wijst naar
die tag, dus verplaatsen raakt in een keer elke klant. Binnen één run wordt die tag precies eenmaal
naar een commit-hash opgelost. Beide jobs halen daarna die hash op; job 2 weigert als zijn checkout
niet exact die commit is. Een release tussen de jobs kan een lopende build dus niet veranderen.

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
| 8 | `publiceren` | De samenvatting en workflowoutputs geven de volledige digestreferentie plus alle herkomst voor de platformopdracht |

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

## De grens rond het manifest

Het manifest is invoer van de klant en geen stukje workflow. Elke waarde krijgt daarom bij het
lezen een vaste vorm: organisatie, project en module hebben hun codevorm, het pakket moet precies
bij de module horen, het plan heeft alleen kleine letters/cijfers/streepjes, en de bouwvorm is een
`npm`, `pnpm` of `yarn`-script met veilige argumenten. Uitvoer is een gewone relatieve map. Daarna
gaan de waarden alleen via omgevingsvariabelen naar een `run:`-stap; er staat geen expression uit
het manifest in shelltekst.

De bouwlaag zelf wordt buiten de werkmap van het project uitgecheckt. Een klant die alles naar
`dist` kopieert kan daardoor geen `.notift`-proefbestanden meenemen. `build-layer-proof.sh` wijzigt
ieder manifestveld met shellsubstitutie, backticks, puntkomma, newline en `../`, en bewijst dat ze
allemaal al bij het lezen falen.

## Wat de volgende laag uit een publicatie krijgt

De reusable workflow geeft naast `digest` en `build` ook `image`, `module`, `project`, `package`,
`repository`, `ref`, `commit`, `workflow`, `run_id` en `run_attempt` terug. `image` is altijd de
volledige vorm `ghcr.io/notift/mod_00001@sha256:...`; een tag is nooit een uitrolopdracht.

De platformontvanger moet vóór hij een opdracht opslaat controleren dat de ondertekende repo bij
de module hoort, dat package en module exact overeenkomen, en dat `ref` precies
`refs/heads/main` is. `deploy.sh` moet dezelfde repo- en workflowtoelating uit de moduleconfiguratie
controleren, naast de bestaande label- en identiteitscontrole. Labels alleen zijn verklaringen van
de bouwer, geen bewijs. Deze ronde bouwt die runtime- en platformcontroles bewust niet.

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

De uitzonderingenlijst kent vandaag alleen `supabase_anon_key`: de waarde moet een leesbare JWT met
rol `anon` zijn. Een ander opgegeven type, een verkeerd type bij de waarde, een onleesbare JWT, een
`sk_`-sleutel of een `service_role`-sleutel faalt al bij het lezen van het manifest. De lijst is
geen manier om een geheim alsnog goed te keuren.

Bij `./verify.sh mod_...` meet de modulecontrole in zes afzonderlijke regels: bestaat het
containerpakket, noemt GitHub het private, is er een bestaande digest, kan de ingelogde weg die
digest ophalen, weigert de anonieme weg diezelfde digest, en kwam er werkelijk een HTTP-antwoord.
De oude controle vroeg `latest` op, terwijl de workflow alleen buildnummers en digests publiceert.
Een publiek pakket zonder tag `latest` gaf daardoor 404 en ten onrechte groen. Een onbekend pakket,
lege versielijst of netwerkfout is nu een fout, nooit bewijs van afscherming.

`check-private-image-proof.sh` draait diezelfde zes metingen aan beide kanten. Op het bestaande
publieke containerpakket `notift/static-base` horen stappen 2 en 5 rood te zijn: GitHub zegt
`public` en de anonieme aanvraag van een bestaande digest krijgt HTTP 200. Op `mod_90001` horen
stappen 1 tot en met 6 groen te zijn; GHCR weigert daar al bij het tokenpunt met geldige
`UNAUTHORIZED`-JSON. Beide uitkomsten bewijzen iets anders en samen tonen ze dat de controle
publiek werkelijk afkeurt én privaat werkelijk kan goedkeuren. De proef verandert niets bij GitHub
en stopt met een fout als `gh` niet beschikbaar of niet ingelogd is.

## Wat Leon nog moet doen voordat dit voor het eerst draait

| | Wat | Waar |
|---|---|---|
| 1 | ~~Een repo `notift/build` aanmaken met een tag `v1`~~ **Gedaan 2026-09-04.** **Publiek**, want een projectrepo kan een prive workflow-repo niet uitchecken. `v1` staat en publiceren gaat met `release.sh`. **Er komt nooit iets in deze repo dat niet openbaar mag zijn** | GitHub |
| 2 | ~~Elke `uses:` vastzetten op een commit-hash~~ **Gedaan 2026-09-04.** Alle vier de actions staan vast op een hash, met de versie als commentaar erachter. Meteen ook naar de actuele hoofdversie, want alle vier stonden een major achter en draaien nu op node24. Nagekeken dat elke invoerwaarde die wij gebruiken daar nog bestaat | `workflow/build-and-publish.yml` |
| 3 | ~~Het basisimage publiceren~~ **Gedaan 2026-09-04.** Staat sinds 1 oktober op **versie 6**, digest `sha256:64f027ff`: `$uri.html` voor `$uri/`, want een pagina naast een map van dezelfde naam liep in een lus. Versie 5 (`sha256:2cc3dd81`, 24 september) bracht doorverwijzingen zonder de interne poort, en een 301 voor een slash aan het eind en voor `.html`. Versie 4 (`sha256:a36a47e5`) stuurde `/` in een lus naar zichzelf en is vervangen. Versie 3 (`sha256:31bcdc43`) was de eerste die werkelijk van de organisatie is. Versie 1 en 2 zijn weg: die hoorden bij het gebruikersaccount en hielden de naam bezet. Nagemeten op het gepubliceerde image: geen root, poort 8080, `/_health` antwoordt vanuit een alleen-lezen container, en een niet-bestaande pagina geeft 404 en geen 200 | Eenmalig |
| 4 | ~~Het deployeraccount en het token~~ **Gedaan 2026-09-04.** `notift-deploy` is **lid van de organisatie** met Read op het pakket `prj_00001`. Lid worden was nodig omdat een organisatie pakkettoegang alleen aan leden en teams geeft. Het kan alleen veilig doordat de standaardrechten van de organisatie op `none` staan, anders had dit account leesrecht op elke repo gekregen. Het token staat in `/root/.docker/config.json` op `web-01` en `platform-01` en **verloopt op 2026-12-03**. Vernieuwen: `token-renewal.md`. Per nieuw project moet de pakkettoegang opnieuw gegeven worden, en daar is geen API voor | GitHub plus de machine |
| 5 | Per project een `notift.json` en een workflow van drie regels die de onze aanroept. Zie `notift/testsite` als voorbeeld dat werkt | Per klant |

Punt 4 is een bewuste keuze en geen gemak: zie doel 3 in `docs/07-bouwlaag.md`, met de reden en de
trigger om het later strakker te zetten.

## Wat hier nog niet staat

**Opruimen van oude versies op `ghcr.io` en het intrekken bij vertrek, doel 8.** Elke build laat een
versie achter in het pakket, en niets ruimt die op. Bij een site die vaak publiceert groeit dat door.

**Uitrollen zonder serverlogin.** Dat is de aansturingslaag, niet deze laag. De workflow print aan
het eind een commando dat iemand met de hand uitvoert.

**Een build voor een klant zonder `package.json`.** De workflow draait altijd `setup-node` en
`npm ci`, dus kant-en-klare HTML zonder afhankelijkheden komt er nu niet doorheen. Doel 2 zegt dat
zo'n klant erbij hoort, dus dit is een gat en geen keuze.

De proef op de echte keten is **gedaan** op 4 september 2026, met `notift/testsite`. Zie
"Wat de eerste proef moet aantonen" in `docs/07-bouwlaag.md`.

## Ondertekende stagingmelding, ronde C

Na het publiceren roept de publicatiejob `checks/notify_deployment.py` aan. Die tekent de ruwe
UTF-8 JSON-body met HMAC-SHA-256 over `<timestamp>.<body>` en POST naar de vaste URL
`https://app.notift.nl/api/deployments`. Het event-id staat in body en header.
Alleen `refs/heads/main` meldt staging. HTTP 202 is groen; weigering, redirect of netwerkfout is rood.
De sender drukt geen responsebody, signature of geheim af; het geheim komt uitsluitend uit zijn env.

`NOTIFT_DEPLOY_SECRET` is een optioneel workflow_call-secret. Zonder geheim geeft de stap een
zichtbare `::warning::` en exit 0, zodat de bestaande vier sites blijven publiceren. Per gekoppelde
klantrepo moet de aanroep het geheim expliciet doorgeven, uitsluitend aan deze reusable workflow:

```yaml
jobs:
  publiceren:
    uses: notift/build/.github/workflows/build-and-publish.yml@v1
    permissions:
      contents: read
      packages: write
    secrets:
      NOTIFT_DEPLOY_SECRET: ${{ secrets.NOTIFT_DEPLOY_SECRET }}
```

De sender reist met de bestaande kopie van `checks/` in `release.sh`; geen wijziging van release.sh
nodig. Geef na het verplaatsen van v1 de nieuwe bouwlaaghash vrij via het dashboard-adminscript.
De job zonder gekoppeld geheim blijft groen. Met een geheim moet het dashboard al met de nieuwe
platformsleutel draaien. Het serverdraaiboek staat in `docs/prompts/geheel-build-10-oplevering.md`.
