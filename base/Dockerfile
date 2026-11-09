# Het basisimage van Notift voor een statische site.
#
# Doel 2 van docs/07-bouwlaag.md: de klant levert een map, Notift levert de
# webserver. Er draait nooit een Dockerfile die een klant geschreven heeft.
#
# Dit image wordt eenmalig gebouwd en gepubliceerd. De workflow van een project
# gebruikt het als basis en kopieert er alleen de gebouwde map van de klant in.
#
# Wat dit image nakomt uit het artefactcontract in docs/06-runtime.md:
#   punt 4  een poort, een gezondheidspad, draait als gewone gebruiker, stopt netjes
#   punt 8  architectuur amd64, want de machines zijn x86

# nginx:1.29-alpine, vastgezet op de digest van de multi-arch index. Dependabot (docker) werkt hem bij.
# Een nieuwe digest raakt de sites pas als het basisimage opnieuw gebouwd en in build-and-publish.yml
# verwezen is (docs/07-bouwlaag.md, bevinding 6).
FROM nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de

COPY nginx.conf /etc/nginx/nginx.conf

# De standaard-404 hoort bij ons, niet bij de klant. Levert een klant een eigen
# 404.html, dan overschrijft die deze.
COPY 404.html /usr/share/nginx/html/404.html

# security.txt van Notift (zie nginx.conf). Eigen map, niet in de webroot van de klant.
# Expires zet de build: de builddatum plus 365 dagen, als build-arg uit base-image.yml (Leon, 19 oktober 2026).
# Zonder geldige waarde faalt de build; security-txt.sh is de enige render, ook voor de proef.
ARG SECURITY_TXT_EXPIRES
COPY security.txt security-txt.sh /tmp/notift-security/
RUN mkdir -p /etc/nginx/notift \
 && sh /tmp/notift-security/security-txt.sh render /tmp/notift-security/security.txt "$SECURITY_TXT_EXPIRES" > /etc/nginx/notift/security.txt \
 && grep -qx "Expires: $SECURITY_TXT_EXPIRES" /etc/nginx/notift/security.txt \
 && rm -rf /tmp/notift-security

# Redirects per pad: een lege lijst. De build van een site zet hier de map uit zijn _redirects
# (checks/redirects.py, site.Dockerfile); nginx.conf laadt hem binnen een map-blok.
# De poort (redirects-gate.sh) zit in hetzelfde image: base-image.yml en site.Dockerfile draaien hem, en een
# sitebuild op een basisimage van voor de redirects stopt omdat hij ontbreekt (N27-06, 22 oktober 2026).
COPY redirects.map /etc/nginx/notift/redirects.map
COPY redirects-gate.sh /usr/local/lib/notift/redirects-gate.sh

# Het entrypoint van de officiele nginx-image wordt bewust overgeslagen: dat
# schrijft naar /etc, en dat kan niet op een alleen-lezen bestandssysteem.
USER nginx
EXPOSE 8080
STOPSIGNAL SIGQUIT
ENTRYPOINT ["nginx", "-g", "daemon off;"]
