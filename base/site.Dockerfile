# Het image van een site: het basisimage van Notift plus de gebouwde map van de
# klant. Meer gebeurt er niet, en dat is doel 2 van docs/07-bouwlaag.md.
#
# Wordt gebruikt door de workflow, niet met de hand. De bouwcontext is de map
# waarin de workflow `site/` heeft klaargezet.

ARG BASE
FROM ${BASE}

ARG BUILD
ARG ORGANISATION
ARG PROJECT
ARG MODULE
ARG PLAN
ARG COMMIT
ARG REPO
ARG WORKFLOW

COPY site/ /usr/share/nginx/html/

# Redirects per pad (docs/07-bouwlaag.md). De workflow zette _redirects van de site om in deze map
# (checks/redirects.py), leeg als de site geen lijst heeft. Dan de poort uit het basisimage
# (base/redirects-gate.sh, vanaf versie 7): nginx -t met de echte nginx van het basisimage, en de eis dat
# nginx.conf de map werkelijk laadt. Een basisimage van voor de redirects heeft die poort niet, en dan
# stopt de build hier met de reden: de lijst zou anders stil niets doen. Rood hier is een geweigerde build;
# de site blijft op de vorige versie.
COPY redirects.map /etc/nginx/notift/redirects.map
RUN test -f /usr/local/lib/notift/redirects-gate.sh \
     || { echo "redirects: BASE is een basisimage van voor de redirects, zet BASE op versie 7 of later" >&2; exit 1; } \
 && sh /usr/local/lib/notift/redirects-gate.sh \
 && rm -rf /tmp/body /tmp/proxy /tmp/fastcgi /tmp/uwsgi /tmp/scgi

# Punt 3 van het artefactcontract: organisatie, project, module, plan, versie
# en de commit.
# De laatste twee zijn de herkomst uit doel 1 van de bouwlaag: welke repo en
# welke versie van de workflow dit image mocht maken.
LABEL nl.notift.organisation="$ORGANISATION" \
      nl.notift.project="$PROJECT" \
      nl.notift.module="$MODULE" \
      nl.notift.plan="$PLAN" \
      nl.notift.version="$BUILD" \
      nl.notift.commit="$COMMIT" \
      nl.notift.repo="$REPO" \
      nl.notift.workflow="$WORKFLOW"
