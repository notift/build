#!/bin/sh
# The gate for redirects per path (docs/07-bouwlaag.md, besluit 106). It ships in the base image from
# version 7 on, at /usr/local/lib/notift/redirects-gate.sh, so that the base image and its own check are
# one release: base-image.yml runs it on a test site on the published image, and site.Dockerfile runs it
# after it copied the map of the site. A site build on a base image without this file stops there.
#
# 1. nginx -t with the real nginx and nginx.conf of the image: a broken map refuses the build.
# 2. nginx.conf loads the map for real. Without this, a list on a base image that does not include the
#    map would pass nginx -t and silently do nothing.
#
# Arguments go to nginx unchanged (the proof on the Mac passes -c and -e). NOTIFT_REDIRECTS_MAP is the
# path the include has to name. Exit 0 only when both hold. Runs under the sh of the image (busybox).
set -eu
map="${NOTIFT_REDIRECTS_MAP:-/etc/nginx/notift/redirects.map}"

if ! nginx -t -q "$@"; then
  echo "redirects: nginx -t is rood, de map van _redirects of nginx.conf klopt niet" >&2
  exit 1
fi
# Captured first, then searched: no early exit of grep against a writing nginx.
if ! dump="$(nginx -T "$@" 2>/dev/null)"; then
  echo "redirects: nginx -T faalde" >&2
  exit 1
fi
if ! printf '%s\n' "$dump" | grep -qxF "# configuration file $map:"; then
  echo "redirects: nginx.conf laadt $map niet, een lijst zou stil niets doen" >&2
  exit 1
fi
