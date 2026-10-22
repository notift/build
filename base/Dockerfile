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

# Het entrypoint van de officiele nginx-image wordt bewust overgeslagen: dat
# schrijft naar /etc, en dat kan niet op een alleen-lezen bestandssysteem.
USER nginx
EXPOSE 8080
STOPSIGNAL SIGQUIT
ENTRYPOINT ["nginx", "-g", "daemon off;"]
