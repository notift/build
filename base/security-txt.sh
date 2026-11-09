#!/bin/sh
# security.txt van Notift: Expires zet de build van het basisimage, niet de hand (Leon, 19 oktober 2026).
# Eén bron voor de Dockerfile (render), de workflow base-image.yml (expires, check) en de proef op de Mac.
#
#   security-txt.sh expires [JJJJ-MM-DD]          de builddatum (standaard vandaag, UTC) plus 365 dagen, ISO 8601 in UTC
#   security-txt.sh render <sjabloon> <expires>   het bestand op stdout; weigert een expires die geen ISO 8601 in UTC is
#   security-txt.sh check <bestand> [nu-epoch]    Contact van Notift, en Expires loopt nog minstens 180 dagen (vangnet)
#
# POSIX sh: de render draait in nginx:alpine (busybox), expires en check op Ubuntu (GNU date) en op de Mac (BSD date).
set -eu
ISO='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.000Z$'
MIN_DAYS=180
die() { printf 'security-txt: %s\n' "$*" >&2; exit 1; }
# epoch <JJJJ-MM-DDTHH:MM:SS>: GNU date of BSD date, altijd UTC.
epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%S' "$1" +%s 2>/dev/null || die "datum onleesbaar: $1"; }
case "${1:-}" in
  expires)
    day="${2:-$(date -u +%Y-%m-%d)}"
    printf '%s\n' "$day" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || die "builddatum is geen JJJJ-MM-DD: $day"
    e=$(( $(epoch "${day}T00:00:00") + 365 * 86400 ))
    date -u -d "@$e" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%S.000Z
    ;;
  render)
    [ "$#" = 3 ] || die "gebruik: $0 render <sjabloon> <expires>"
    printf '%s\n' "$3" | grep -Eq "$ISO" || die "Expires ontbreekt of is geen ISO 8601 in UTC: '$3'"
    [ "$(grep -c '^Expires: @EXPIRES@$' "$2")" = 1 ] || die "sjabloon $2 heeft niet precies één regel 'Expires: @EXPIRES@'"
    sed "s/^Expires: @EXPIRES@\$/Expires: $3/" "$2"
    ;;
  check)
    [ -r "${2:-}" ] || die "geen bestand om te controleren: ${2:-}"
    grep -qx 'Contact: mailto:info@notift.nl' "$2" || die "geen Contact: mailto:info@notift.nl"
    [ "$(grep -c '^Expires: ' "$2")" = 1 ] || die "niet precies één Expires"
    exp="$(sed -n 's/^Expires: //p' "$2")"
    printf '%s\n' "$exp" | grep -Eq "$ISO" || die "Expires is geen ISO 8601 in UTC: '$exp'"
    now="${3:-$(date -u +%s)}"
    over=$(( ( $(epoch "${exp%.000Z}") - now ) / 86400 ))
    [ "$over" -ge "$MIN_DAYS" ] || die "Expires $exp loopt nog $over dagen, minder dan $MIN_DAYS"
    printf 'ok   security.txt van Notift, Expires %s, nog %s dagen\n' "$exp" "$over"
    ;;
  *) die "gebruik: $0 expires [JJJJ-MM-DD] | render <sjabloon> <expires> | check <bestand> [nu-epoch]" ;;
esac
