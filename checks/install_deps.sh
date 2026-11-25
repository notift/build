#!/usr/bin/env bash
# Installs the dependencies of a project with a frozen lockfile. Job 1 of build-and-publish.yml.
#
# Input only through the environment, and only values check_output.py --github-output already checked.
# Mode and packages travel as two separate values, so a package name can never be read as a mode
# (audit finding 4):
#   MANAGER           npm | pnpm | yarn | bun
#   INSTALL_MODE      none | named | legacy-all
#   INSTALL_PACKAGES  space-separated package names; empty unless INSTALL_MODE is named
#
# none        no install script of any dependency runs.
# named       none run during install; afterwards the named packages, and only those, get their
#             lifecycle scripts through the manager's rebuild. Every name must also be on Notift's
#             list next to this script (install-scripts-allowed.txt), checked again here.
# legacy-all  the explicit compatibility for a static npm/pnpm/yarn site whose manifest predates the
#             field: every install script runs, exactly as before. Never for bun.
#
# The old single variable INSTALL_SCRIPTS is refused, so a workflow that was not updated fails loudly
# instead of guessing.
#
# NOTIFT_DRY_RUN=1 prints the commands instead of running them (build-layer-proof.sh uses that).
set -euo pipefail

run() {
  if [ "${NOTIFT_DRY_RUN:-}" = "1" ]; then printf '%s\n' "$*"; else "$@"; fi
}
fail() { echo "::error::$*"; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWED_FILE="$HERE/install-scripts-allowed.txt"

[ -z "${INSTALL_SCRIPTS+x}" ] || fail "INSTALL_SCRIPTS is vervangen door INSTALL_MODE en INSTALL_PACKAGES; werk de workflow bij"
: "${MANAGER:?MANAGER is required}"
: "${INSTALL_MODE:?INSTALL_MODE is required}"
INSTALL_PACKAGES="${INSTALL_PACKAGES-}"

PACKAGES=()
case "$INSTALL_MODE" in
  none|legacy-all)
    [ -z "$INSTALL_PACKAGES" ] || fail "INSTALL_PACKAGES hoort leeg te zijn bij INSTALL_MODE=$INSTALL_MODE"
    ;;
  named)
    read -r -a PACKAGES <<< "$INSTALL_PACKAGES"
    [ "${#PACKAGES[@]}" -ge 1 ] && [ "${#PACKAGES[@]}" -le 10 ] \
      || fail "INSTALL_MODE=named vraagt een tot tien pakketnamen"
    for P in "${PACKAGES[@]}"; do
      [[ "$P" =~ ^(@[a-z0-9][a-z0-9._-]{0,100}/)?[a-z0-9][a-z0-9._-]{0,100}$ ]] \
        || fail "INSTALL_PACKAGES bevat geen geldige pakketnaam: $P"
      case "$P" in none|named|legacy-all|all) fail "INSTALL_PACKAGES bevat een modusnaam: $P" ;; esac
      # Exact line match on Notift's list, comments and blanks ignored.
      sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOWED_FILE" 2>/dev/null | grep -qxF -- "$P" \
        || fail "$P staat niet op de lijst van Notift (install-scripts-allowed.txt)"
    done
    ;;
  *)
    fail "onbekende INSTALL_MODE" ;;
esac

case "$MANAGER" in
  npm)
    test -f package-lock.json || fail "npm ci vraagt package-lock.json"
    if [ "$INSTALL_MODE" = legacy-all ]; then run npm ci; else run npm ci --ignore-scripts; fi
    [ "$INSTALL_MODE" != named ] || run npm rebuild "${PACKAGES[@]}"
    ;;
  pnpm)
    run corepack enable
    if [ "$INSTALL_MODE" = legacy-all ]; then run pnpm install --frozen-lockfile
    else run pnpm install --frozen-lockfile --ignore-scripts; fi
    [ "$INSTALL_MODE" != named ] || run pnpm rebuild "${PACKAGES[@]}"
    ;;
  yarn)
    run corepack enable
    if [ "$INSTALL_MODE" = legacy-all ]; then run yarn install --immutable
    else run yarn install --immutable --mode=skip-build; fi
    [ "$INSTALL_MODE" != named ] || run yarn rebuild "${PACKAGES[@]}"
    ;;
  bun)
    # bun.lock is the text lockfile Lovable writes; bun.lockb the older binary one. Without either,
    # --frozen-lockfile would resolve fresh versions, so refuse instead.
    { test -f bun.lock || test -f bun.lockb; } || fail "bun install --frozen-lockfile vraagt bun.lock"
    [ "$INSTALL_MODE" = none ] || fail "bij bun kan de installatiemodus alleen none zijn"
    run bun install --frozen-lockfile --ignore-scripts
    ;;
  *)
    fail "onbekende pakketmanager" ;;
esac
