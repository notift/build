#!/usr/bin/env bash
# The proof of the install opt-in (audit finding 4): mode and packages travel as two fields, a package
# name can never become a mode, only Notift's own list can widen it, and old sites keep their behaviour
# explicitly (legacy-all).
#
# Runs check_output.py --github-output on manifests and install_deps.sh with NOTIFT_DRY_RUN=1 on a copy
# of the checks folder in a temp dir, so the allowlist can be filled for the test. Installs nothing,
# talks to nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(cd "$HERE/.." && pwd)"

if [ -t 1 ]; then C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'; else C_OK=""; C_ERR=""; C_OFF=""; fi
FAILED=0
pass() { printf '  %sok%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; FAILED=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/checks" "$WORK/repo"
cp "$HERE/check_output.py" "$HERE/redirects.py" "$HERE/install_deps.sh" "$WORK/checks/"
CHECK="$WORK/checks/check_output.py"
INSTALL="$WORK/checks/install_deps.sh"
: > "$WORK/repo/package-lock.json"
: > "$WORK/repo/bun.lock"

allow() { printf '# test list\n%s\n' "$@" > "$WORK/checks/install-scripts-allowed.txt"; }
no_list() { mv -f "$WORK/checks/install-scripts-allowed.txt" "$WORK/list.off" 2>/dev/null || true; }

# manifest <base> <out> [build-key=json-value | build-key=<weg>]...
manifest() {
  python3 -I - "$@" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for change in sys.argv[3:]:
    key, value = change.split("=", 1)
    if value == "<weg>":
        m["build"].pop(key, None)
    else:
        m["build"][key] = json.loads(value)
json.dump(m, open(sys.argv[2], "w"))
PY
}

out() { python3 -I "$CHECK" --github-output "$1" 2>"$WORK/err"; }

printf '\n== install opt-in: two fields, Notift list, explicit compatibility ==\n\n'

# 1. An existing static manifest without the field: explicit legacy-all, and the run says so.
manifest "$BUILD/notift.example.json" "$WORK/old.json"
U="$(out "$WORK/old.json")" || bad "an existing static manifest is refused"
if grep -qx 'install_mode=legacy-all' <<< "$U" && grep -qx 'install_packages=' <<< "$U" \
   && ! grep -q '^install_scripts=' <<< "$U" && grep -q 'legacy-all' "$WORK/err"; then
  pass "static manifest without the field: install_mode=legacy-all, empty packages, a visible warning"
else bad "static manifest without the field: $U"; fi

# 2. Lovable manifest: none.
U="$(out "$BUILD/notift.lovable.example.json")" || bad "the lovable example is refused"
grep -qx 'install_mode=none' <<< "$U" && grep -qx 'install_packages=' <<< "$U" \
  && pass "lovable manifest: install_mode=none" || bad "lovable manifest: $U"

# 3. Explicit none on a static site.
manifest "$BUILD/notift.example.json" "$WORK/none.json" 'install_scripts="none"'
U="$(out "$WORK/none.json")"
grep -qx 'install_mode=none' <<< "$U" && pass "static manifest with none: install_mode=none" || bad "none: $U"

# 4. A package named like a mode is refused in the manifest, and Notift's own list cannot name one.
allow esbuild
for name in all none legacy-all named; do
  manifest "$BUILD/notift.example.json" "$WORK/m.json" "install_scripts=[\"$name\"]"
  if out "$WORK/m.json" >/dev/null; then bad "a package named $name was accepted"
  elif grep -q "geen geldige pakketnaam: $name\$" "$WORK/err"; then pass "a package named $name is refused"
  else bad "a package named $name refused for another reason: $(head -1 "$WORK/err")"; fi
done
allow esbuild all
manifest "$BUILD/notift.example.json" "$WORK/m.json" 'install_scripts=["esbuild"]'
out "$WORK/m.json" >/dev/null && bad "a Notift list naming all was accepted" \
  || pass "a Notift list that names a mode is itself refused: $(head -1 "$WORK/err")"

# 5. A name that is not on Notift's list is refused; with an empty or missing list everything is.
no_list
manifest "$BUILD/notift.example.json" "$WORK/m.json" 'install_scripts=["esbuild"]'
out "$WORK/m.json" >/dev/null && bad "esbuild accepted without a Notift list" \
  || pass "esbuild without a Notift list is refused: $(head -1 "$WORK/err")"
allow sharp
out "$WORK/m.json" >/dev/null && bad "esbuild accepted while the list only names sharp" \
  || pass "esbuild not on the list (sharp only) is refused"

# 6. On the list: named, with the packages in their own field.
allow esbuild @swc/core
manifest "$BUILD/notift.example.json" "$WORK/m.json" 'install_scripts=["esbuild","@swc/core"]'
U="$(out "$WORK/m.json")"
grep -qx 'install_mode=named' <<< "$U" && grep -qx 'install_packages=esbuild @swc/core' <<< "$U" \
  && pass "named opt-in on the Notift list: install_mode=named, install_packages apart" || bad "named: $U"

# Installer: what it would run.
dry() { (cd "$WORK/repo" && env -u INSTALL_SCRIPTS "$@" NOTIFT_DRY_RUN=1 bash "$INSTALL" 2>&1); }
expect_cmd() {  # expect_cmd <description> <expected output> <env>...
  local d="$1" want="$2"; shift 2
  local got; got="$(dry "$@")"; local rc=$?
  if [ $rc -eq 0 ] && [ "$got" = "$want" ]; then pass "$d"; else bad "$d: rc=$rc, got: $got"; fi
}
expect_refuse() {  # expect_refuse <description> <env>...
  local d="$1"; shift
  local got; got="$(dry "$@")"; local rc=$?
  if [ $rc -ne 0 ]; then pass "$d: ${got##*::error::}"; else bad "$d was accepted: $got"; fi
}

expect_cmd "npm none: no scripts" "npm ci --ignore-scripts" MANAGER=npm INSTALL_MODE=none
expect_cmd "npm legacy-all: as before" "npm ci" MANAGER=npm INSTALL_MODE=legacy-all
expect_cmd "npm named: only the listed packages rebuilt" $'npm ci --ignore-scripts\nnpm rebuild esbuild @swc/core' \
  MANAGER=npm INSTALL_MODE=named "INSTALL_PACKAGES=esbuild @swc/core"
expect_cmd "bun none" "bun install --frozen-lockfile --ignore-scripts" MANAGER=bun INSTALL_MODE=none
expect_refuse "a package named all in INSTALL_PACKAGES" MANAGER=npm INSTALL_MODE=named INSTALL_PACKAGES=all
expect_refuse "a package not on the Notift list" MANAGER=npm INSTALL_MODE=named INSTALL_PACKAGES=sharp
expect_refuse "packages with mode none" MANAGER=npm INSTALL_MODE=none INSTALL_PACKAGES=esbuild
expect_refuse "packages with mode legacy-all" MANAGER=npm INSTALL_MODE=legacy-all INSTALL_PACKAGES=esbuild
expect_refuse "named without packages" MANAGER=npm INSTALL_MODE=named
expect_refuse "mode all (the old single value)" MANAGER=npm INSTALL_MODE=all
expect_refuse "legacy-all with bun" MANAGER=bun INSTALL_MODE=legacy-all
expect_refuse "no INSTALL_MODE" MANAGER=npm
# The old single variable is refused even when set to a harmless value, so a stale workflow fails loudly.
got="$(cd "$WORK/repo" && MANAGER=npm INSTALL_MODE=none INSTALL_SCRIPTS=none NOTIFT_DRY_RUN=1 bash "$INSTALL" 2>&1)" \
  && bad "the old INSTALL_SCRIPTS variable was accepted" || pass "the old INSTALL_SCRIPTS variable is refused"
got="$(cd "$WORK/repo" && MANAGER=npm INSTALL_MODE=none INSTALL_SCRIPTS= NOTIFT_DRY_RUN=1 bash "$INSTALL" 2>&1)" \
  && bad "an empty INSTALL_SCRIPTS was accepted" || pass "an empty INSTALL_SCRIPTS (stale workflow) is refused"

# The real list in the repo starts empty: no name passes it.
if grep -v '^[[:space:]]*#' "$HERE/install-scripts-allowed.txt" | grep -q '[^[:space:]]'; then
  bad "the Notift list in the repo is not empty"
else pass "the Notift list in the repo starts empty"; fi

printf '\n'
[ "$FAILED" -eq 0 ] || { printf '  %sSomething is wrong with the install opt-in.%s\n\n' "$C_ERR" "$C_OFF" >&2; exit 1; }
printf '  %sMode and packages stay apart, and only Notift widens the list.%s\n\n' "$C_OK" "$C_OFF"
