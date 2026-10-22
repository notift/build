#!/usr/bin/env bash
# For Leon, on the Mac, after the one-time setup of signed releases (choice L4 c). Pushes nothing, changes nothing
# in his config: it makes a throwaway repo with the remote of notift/build, signs one empty commit there with his
# setup, and runs the same check as platform-01 against infra/dashboard/build-signers. Ends with OK/FOUT per line.
#   ./infra/build/checks/signing-setup-check.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; INFRA="$(cd "$HERE/../.." && pwd)"
SIGNERS="${NOTIFT_BUILD_SIGNERS:-$INFRA/dashboard/build-signers}"
REMOTE="${NOTIFT_BUILD_REMOTE:-git@github.com:notift/build.git}"
results=(); fail=0
ok() { results+=("OK    $1"); }
no() { results+=("FOUT  $1"); fail=1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

version="$(git --version | awk '{print $3}')"
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 36 ]; }; then ok "git $version kent includeIf hasconfig"; else no "git $version is te oud voor includeIf hasconfig (2.36 of nieuwer)"; fi
if out="$(bash "$INFRA/dashboard/check-build-signers.sh" "$SIGNERS")"; then ok "build-signers: $(printf '%s' "$out" | tr '\n' ';')"; else no "build-signers: $(printf '%s' "$out" | tail -1)"; fi

git init -q "$work/build" && git -C "$work/build" remote add origin "$REMOTE"
git init -q "$work/other"
fmt="$(git -C "$work/build" config gpg.format || true)"
[ "$fmt" = ssh ] && ok "in een kloon van notift/build: gpg.format ssh" || no "in een kloon van notift/build: gpg.format is '$fmt', verwacht ssh"
[ "$(git -C "$work/build" config --type=bool commit.gpgsign || true)" = true ] && ok "in een kloon van notift/build: commit.gpgsign true" || no "commit.gpgsign staat niet aan voor notift/build"
[ -n "$(git -C "$work/build" config user.signingkey || true)" ] && ok "user.signingkey staat voor notift/build" || no "user.signingkey ontbreekt voor notift/build"
[ -z "$(git -C "$work/other" config gpg.format || true)" ] && ok "in een andere repo: geen gpg.format (alleen notift/build tekent)" || no "gpg.format staat ook buiten notift/build"

if git -C "$work/build" commit -q --allow-empty -m "chore: signing setup check" 2> "$work/err"; then
  sha="$(git -C "$work/build" rev-parse HEAD)"
  git -C "$work/build" cat-file commit "$sha" > "$work/raw"
  verdict="$(python3 -I "$INFRA/dashboard/lib/build_signature.py" --sha "$sha" --commit "$work/raw" --signers "$SIGNERS")"
  case "$verdict" in ok\ *) ok "proefcommit: $verdict" ;; *) no "proefcommit niet goed ondertekend: $verdict" ;; esac
else
  no "proefcommit faalde: $(tail -1 "$work/err")"
fi

printf '\n'; printf '%s\n' "${results[@]}"
[ "$fail" -eq 0 ] && printf '\nAlles OK: release.sh kan ondertekend publiceren.\n\n' || printf '\nNiet alles OK; niets veranderd.\n\n'
exit "$fail"
