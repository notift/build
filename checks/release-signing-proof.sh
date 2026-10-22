#!/usr/bin/env bash
# Proof that release.sh only publishes a signed notift/build commit (signed releases, choice L4 c), that the
# git setup from Leon's one-time steps signs only in a clone of notift/build, and that restore-release.sh puts an
# earlier publication back as a new signed commit with exactly its tree, which the check of platform-01 accepts
# (Codex audit 29, finding 3). Local: a bare repo plays GitHub,
# its own keys, its own global git config (GIT_CONFIG_GLOBAL). Nothing touches ~/.gitconfig or ~/.ssh.
#   bash infra/build/checks/release-signing-proof.sh <werkmap>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; INFRA="$(cd "$HERE/../.." && pwd)"
W="${1:?werkmap}"; mkdir -p "$W"; W="$(cd "$W" && pwd)"
[ ! -e "$W/hosting" ] || { printf 'werkmap %s is niet leeg; kies een nieuwe\n' "$W" >&2; exit 2; }
good=0; bad=0
ok() { printf '  ok   %s\n' "$1"; good=$((good+1)); }
no() { printf '  FOUT %s\n' "$1"; bad=$((bad+1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (verwacht '$2', kreeg '$3')"; fi; }

mkdir -p "$W/keys" "$W/github" "$W/hosting/infra/dashboard/lib"
for k in leon-a vreemd; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$W/keys/$k"; done
# A copy of the hosting repo with only what release.sh needs, and key a pinned.
cp -R "$INFRA/build" "$W/hosting/infra/build"
cp "$INFRA/dashboard/check-build-signers.sh" "$W/hosting/infra/dashboard/"
cp "$INFRA/dashboard/lib/build_signature.py" "$W/hosting/infra/dashboard/lib/"
printf 'leon@notift.nl namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$W/keys/leon-a.pub")" > "$W/hosting/infra/dashboard/build-signers"
export GIT_CONFIG_NOSYSTEM=1 HOME="$W" GIT_TERMINAL_PROMPT=0
printf '[user]\n\tname = Leon\n\temail = leon@notift.nl\n[init]\n\tdefaultBranch = main\n' > "$W/plain.gitconfig"
export GIT_CONFIG_GLOBAL="$W/plain.gitconfig"
git -C "$W/hosting" init -q && git -C "$W/hosting" add -A && git -C "$W/hosting" commit -q -m "chore: proof copy"
# "GitHub": notift/build with one old, unsigned commit on main and v1 on it (the state before signing). Like e4c45d0:
# files of its own, and no embed/ (that came with the forms script).
git init -q --bare "$W/github/build.git"
git init -q "$W/seed" && mkdir -p "$W/seed/base" "$W/seed/.github/workflows"
printf 'oude bouwlaag\n' > "$W/seed/README.md"; printf 'FROM scratch\n' > "$W/seed/base/Dockerfile"
printf 'name: oud\n' > "$W/seed/.github/workflows/build-and-publish.yml"
git -C "$W/seed" add -A && git -C "$W/seed" commit -q -m "chore: publish the build layer before signing"
git -C "$W/seed" tag -m old v1 && git -C "$W/seed" push -q "$W/github/build.git" main refs/tags/v1
remote() { git --git-dir="$W/github/build.git" rev-parse "$1" 2>/dev/null; }
OLD_MAIN="$(remote refs/heads/main)"; OLD_V1="$(remote 'refs/tags/v1^{commit}')"

# Leon's one-time setup, with the paths of this proof: sign only in a clone whose remote is notift/build.
signing() { # $1 = key name
  printf '[gpg]\n\tformat = ssh\n[user]\n\tsigningkey = %s\n[commit]\n\tgpgsign = true\n' "$W/keys/$1" > "$W/signing-$1.gitconfig"
  { cat "$W/plain.gitconfig"; printf '[includeIf "hasconfig:remote.*.url:%s"]\n\tpath = %s\n' "$W/github/build.git" "$W/signing-$1.gitconfig"; } > "$W/leon-$1.gitconfig"
}
signing leon-a; signing vreemd
release() { # $1 = global git config; sets RC and OUT
  set +e
  OUT="$(GIT_CONFIG_GLOBAL="$1" NOTIFT_BUILD_REMOTE="$W/github/build.git" NOTIFT_BUILD_WORK="$W/release" \
    bash "$W/hosting/infra/build/release.sh" --push v1 2>&1)"
  RC=$?
  set -e
}
verdict() { # the server's check on what v1 points to now
  local sha; sha="$(remote 'refs/tags/v1^{commit}')"
  git --git-dir="$W/github/build.git" cat-file commit "$sha" > "$W/raw"
  python3 -I "$INFRA/dashboard/lib/build_signature.py" --sha "$sha" --commit "$W/raw" --signers "$W/hosting/infra/dashboard/build-signers" || true
}

printf '\n== release.sh: alleen een ondertekende commit gaat naar notift/build ==\n\n'
release "$W/plain.gitconfig"
is "zonder ondertekenconfig: release.sh stopt" 1 "$RC"
is "zonder ondertekenconfig: main en v1 bij GitHub ongewijzigd" "$OLD_MAIN|$OLD_V1" "$(remote refs/heads/main)|$(remote 'refs/tags/v1^{commit}')"
printf '%s\n' "$OUT" | grep -q 'Ondertekenen mislukt' && ok "zonder ondertekenconfig: de melding wijst naar de README" || no "melding bij mislukt ondertekenen: $(printf '%s' "$OUT" | tail -2)"

release "$W/leon-vreemd.gitconfig"
is "getekend met een sleutel die niet in build-signers staat: release.sh stopt" 1 "$RC"
printf '%s\n' "$OUT" | grep -q 'niet goed ondertekend (fout unknown_key)' && ok "de melding noemt unknown_key" || no "melding verkeerde sleutel: $(printf '%s' "$OUT" | tail -2)"
is "verkeerde sleutel: main en v1 bij GitHub ongewijzigd" "$OLD_MAIN|$OLD_V1" "$(remote refs/heads/main)|$(remote 'refs/tags/v1^{commit}')"

cp "$W/hosting/infra/dashboard/build-signers" "$W/signers.keep"
printf '# leeg\n' > "$W/hosting/infra/dashboard/build-signers"
release "$W/leon-leon-a.gitconfig"
is "build-signers zonder sleutel: release.sh stopt voor hij commit" 1 "$RC"
is "build-signers zonder sleutel: GitHub ongewijzigd" "$OLD_MAIN|$OLD_V1" "$(remote refs/heads/main)|$(remote 'refs/tags/v1^{commit}')"
cp "$W/signers.keep" "$W/hosting/infra/dashboard/build-signers"

release "$W/leon-leon-a.gitconfig"
is "met Leons sleutel: gepusht" 0 "$RC"
new_v1="$(remote 'refs/tags/v1^{commit}')"
is "main en v1 wijzen naar dezelfde nieuwe commit" "$(remote refs/heads/main)" "$new_v1"
[ "$new_v1" != "$OLD_V1" ] && ok "v1 is verplaatst" || no "v1 niet verplaatst"
is "de controle van platform-01 op v1: ondertekend door leon@notift.nl" "ok leon@notift.nl $(ssh-keygen -l -E sha256 -f "$W/keys/leon-a.pub" | awk '{print $2}')" "$(verdict)"

release "$W/leon-leon-a.gitconfig"
is "nog een keer zonder wijziging: geen nieuwe commit, v1 blijft" "0|$new_v1" "$RC|$(remote 'refs/tags/v1^{commit}')"

# The includeIf only applies to a clone of notift/build: an unrelated repo with the same global config is not signed.
git init -q "$W/other" && GIT_CONFIG_GLOBAL="$W/leon-leon-a.gitconfig" git -C "$W/other" commit -q --allow-empty -m "unrelated"
is "een andere repo met dezelfde globale config: niet ondertekend" "" "$(GIT_CONFIG_GLOBAL="$W/leon-leon-a.gitconfig" git -C "$W/other" cat-file commit HEAD | grep '^gpgsig' || true)"
is "in de kloon van notift/build geldt gpg.format ssh" ssh "$(GIT_CONFIG_GLOBAL="$W/leon-leon-a.gitconfig" git -C "$W/release/repo" config gpg.format)"
is "in de andere repo geldt geen gpg.format" "" "$(GIT_CONFIG_GLOBAL="$W/leon-leon-a.gitconfig" git -C "$W/other" config gpg.format || true)"

printf '\n== restore-release.sh: de publicatie van voor de release terug, ondertekend ==\n\n'
restore() { # $1 = global git config, the rest are the arguments; sets RC and OUT
  local cfg="$1"; shift
  set +e
  OUT="$(GIT_CONFIG_GLOBAL="$cfg" NOTIFT_BUILD_REMOTE="$W/github/build.git" NOTIFT_BUILD_WORK="$W/restore" \
    bash "$W/hosting/infra/build/restore-release.sh" "$@" 2>&1)"
  RC=$?
  set -e
}
tree() { git --git-dir="$W/github/build.git" rev-parse "$1^{tree}"; }
NOW_MAIN="$(remote refs/heads/main)"; NOW_V1="$(remote 'refs/tags/v1^{commit}')"
unchanged() { is "$1: main en v1 bij GitHub ongewijzigd" "$NOW_MAIN|$NOW_V1" "$(remote refs/heads/main)|$(remote 'refs/tags/v1^{commit}')"; }
[ "$(tree "$NOW_MAIN")" != "$(tree "$OLD_MAIN")" ] && ok "na de release is de boom anders dan de oude (anders bewijst het terugzetten niets)" || no "de release veranderde de boom niet"

restore "$W/leon-leon-a.gitconfig" "$OLD_MAIN"
is "droog: exit 0" 0 "$RC"
unchanged "droog"
printf '%s\n' "$OUT" | grep -q "boom gelijk aan ${OLD_MAIN:0:12}" && ok "droog: de klaargezette boom is gemeten gelijk aan de oude" || no "droog: geen boommeting: $(printf '%s' "$OUT" | tail -3)"
printf '%s\n' "$OUT" | grep -q '^D  embed/forms.js$' && ok "droog: embed/forms.js gaat weg (bestond toen niet)" || no "droog: embed/forms.js gaat niet weg: $(printf '%s' "$OUT" | grep '^[MAD] ' | head -5)"

restore "$W/plain.gitconfig" "$OLD_MAIN" --push v1
is "zonder ondertekenconfig: stopt" 1 "$RC"
unchanged "zonder ondertekenconfig"
restore "$W/leon-vreemd.gitconfig" "$OLD_MAIN" --push v1
printf '%s\n' "$OUT" | grep -q 'unknown_key' && ok "verkeerde sleutel: de melding noemt unknown_key" || no "verkeerde sleutel: $(printf '%s' "$OUT" | tail -2)"
is "verkeerde sleutel: stopt" 1 "$RC"
unchanged "verkeerde sleutel"
restore "$W/leon-leon-a.gitconfig" "${OLD_MAIN:0:12}" --push v1
is "een verkorte hash: stopt" 1 "$RC"
restore "$W/leon-leon-a.gitconfig" "$(printf '%040d' 7)" --push v1
is "een hash die niet in notift/build staat: stopt" 1 "$RC"
git -C "$W/seed" checkout -q -b zij && git -C "$W/seed" commit -q --allow-empty -m "zijtak" && git -C "$W/seed" push -q "$W/github/build.git" zij
restore "$W/leon-leon-a.gitconfig" "$(git -C "$W/seed" rev-parse zij)" --push v1
is "een commit die niet op main staat: stopt" 1 "$RC"
unchanged "na de weigeringen"

restore "$W/leon-leon-a.gitconfig" "$OLD_MAIN" --push v1
is "met Leons sleutel: teruggezet" 0 "$RC"
back="$(remote 'refs/tags/v1^{commit}')"
is "v1 en main wijzen naar dezelfde nieuwe commit" "$(remote refs/heads/main)" "$back"
[ "$back" != "$OLD_V1" ] && [ "$back" != "$NOW_V1" ] && ok "v1 is een nieuwe commit, niet de oude onondertekende" || no "v1 wijst naar een bestaande commit"
is "de nieuwe commit heeft precies de boom van de oude publicatie" "$(tree "$OLD_MAIN")" "$(tree "$back")"
is "main is niet geforceerd: de ouder is de release van daarvoor" "$NOW_MAIN" "$(git --git-dir="$W/github/build.git" rev-parse "$back^")"
is "de controle van platform-01 op v1: ondertekend door leon@notift.nl" "ok leon@notift.nl $(ssh-keygen -l -E sha256 -f "$W/keys/leon-a.pub" | awk '{print $2}')" "$(verdict)"
set +e
ACC="$(env -i PATH=/usr/bin:/bin NOTIFT_BUILD_REPO_URL="$W/github/build.git" NOTIFT_BUILD_SIGNERS="$W/hosting/infra/dashboard/build-signers" \
  NOTIFT_BUILD_STATE_DIR="$W/approve-state" NOTIFT_LOGGER=true NOTIFT_BUILD_VERIFIER="$INFRA/dashboard/lib/build_signature.py" \
  bash "$INFRA/dashboard/approve-build.sh" --check 2>&1)"; RC=$?
set -e
is "approve-build.sh --check zoals cron (ophalen en controleren): geaccepteerd" "0|build_workflow $back ondertekend door leon@notift.nl $(ssh-keygen -l -E sha256 -f "$W/keys/leon-a.pub" | awk '{print $2}') (alleen gecontroleerd)" "$RC|$ACC"
restore "$W/leon-leon-a.gitconfig" "$OLD_MAIN" --push v1
is "nog een keer: geen nieuwe commit, v1 blijft" "0|$back|$back" "$RC|$(remote refs/heads/main)|$(remote 'refs/tags/v1^{commit}')"

printf '\n  %d goed, %d fout\n\n' "$good" "$bad"
[ "$bad" -eq 0 ]
