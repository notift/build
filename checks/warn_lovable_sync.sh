#!/usr/bin/env bash
# Warns, never fails, when the project repo has a lovable-sync branch. Job 1 of build-and-publish.yml.
#
# Lovable commits on every AI edit. When GitHub rejects its push, it parks the work on a branch whose
# name starts with lovable-sync (seen: lovable-sync and lovable-sync-<timestamp>). That work is then not
# on main and will not be built, and nobody sees it unless the build says so. This runs before any
# client code, so a build cannot hide it.
#
# Usage: warn_lovable_sync.sh <repo-dir>   (reads the remote 'origin' of that checkout)
# Writes a ::warning:: annotation and, when GITHUB_STEP_SUMMARY is set, a section in the job summary.
# A failed lookup is itself only a warning: this step must never stop a build.
set -uo pipefail

REPO_DIR="${1:?usage: warn_lovable_sync.sh <repo-dir>}"

if ! HEADS="$(git -C "$REPO_DIR" ls-remote --heads origin 2>/dev/null)"; then
  echo "::warning title=Lovable-sync::de takken van deze repo konden niet worden opgevraagd"
  exit 0
fi

# Every branch whose name starts with lovable-sync, as documented (lovable-sync*): Lovable's suffix is
# not a contract. Names are made safe for a table cell (Git allows | and backticks in a branch name).
FOUND="$(printf '%s\n' "$HEADS" | awk 'index($2, "refs/heads/lovable-sync") == 1 { sub(/^refs\/heads\//, "", $2); print $2, substr($1, 1, 12) }' \
  | LC_ALL=C tr -c 'A-Za-z0-9._/ \n-' '?')"
[ -n "$FOUND" ] || exit 0

COUNT="$(printf '%s\n' "$FOUND" | wc -l | tr -d ' ')"
echo "::warning title=Lovable-sync::$COUNT lovable-sync-tak(ken) in deze repo: werk van Lovable dat niet op main staat en niet gebouwd wordt"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Let op: werk van Lovable staat naast main"
    echo ""
    echo "Lovable kon niet naar main pushen en zette dit op een eigen tak. Deze build bevat het niet."
    echo ""
    echo "| Tak | Commit |"
    echo "|---|---|"
    printf '%s\n' "$FOUND" | while read -r NAAM SHA; do
      echo "| \`$NAAM\` | \`$SHA\` |"
    done
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
