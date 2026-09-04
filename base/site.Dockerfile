# Het image van een site: het basisimage van Notift plus de gebouwde map van de
# klant. Meer gebeurt er niet, en dat is doel 2 van docs/07-bouwlaag.md.
#
# Wordt gebruikt door de workflow, niet met de hand. De bouwcontext is de map
# waarin de workflow `site/` heeft klaargezet.

ARG BASE
FROM ${BASE}

ARG BUILD
ARG PROJECT
ARG CUSTOMER
ARG PLAN
ARG COMMIT
ARG REPO
ARG WORKFLOW

COPY site/ /usr/share/nginx/html/

# Punt 3 van het artefactcontract: klant, project, plan, versie en de commit.
# De laatste twee zijn de herkomst uit doel 1 van de bouwlaag: welke repo en
# welke versie van de workflow dit image mocht maken.
LABEL nl.notift.customer="$CUSTOMER" \
      nl.notift.project="$PROJECT" \
      nl.notift.plan="$PLAN" \
      nl.notift.version="$BUILD" \
      nl.notift.commit="$COMMIT" \
      nl.notift.repo="$REPO" \
      nl.notift.workflow="$WORKFLOW"
