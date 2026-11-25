#!/usr/bin/env bash
# The proof of check_lovable.py: a Lovable project that breaks a hosting rule is refused.
#
# Builds one green Lovable-shaped project (source plus static output) in a temp folder, then
# one copy per refusal with exactly one thing broken, and checks that the check refuses it
# with the right rule. Warnings are checked to warn and not block. Talks to nothing.
#
# Usage: ./check-lovable-proof.sh [<real-source> <real-output> [<expected-exit-code>]]
# With two arguments it also runs the check on a real build, prints what it finds, and fails
# unless the exit code is the expected one (default 0). Nothing is swallowed (audit finding 13).
#
# Portable between BSD and GNU: files are edited with python3, never in place with sed.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check_lovable.py"
command -v python3 >/dev/null || { echo "FAIL python3 is required" >&2; exit 1; }
[ -f "$CHECK" ] || { echo "FAIL $CHECK is missing" >&2; exit 1; }

if [ -t 1 ]; then C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else C_OK=""; C_ERR=""; C_BOLD=""; C_OFF=""; fi
FAILED=0
pass() { printf '  %sok%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; FAILED=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FORMS_TAG='<script src="/_notift/embed/forms.js" data-sitekey="0x4AAAAAAAtest" defer></script>'
NOTIFT_FORM='<form action="/_notift/forms/proefweek" method="post"><input name="naam"><button type="submit">Verstuur</button></form>'

page() {  # page <file> <title> [extra-body] [extra-head]
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<HTML
<!doctype html>
<html lang="nl">
<head>
<meta charset="utf-8">
<title>$2 - Sportschool Test</title>
<meta name="description" content="$2: kickboksen en conditietraining in De Bilt, met een gratis proefweek.">
<link rel="canonical" href="https://example.nl/">
<script type="module" src="/assets/index-a1b2c3.js"></script>
${4:-}
</head>
<body>
<main>
<h1>$2</h1>
<p>Wij trainen sinds 2010 in De Bilt. Kom langs voor een gratis proefweek, met kickboksen,
conditietraining en personal training voor elk niveau.</p>
${3:-}
</main>
</body>
</html>
HTML
}

green() {  # green <dir>: a Lovable-shaped project that follows every rule
  local s="$1/src" o="$1/out"
  mkdir -p "$s/src/routes/blog" "$s/src/lib" "$s/public" "$o/assets"
  cat > "$s/vite.config.ts" <<'TS'
// @lovable.dev/vite-tanstack-config already includes tanstackStart.
// An old line, commented out: prerender: { enabled: false }
import { defineConfig } from "@lovable.dev/vite-tanstack-config";

export default defineConfig({
  tanstackStart: {
    server: { entry: "server" },
    /* Render every static route to HTML at build time. */
    "prerender": { crawlLinks: false, enabled: true, },
  },
});
TS
  cat > "$s/src/start.ts" <<'TS'
import { createStart, createMiddleware } from "@tanstack/react-start";
// Enabling Lovable Cloud adds functionMiddleware: [attachSupabaseAuth]; see createServerFn docs.
// import { createClient } from "@supabase/supabase-js";
const errorMiddleware = createMiddleware().server(async ({ next }) => next());
export const startInstance = createStart(() => ({ requestMiddleware: [errorMiddleware] }));
TS
  printf 'export const re = /"|\\/\\//g; // a regex with a quote in it\n' > "$s/src/lib/utils.ts"
  printf 'import { Outlet } from "@tanstack/react-router";\n' > "$s/src/routes/__root.tsx"
  printf 'export const Route = createFileRoute("/")({ component: Home });\n' > "$s/src/routes/index.tsx"
  printf 'export const Route = createFileRoute("/over")({});\n' > "$s/src/routes/over.tsx"
  printf 'export const Route = createFileRoute("/_shell")({});\n' > "$s/src/routes/_shell.tsx"
  printf 'export const Route = createFileRoute("/blog/$slug")({});\n' > "$s/src/routes/blog/\$slug.tsx"
  printf '# Routes\nDo not use /__l5e/ or *.asset.json, see AGENTS.md\n' > "$s/src/routes/README.md"
  printf '{"pages": ["/blog/eerste-week"]}\n' > "$s/notift.routes.json"
  # A link inside the source folder is fine: never followed, its target is checked where it really is.
  ln -s lib "$s/src/lib-link"
  printf 'Media: no /__l5e/ URLs, no *.asset.json pointers.\n' > "$s/AGENTS.md"
  printf '{"name":"t","devDependencies":{"@lovable.dev/vite-tanstack-config":"2.27.2"}}\n' > "$s/package.json"

  # A correct Notift form: post, the Notift path, a submit button, and the forms script with a site key.
  page "$o/index.html" "Home" "$NOTIFT_FORM" "$FORMS_TAG"
  page "$o/over/index.html" "Over ons"
  page "$o/blog/eerste-week/index.html" "Eerste week"
  printf '<!doctype html><html lang="nl"><head><title>Niet gevonden</title><meta name="robots" content="noindex"></head><body><h1>Niet gevonden</h1></body></html>' > "$o/404.html"
  printf 'console.log("site");' > "$o/assets/index-a1b2c3.js"
  printf 'User-agent: Googlebot\nAllow: /\n\nUser-agent: GPTBot\nDisallow: /\n\nUser-agent: *\nDisallow: /404.html\n' > "$o/robots.txt"
}

subst() {  # subst <file> <old> <new>: literal replace, fails when <old> is not there
  python3 -I -c '
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
' "$@" || bad "subst: '$2' not found in $1"
}

RUN_ENV=()
run() {  # run <dir> [output-override]; sets RC and OUT. RUN_ENV holds extra VAR=value pairs.
  local out="${2:-$1/out}"
  RC=0
  OUT="$(env ${RUN_ENV[@]+"${RUN_ENV[@]}"} python3 -I "$CHECK" --source "$1/src" --output "$out" 2>&1)" || RC=$?
  if printf '%s\n' "$OUT" | grep -q '^Traceback'; then
    bad "the check crashed"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2; RC=99
  fi
}

refused() {  # refused <rule> <description> <dir> [output-override] [text-in-the-refusal]; ALSO=<rule> allows a second one
  run "$3" "${4:-}"
  if [ "$RC" -eq 0 ]; then
    bad "ALLOWED but must be refused: $2"
  elif [ "$RC" -ne 1 ]; then
    bad "exit $RC instead of 1 (refuse): $2"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
  elif [ -n "${5:-}" ] && ! printf '%s\n' "$OUT" | grep "^REFUSE lovable/$1: " | grep -qF -- "$5"; then
    bad "refused on $1, but without '$5': $2"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
  elif ! printf '%s\n' "$OUT" | grep -q "^REFUSE lovable/$1: "; then
    bad "refused, but not on rule $1: $2"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
  elif [ -z "${4:-}" ] && printf '%s\n' "$OUT" | grep '^REFUSE ' | grep -Evq "^REFUSE lovable/($1|${ALSO:-$1}): "; then
    # One thing broken, one rule refusing: a second rule would hide which one did the work.
    bad "refused on $1, but also on another rule: $2"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
  else
    pass "refused ($1): $2"
    printf '%s\n' "$OUT" | grep "^REFUSE lovable/$1: " | head -1 | sed 's/^/         /'
  fi
}

allowed() {  # allowed <description> <dir> [expected-warning-text]
  run "$2"
  if [ "$RC" -ne 0 ]; then
    bad "refused but must pass: $1"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
  elif [ -n "${3:-}" ] && ! printf '%s\n' "$OUT" | grep -q "^WARN .*$3"; then
    bad "passed, but without the warning '$3': $1"
  else
    pass "allowed: $1${3:+ (warns: $3)}"
  fi
}

case_dir() {  # case_dir <name>: a fresh copy of the green project
  cp -R "$WORK/green" "$WORK/$1"
  printf '%s' "$WORK/$1"
}

printf '\n%s== check_lovable.py: what passes, what is refused ==%s\n\n' "$C_BOLD" "$C_OFF"

green "$WORK/green"
run "$WORK/green"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q "check_lovable: ok, 0 warning(s), 3 required route(s) found"; then
  pass "green: a project that follows every rule passes without warnings"
else
  bad "green project not clean"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi

printf '\n  %s1. Prerender%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir pr-missing); python3 -I - "$d/src/vite.config.ts" <<'PY'
import sys, re; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r'\n\s*"prerender".*\n', "\n", s))
PY
refused prerender "prerender removed from tanstackStart" "$d"
d=$(case_dir pr-false); subst "$d/src/vite.config.ts" 'enabled: true' 'enabled: false'
refused prerender "prerender.enabled set to false" "$d"
d=$(case_dir pr-comment); python3 -I - "$d/src/vite.config.ts" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace('"prerender": { crawlLinks: false, enabled: true, },', '// prerender: { enabled: true },')
open(p, "w").write(s)
PY
refused prerender "prerender only in a comment" "$d"
d=$(case_dir pr-elsewhere); cat > "$d/src/vite.config.ts" <<'TS'
import { defineConfig } from "@lovable.dev/vite-tanstack-config";
const unused = { tanstackStart: { prerender: { enabled: true } } };
const s = "tanstackStart: { prerender: { enabled: true } }";
export default defineConfig({ tanstackStart: { server: { entry: "server" } } });
TS
refused prerender "prerender only in an unused object and a string" "$d"
d=$(case_dir pr-spread); subst "$d/src/vite.config.ts" '"prerender": {' '"prerender": { ...base, '
refused prerender "a spread inside prerender that could override enabled" "$d"
d=$(case_dir pr-two); cp "$d/src/vite.config.ts" "$d/src/vite.config.js"
refused prerender "two Vite configs, so the checked one may not be used" "$d"
d=$(case_dir pr-route); printf 'export const Route = createFileRoute("/contact")({});\n' > "$d/src/src/routes/contact.tsx"
refused prerender "a route without an index.html in the output" "$d"
d=$(case_dir pr-dynamic); rm -r "$d/out/blog"
refused prerender "a dynamic route with no prerendered page" "$d"
refused prerender "the output folder does not exist" "$WORK/green" "$WORK/does-not-exist"

printf '\n  %s1b. Required routes from an explicit list (finding 9)%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir rt-unlisted); printf '{"pages": []}\n' > "$d/src/notift.routes.json"
refused prerender "a dynamic route with no listed path, although other HTML sits under its prefix" "$d" "" "has no listed path"
d=$(case_dir rt-prefix); mv "$d/out/blog/eerste-week" "$d/out/blog/iets-anders"
refused prerender "a listed path without HTML, while other HTML under /blog would have fooled the old check" "$d" "" "/blog/eerste-week"
d=$(case_dir rt-vitepages); printf '{"pages": []}\n' > "$d/src/notift.routes.json"
subst "$d/src/vite.config.ts" '"prerender": {' 'pages: [{ path: "/blog/eerste-week", prerender: { enabled: true } }],
    "prerender": {'
allowed "a dynamic route listed in tanstackStart.pages instead of notift.routes.json" "$d"
d=$(case_dir rt-gen); printf "export interface FileRoutesByFullPath {\n  '/': typeof IndexRoute\n  '/contact': typeof ContactRoute\n}\n" > "$d/src/src/routeTree.gen.ts"
refused prerender "a route in routeTree.gen.ts that has no HTML" "$d" "" "/contact"
d=$(case_dir rt-gen-ok); printf "export interface FileRoutesByFullPath {\n  '/': typeof IndexRoute\n  '/over': typeof OverRoute\n  '/blog/\$slug': typeof BlogRoute\n}\n" > "$d/src/src/routeTree.gen.ts"
allowed "routeTree.gen.ts that agrees with the output" "$d"
d=$(case_dir rt-splat); printf 'export const Route = 1;\n' > "$d/src/src/routes/\$.tsx"
allowed "a catch-all route without listed paths" "$d" "catch-all route under /"
d=$(case_dir rt-splat-listed); mkdir -p "$d/src/src/routes/docs"; printf 'export const Route = 1;\n' > "$d/src/src/routes/docs/\$.tsx"
printf '{"pages": ["/blog/eerste-week", "/docs/a/b"]}\n' > "$d/src/notift.routes.json"
refused prerender "a listed catch-all path without HTML" "$d" "" "/docs/a/b"
d=$(case_dir rt-bad); printf '{"pages": ["/blog/../../etc"]}\n' > "$d/src/notift.routes.json"
refused prerender "a listed path with .." "$d" "" "not a plain site path"
d=$(case_dir rt-json); printf '{"pages": ' > "$d/src/notift.routes.json"
refused prerender "notift.routes.json that is not JSON" "$d" "" "not readable JSON"

printf '\n  %s1c. Links out of the folder (finding 9)%s\n' "$C_BOLD" "$C_OFF"
mkdir -p "$WORK/outside"; printf 'export const secret = "runner";\n' > "$WORK/outside/x.ts"
d=$(case_dir ln-src); ln -s "$WORK/outside" "$d/src/src/lib/ext"
refused symlink "a source folder link to outside the repo" "$d" "" "outside the source folder"
d=$(case_dir ln-srcfile); ln -s "$WORK/outside/x.ts" "$d/src/src/lib/x.ts"
refused symlink "a source file link to outside the repo" "$d"
d=$(case_dir ln-out); ln -s "$WORK/outside/x.ts" "$d/out/assets/x.js"
refused symlink "an output link to outside the output folder" "$d" "" "outside the output folder"
d=$(case_dir ln-loop); ln -s .. "$d/src/src/lib/up"
allowed "a link inside the repo that loops back is not followed and not refused" "$d"

printf '\n  %s1d. Nothing outside the folder is ever opened (audit 2, finding N1)%s\n' "$C_BOLD" "$C_OFF"
# A driver with an audit hook, modelled on the audit's begrenzing-proef.py. It runs the real check and
# records every open: an absolute or multi-component path that resolves into the outside folder, or a
# single component opened without O_NOFOLLOW (which could follow a link), is reported as OUTSIDE-OPEN.
cat > "$WORK/audit_driver.py" <<'PY'
import os, runpy, sys
script, outside = sys.argv[1], os.path.realpath(sys.argv[2])
bad = []
def leaves(p):
    r = os.path.realpath(p)
    return r == outside or r.startswith(outside + os.sep)
def audit(event, args):
    if event == "open":
        path, flags = args[0], args[2]
        if path is None or isinstance(path, int):
            return
        path = os.fsdecode(path)
        if os.path.isabs(path) or "/" in path:
            if leaves(path):
                bad.append(f"{path}")
        elif not (isinstance(flags, int) and flags & os.O_NOFOLLOW):
            bad.append(f"{path} (without O_NOFOLLOW)")
    elif event in ("os.scandir", "os.listdir") and isinstance(args[0], (str, bytes)) and leaves(os.fsdecode(args[0])):
        bad.append(f"{os.fsdecode(args[0])} (listed)")
sys.addaudithook(audit)
sys.argv[:] = [script] + sys.argv[3:]
try:
    runpy.run_path(script, run_name="__main__")
    rc = 0
except SystemExit as e:
    rc = e.code if isinstance(e.code, int) else 1
for b in bad:
    print("OUTSIDE-OPEN", b, file=sys.stderr)
sys.exit(rc)
PY
OUTSIDE="$WORK/outside-n1"
mkdir -p "$OUTSIDE/supabase" "$OUTSIDE/routes" "$OUTSIDE/srcdir/routes" "$OUTSIDE/blog"
cp "$WORK/green/src/vite.config.ts" "$OUTSIDE/vite.config.ts"
printf '{"name":"t","dependencies":{"@supabase/supabase-js":"2"}}\n' > "$OUTSIDE/package.json"
printf "export interface FileRoutesByFullPath {\n  '/': typeof IndexRoute\n}\n" > "$OUTSIDE/routeTree.gen.ts"
printf '{"pages": ["/blog/eerste-week"]}\n' > "$OUTSIDE/notift.routes.json"
printf 'Deno.serve(() => new Response("x"));\n' > "$OUTSIDE/supabase/index.ts"
printf 'export const Route = 1;\n' > "$OUTSIDE/routes/index.tsx"
printf 'export const Route = 1;\n' > "$OUTSIDE/srcdir/routes/index.tsx"
printf 'User-agent: *\nAllow: /\n' > "$OUTSIDE/robots.txt"
printf '/*\n  X-Frame-Options: DENY\n' > "$OUTSIDE/_headers"
cp "$WORK/green/out/over/index.html" "$OUTSIDE/index.html"
cp -R "$WORK/green/out/blog/." "$OUTSIDE/blog/"

# Detector self-test: the same hook must see a plain open through a link, or a green result means nothing.
printf 'import sys; open(sys.argv[1]).read()\n' > "$WORK/naive_open.py"
ln -s "$OUTSIDE/vite.config.ts" "$WORK/naive-link.ts"
if python3 -I "$WORK/audit_driver.py" "$WORK/naive_open.py" "$OUTSIDE" "$WORK/naive-link.ts" 2>&1 | grep -q '^OUTSIDE-OPEN'; then
  pass "detector self-test: a plain open through a link to the outside folder is seen"
else
  bad "detector self-test: the audit hook missed an open through a link; the N1 cases below prove nothing"
fi

never_opened() {  # never_opened <description> <dir> <text-in-a-refusal> [--output-only]
  local d="$2" rc=0 out
  if [ "${4:-}" = "--output-only" ]; then
    out="$(python3 -I "$WORK/audit_driver.py" "$CHECK" "$OUTSIDE" --output-only --output "$d/out" 2>&1)" || rc=$?
  else
    out="$(python3 -I "$WORK/audit_driver.py" "$CHECK" "$OUTSIDE" --source "$d/src" --output "$d/out" 2>&1)" || rc=$?
  fi
  if printf '%s\n' "$out" | grep -q '^Traceback'; then
    bad "the check crashed: $1"; printf '%s\n' "$out" | sed 's/^/      /' >&2
  elif printf '%s\n' "$out" | grep -q '^OUTSIDE-OPEN'; then
    bad "opened outside the folder: $1"; printf '%s\n' "$out" | grep '^OUTSIDE-OPEN' | sed 's/^/      /' >&2
  elif [ "$rc" -ne 1 ]; then
    bad "exit $rc instead of 1: $1"; printf '%s\n' "$out" | sed 's/^/      /' >&2
  elif ! printf '%s\n' "$out" | grep '^REFUSE ' | grep -qF -- "$3"; then
    bad "refused, but not on '$3': $1"; printf '%s\n' "$out" | sed 's/^/      /' >&2
  else
    pass "refused, nothing outside opened: $1"
  fi
}
d=$(case_dir n1-vite); rm "$d/src/vite.config.ts"; ln -s "$OUTSIDE/vite.config.ts" "$d/src/vite.config.ts"
never_opened "vite.config.ts as a link to outside" "$d" "vite.config.ts"
d=$(case_dir n1-vite-in); mkdir -p "$d/src/config"; mv "$d/src/vite.config.ts" "$d/src/config/vite.ts"; ln -s config/vite.ts "$d/src/vite.config.ts"
refused prerender "vite.config.ts as a link inside the repo: only a plain file is read" "$d" "" "is a link"
d=$(case_dir n1-pkg); rm "$d/src/package.json"; ln -s "$OUTSIDE/package.json" "$d/src/package.json"
never_opened "package.json as a link to outside" "$d" "package.json"
d=$(case_dir n1-gen); ln -s "$OUTSIDE/routeTree.gen.ts" "$d/src/src/routeTree.gen.ts"
never_opened "src/routeTree.gen.ts as a link to outside" "$d" "src/routeTree.gen.ts"
d=$(case_dir n1-routesjson); rm "$d/src/notift.routes.json"; ln -s "$OUTSIDE/notift.routes.json" "$d/src/notift.routes.json"
never_opened "notift.routes.json as a link to outside" "$d" "notift.routes.json"
d=$(case_dir n1-supabase); ln -s "$OUTSIDE/supabase" "$d/src/supabase"
never_opened "supabase/ as a link to an outside folder" "$d" "supabase/"
d=$(case_dir n1-drizzle); ln -s "$OUTSIDE/supabase" "$d/src/drizzle"
never_opened "drizzle/ as a link to an outside folder" "$d" "drizzle/"
d=$(case_dir n1-routes); rm -r "$d/src/src/routes"; ln -s "$OUTSIDE/routes" "$d/src/src/routes"
never_opened "src/routes as a link to an outside folder" "$d" "src/routes"
d=$(case_dir n1-src); rm -r "$d/src/src"; ln -s "$OUTSIDE/srcdir" "$d/src/src"
never_opened "src/ itself as a link (a component on the way to src/routes)" "$d" "src"
d=$(case_dir n1-robots); rm "$d/out/robots.txt"; ln -s "$OUTSIDE/robots.txt" "$d/out/robots.txt"
never_opened "robots.txt in the output as a link to outside" "$d" "robots.txt"
never_opened "the same, output only (job 2)" "$d" "robots.txt" --output-only
d=$(case_dir n1-headers); ln -s "$OUTSIDE/_headers" "$d/out/_headers"
never_opened "_headers in the output as a link to outside, output only" "$d" "_headers" --output-only
d=$(case_dir n1-page); rm "$d/out/over/index.html"; ln -s "$OUTSIDE/index.html" "$d/out/over/index.html"
never_opened "a required page as a link to outside" "$d" "over/index.html"
d=$(case_dir n1-blog); rm -r "$d/out/blog"; ln -s "$OUTSIDE/blog" "$d/out/blog"
never_opened "an output folder as a link to outside, output only" "$d" "blog" --output-only
d=$(case_dir n1-inlink); ln -s index.html "$d/out/kopie.html"
refused symlink "a link inside the output (the transfer carries none)" "$d" "" "a link inside the output"

printf '\n  %s1e. Two modes: job 1 source and output, job 2 output only (N1)%s\n' "$C_BOLD" "$C_OFF"
RC=0; OUT="$(python3 -I "$CHECK" --output-only --output "$WORK/green/out" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q "check_lovable: ok, output only, 0 warning(s)$" \
  && pass "output only: the green output passes, no source given or read" || { bad "output only on the green output: exit $RC"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2; }
RC=0; python3 -I "$CHECK" --output "$WORK/green/out" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ] && pass "neither --source nor --output-only is a usage error (exit 2)" || bad "no mode gave exit $RC"
RC=0; python3 -I "$CHECK" --output-only --source "$WORK/green/src" --output "$WORK/green/out" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ] && pass "--source with --output-only is a usage error (exit 2)" || bad "both modes gave exit $RC"
d=$(case_dir oo-storage); printf 'v.src="/__l5e/assets-v1/abc/home.mov";' >> "$d/out/assets/index-a1b2c3.js"
RC=0; OUT="$(python3 -I "$CHECK" --output-only --output "$d/out" 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^REFUSE lovable/lovable-storage: ' \
  && pass "output only still refuses what the output shows (Lovable storage)" || bad "output only let Lovable storage through (exit $RC)"

printf '\n  %s1f. Every route source normalized the same, HTML only as a plain .html file (N3)%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir n3-vite); printf '{"pages": []}\n' > "$d/src/notift.routes.json"
subst "$d/src/vite.config.ts" '"prerender": {' 'pages: [{ path: "/blog/../../etc" }, { path: "/blog/eerste-week" }],
    "prerender": {'
refused prerender "a Vite pages path with .." "$d" "" "not a plain site path"
d=$(case_dir n3-gen); printf "export interface FileRoutesByFullPath {\n  '/': typeof IndexRoute\n  '/%%2e%%2e/x': typeof X\n}\n" > "$d/src/src/routeTree.gen.ts"
refused prerender "a routeTree.gen.ts path that decodes to .." "$d" "" "not a plain site path"
d=$(case_dir n3-enc); printf '{"pages": ["/blog/eerste-week", "/a%%2Fb"]}\n' > "$d/src/notift.routes.json"
refused prerender "a listed path with an encoded slash inside a segment" "$d" "" "not a plain site path"
d=$(case_dir n3-ctl); printf '{"pages": ["/blog/eerste-week", "/a%%0Ab"]}\n' > "$d/src/notift.routes.json"
refused prerender "a listed path with an encoded line break" "$d" "" "not a plain site path"
d=$(case_dir n3-utf8); printf '{"pages": ["/blog/eerste-week", "/caf%%C3%%A9"]}\n' > "$d/src/notift.routes.json"
page "$d/out/café/index.html" "Café"
allowed "a percent-encoded listed path whose decoded folder has the HTML (as nginx decodes it)" "$d"
# Audit 3, N3: a path is decoded once, as nginx does. /100%2520sport asks for "100%20sport", never for the
# existing "100 sport.html" that a second decoding would select.
d=$(case_dir n3-twice); printf '{"pages": ["/blog/eerste-week", "/100%%2520sport"]}\n' > "$d/src/notift.routes.json"
page "$d/out/100 sport.html" "Honderd procent sport"
refused prerender "an encoded percent sign that a second decoding would point at another existing page" "$d" "" "/100%20sport"
d=$(case_dir n3-twice-vite); printf '{"pages": []}\n' > "$d/src/notift.routes.json"
subst "$d/src/vite.config.ts" '"prerender": {' 'pages: [{ path: "/blog/eerste-week" }, { path: "/100%2520sport" }],
    "prerender": {'
page "$d/out/100 sport.html" "Honderd procent sport"
refused prerender "the same through Vite pages" "$d" "" "/100%20sport"
d=$(case_dir n3-noext); printf 'export const Route = createFileRoute("/contact")({});\n' > "$d/src/src/routes/contact.tsx"
printf 'not a page' > "$d/out/contact"
refused prerender "a route served from a file without .html (nginx tries \$uri first)" "$d" "" "not an .html page"
d=$(case_dir n3-dotted); printf '{"pages": ["/blog/eerste-week", "/feed.xml"]}\n' > "$d/src/notift.routes.json"; printf '<rss/>' > "$d/out/feed.xml"
refused prerender "a dotted listed route served from a file that is not HTML" "$d" "" "not an .html page"
d=$(case_dir n3-dir); rm "$d/out/over/index.html"; mkdir -p "$d/out/over/index.html"
refused prerender "an index.html that is a folder" "$d" "" "/over"

printf '\n  %s1g. Client text stays one inert log line (audit 2, finding N7)%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir n7-inject)
printf '{"url":"x"}' > "$d/out/assets/pointer
::error title=Injected::from a file name.asset.json"
subst "$d/out/over/index.html" 'lang="nl"' 'lang="en
::warning title=Injected::from an attribute"'
subst "$d/out/over/index.html" '</head>' '<script src="https://cdn.example.com/a.js
::error file=x::from a script src %0A::notice::y"></script></head>'
RC=0; OUT="$(GITHUB_ACTIONS=true python3 -I "$CHECK" --source "$d/src" --output "$d/out" 2>&1)" || RC=$?
STRAY="$(printf '%s\n' "$OUT" | grep -Ev '^(WARN lovable/|REFUSE lovable/|check_lovable: |::error title=Lovable check::)' || true)"
if [ "$RC" -ne 1 ]; then
  bad "the injection case gave exit $RC instead of 1"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
elif [ -n "$STRAY" ]; then
  bad "a client value started its own log line:"; printf '%s\n' "$STRAY" | sed 's/^/      /' >&2
elif [ "$(printf '%s\n' "$OUT" | grep -cF 'Injected:\x3afrom')" -ne 3 ] \
    || [ "$(printf '%s\n' "$OUT" | grep -cF 'pointer\x0a:\x3aerror title=Injected')" -ne 2 ]; then
  bad "the multi-line values were not shown as escaped data"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
else
  pass "a multi-line file name, attribute and script src with '::' stay data on one line (stderr and annotation)"
fi
RC=0; OUT="$(GITHUB_ACTIONS=true python3 -I "$CHECK" --output-only --output "$d/out" 2>&1)" || RC=$?
STRAY="$(printf '%s\n' "$OUT" | grep -Ev '^(WARN lovable/|REFUSE lovable/|check_lovable: |::error title=Lovable check::)' || true)"
[ "$RC" -eq 1 ] && [ -z "$STRAY" ] && pass "the same in output-only mode (job 2)" || bad "output-only injection case: exit $RC, stray: $STRAY"
# Audit 3, N7: both command syntaxes in the middle of a line, in a file name and an HTML attribute. The runner's
# legacy parser finds '##[' anywhere in a line: neither '##[' nor a second '::' may survive anywhere.
d=$(case_dir n7-mid)
printf '{"url":"x"}' > "$d/out/assets/mid::warning::naam ##[error]naam.asset.json"
subst "$d/out/over/index.html" 'lang="nl"' 'lang="x::warning::attr ##[error]attr"'
for modus in source output-only; do
  RC=0
  if [ "$modus" = source ]; then OUT="$(GITHUB_ACTIONS=true python3 -I "$CHECK" --source "$d/src" --output "$d/out" 2>&1)" || RC=$?
  else OUT="$(GITHUB_ACTIONS=true python3 -I "$CHECK" --output-only --output "$d/out" 2>&1)" || RC=$?; fi
  REST="$(printf '%s\n' "$OUT" | sed 's/^::error title=Lovable check:://')"
  if [ "$RC" -eq 1 ] && ! printf '%s\n' "$OUT" | grep -qF '##[' && ! printf '%s\n' "$REST" | grep -qF '::' \
      && printf '%s\n' "$OUT" | grep -qF 'mid:\x3awarning:\x3anaam #\x23[error]naam.asset.json' \
      && printf '%s\n' "$OUT" | grep -qF 'x:\x3awarning:\x3aattr #\x23[error]attr'; then
    pass "$modus: '::warning::' and '##[error]' mid-line in a file name and an attribute are shown inert"
  else
    bad "$modus: a mid-line command syntax survived (exit $RC)"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
  fi
done
d=$(case_dir n7-long); page "$d/out/over/index.html" "Over ons" "" "<script src=\"https://cdn.example.com/$(printf 'a%.0s' $(seq 2000)).js\"></script>"
run "$d"
LONGEST="$(printf '%s\n' "$OUT" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
[ "$RC" -eq 1 ] && [ "$LONGEST" -le 400 ] && pass "a 2000-character value is cut to one line of at most 400 characters" || bad "longest line $LONGEST characters (exit $RC)"

printf '\n  %s2. Lovable storage%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir st-asset); printf '{"url":"x"}' > "$d/src/src/hero.asset.json"
refused lovable-storage "an *.asset.json pointer in the source" "$d"
d=$(case_dir st-l5e-out); printf 'v.src="/__l5e/assets-v1/abc/home.mov";' >> "$d/out/assets/index-a1b2c3.js"
refused lovable-storage "a /__l5e/ URL in the output" "$d"
d=$(case_dir st-l5e-src); printf 'export const v = "/__l5e/assets-v1/abc/home.mov";\n' > "$d/src/src/lib/video.ts"
refused lovable-storage "a /__l5e/ URL in the source" "$d"
d=$(case_dir st-host); printf 'export const img = "https://id-preview--abc.lovable.app/x.png";\n' > "$d/src/src/lib/img.ts"
refused lovable-storage "a lovable.app host in the source" "$d"

printf '\n  %s3. Nothing server-side%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir sv-fn); printf 'import { createServerFn } from "@tanstack/react-start";\nexport const f = createServerFn().handler(() => 1);\n' > "$d/src/src/lib/fn.ts"
refused server-side "a server function (createServerFn), labelled as a source heuristic" "$d" "" "[source heuristic]"
d=$(case_dir sv-handlers); printf 'export const Route = createFileRoute("/over")({\n  server: {\n    handlers: { GET: () => new Response("x") },\n  },\n});\n' > "$d/src/src/routes/over.tsx"
refused server-side "a server route with server.handlers" "$d"
d=$(case_dir sv-api); mkdir -p "$d/src/src/routes/api"; printf 'export const Route = 1;\n' > "$d/src/src/routes/api/send.ts"
refused server-side "a file under src/routes/api" "$d"
d=$(case_dir sv-supabase); printf 'import { createClient } from "@supabase/supabase-js";\n' > "$d/src/src/lib/db.ts"
refused server-side "a Supabase import" "$d"
d=$(case_dir sv-cloud); printf 'import { supabase } from "@/integrations/supabase/client";\n' > "$d/src/src/lib/db.ts"
refused server-side "a Lovable Cloud client import" "$d"
d=$(case_dir sv-gateway); printf 'const k = process.env.LOVABLE_API_KEY;\nfetch("https://ai.gateway.lovable.dev/v1/chat/completions");\n' > "$d/src/src/lib/ai.ts"
refused server-side "the Lovable AI gateway" "$d"
d=$(case_dir sv-edge); mkdir -p "$d/src/supabase/functions/send"; printf 'Deno.serve(() => new Response("x"));\n' > "$d/src/supabase/functions/send/index.ts"
refused server-side "a supabase/functions edge function" "$d"
d=$(case_dir sv-bundle); mkdir -p "$d/dotoutput/server/_ssr"; mv "$d/out" "$d/dotoutput/public"
printf 'export default {};' > "$d/dotoutput/server/index.mjs"; printf '{}' > "$d/dotoutput/nitro.json"
refused server-side "a server bundle in the output (.output instead of .output/public)" "$d" "$d/dotoutput"
d=$(case_dir sv-supahost); printf 'fetch("https://abcdefgh.supabase.co/rest/v1/x");' >> "$d/out/assets/index-a1b2c3.js"
refused server-side "a Supabase host in the output" "$d"

printf '\n  %s4. Media%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir md-big); mkdir -p "$d/out/media"; python3 -I -c "import sys; open(sys.argv[1],'wb').write(b'x' * (11 * 1024 * 1024))" "$d/out/media/hero.mp4"
refused media "a file of 11 MB in the output" "$d"
d=$(case_dir md-mov); mkdir -p "$d/out/media"; printf 'mov' > "$d/out/media/team.mov"
allowed "a small .mov file" "$d" "lovable/media: media/team.mov"

printf '\n  %s5. Forms%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir fm-third); page "$d/out/over/index.html" "Over ons" '<form action="https://formspree.io/f/abc" method="post"><button type="submit">x</button></form>'
refused forms "a form to a third-party form service" "$d"
d=$(case_dir fm-name); page "$d/out/over/index.html" "Over ons" '<form action="/_notift/forms/Contact_Form" method="post"><button type="submit">x</button></form>'
refused forms "a form name with capitals and an underscore" "$d"
d=$(case_dir fm-long); page "$d/out/over/index.html" "Over ons" "<form action=\"/_notift/forms/$(printf 'a%.0s' $(seq 41))\" method=\"post\"></form>"
refused forms "a form name of 41 characters" "$d"
d=$(case_dir fm-honeypot); page "$d/out/over/index.html" "Over ons" '<form action="/_notift/forms/contact" method="post"><input name="website"><button type="submit">x</button></form>'
refused forms "a field named website" "$d"
d=$(case_dir fm-otherhost); page "$d/out/over/index.html" "Over ons" '<form action="https://evil.example/_notift/forms/contact" method="post"></form>'
refused forms "a Notift form path on another host" "$d"
d=$(case_dir fm-static); page "$d/out/over/index.html" "Over ons" '<form action="/contact" method="post"></form>'
refused forms "a POST to a static page" "$d"
d=$(case_dir fm-formaction); page "$d/out/over/index.html" "Over ons" '<form action="/_notift/forms/contact" method="post"><button formaction="https://formspree.io/f/abc">x</button></form>'
refused forms "a button formaction that overrides the form" "$d"
d=$(case_dir fm-noaction); page "$d/out/over/index.html" "Over ons" '<form><input name="q"></form>'
allowed "a GET form without action (a search box)" "$d" "lovable/forms: over/index.html: a form without an action"
d=$(case_dir fm-search); page "$d/out/over/index.html" "Over ons" '<form action="/zoeken" method="get"><input name="q"></form>'
allowed "a same-site GET search form" "$d" "a GET form to /zoeken"
d=$(case_dir fm-get); page "$d/out/over/index.html" "Over ons" '<form action="/_notift/forms/contact"><button type="submit">x</button></form>' "$FORMS_TAG"
refused forms "a Notift form without method post" "$d" "" 'must be method="post"'
d=$(case_dir fm-formmethod); page "$d/out/over/index.html" "Over ons" '<form action="/_notift/forms/contact" method="post"><button type="submit" formmethod="get">x</button></form>' "$FORMS_TAG"
refused forms "a submit button that switches a Notift form to GET" "$d" "" 'must be method="post"'
d=$(case_dir fm-noscript); page "$d/out/over/index.html" "Over ons" "$NOTIFT_FORM"
refused forms "a Notift form without the hosting forms script" "$d" "" "without <script"
d=$(case_dir fm-nokey); page "$d/out/over/index.html" "Over ons" "$NOTIFT_FORM" '<script src="/_notift/embed/forms.js" defer></script>'
refused forms "the forms script without data-sitekey" "$d" "" "data-sitekey"
d=$(case_dir fm-oldscript); page "$d/out/over/index.html" "Over ons" "$NOTIFT_FORM" '<script src="https://app.notift.nl/embed/forms.js" data-sitekey="0x4AAAAAAAtest"></script>'
ALSO=third-party refused forms "the old forms script from the dashboard instead of the own domain (also third-party)" "$d" "" "without <script"
d=$(case_dir fm-postnoaction); page "$d/out/over/index.html" "Over ons" '<form method="post"><input name="naam"><button type="submit">x</button></form>' "$FORMS_TAG"
refused forms "a form that posts without an action" "$d" "" "posts without an action"
d=$(case_dir fm-relative); page "$d/out/over/index.html" "Over ons" '<form action="_notift/forms/contact" method="post"><button type="submit">x</button></form>' "$FORMS_TAG"
refused forms "a relative Notift path that resolves under /over/" "$d" "" "resolves to /over/_notift/forms/contact"
d=$(case_dir fm-nosubmit); page "$d/out/over/index.html" "Over ons" '<form action="/_notift/forms/contact" method="post"><input name="naam"><button>x</button></form>' "$FORMS_TAG"
refused forms "a Notift form without a type=submit control" "$d" "" 'type="submit"'

printf '\n  %s6. Per page (warnings)%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir pg-lang); subst "$d/out/over/index.html" 'lang="nl"' 'lang="en-US"'
allowed "lang en-US" "$d" 'expected lang="nl"'
d=$(case_dir pg-h1); subst "$d/out/over/index.html" '<h1>Over ons</h1>' '<h1>Over ons</h1><h1>Nog een</h1>'
allowed "two h1 elements" "$d" "2 <h1> elements"
d=$(case_dir pg-title); subst "$d/out/over/index.html" '<title>Over ons' '<title>Home'
allowed "two pages with the same title" "$d" "same title"
d=$(case_dir pg-canon); subst "$d/out/over/index.html" '<link rel="canonical" href="https://example.nl/">' ''
allowed "no canonical link" "$d" "no canonical link"

printf '\n  %s7. No noindex%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir ni-meta); subst "$d/out/over/index.html" '<meta charset="utf-8">' '<meta charset="utf-8"><meta name="robots" content="noindex, nofollow">'
refused noindex "a page with meta robots noindex" "$d"
d=$(case_dir ni-robots); printf 'User-agent: *\nDisallow: /\n' > "$d/out/robots.txt"
refused noindex "robots.txt that blocks every crawler" "$d"
d=$(case_dir ni-googlebot); printf 'User-agent: *\nAllow: /\n\nUser-agent: Googlebot\nDisallow: /\n' > "$d/out/robots.txt"
refused noindex "robots.txt that blocks only Googlebot" "$d" "" "googlebot"
d=$(case_dir ni-star); printf 'User-agent: *\nDisallow: /*\n' > "$d/out/robots.txt"
refused noindex "robots.txt with Disallow: /* (equivalent of /)" "$d"
d=$(case_dir ni-fallback); printf 'User-agent: Googlebot\nAllow: /\n\nUser-agent: *\nDisallow: /\n' > "$d/out/robots.txt"
refused noindex "Googlebot allowed, every other search crawler (Bing) blocked" "$d" "" "bingbot"
d=$(case_dir ni-page); printf 'User-agent: *\nDisallow: /over\n' > "$d/out/robots.txt"
allowed "robots.txt that keeps one page out (the client's choice)" "$d" "robots.txt keeps googlebot from this page"
d=$(case_dir ni-gmeta); subst "$d/out/over/index.html" '<meta charset="utf-8">' '<meta charset="utf-8"><meta name="googlebot" content="noindex">'
refused noindex "meta googlebot noindex" "$d" "" "googlebot"
d=$(case_dir ni-equiv); subst "$d/out/over/index.html" '<meta charset="utf-8">' '<meta charset="utf-8"><meta http-equiv="X-Robots-Tag" content="none">'
refused noindex "meta http-equiv X-Robots-Tag none" "$d"
d=$(case_dir ni-headers); printf '/*\n  X-Robots-Tag: noindex\n' > "$d/out/_headers"
refused noindex "X-Robots-Tag: noindex for /* in _headers" "$d" "" "X-Robots-Tag"
d=$(case_dir ni-headers-bot); printf '/\n  X-Robots-Tag: googlebot: noindex\n' > "$d/out/_headers"
refused noindex "X-Robots-Tag: googlebot: noindex for / in _headers" "$d"
d=$(case_dir ni-headers-path); printf '/intern/*\n  X-Robots-Tag: noindex\n' > "$d/out/_headers"
allowed "X-Robots-Tag only for /intern/* (the client's choice)" "$d" "those paths drop out of search"

printf '\n  %s7b. Size of the whole output (finding 11)%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir sz-files)
RUN_ENV=(NOTIFT_LOVABLE_MAX_OUTPUT_FILES=5)
refused size "more files than the limit (lowered to 5 for the test)" "$d" "" "over the limit of 5"
RUN_ENV=(NOTIFT_LOVABLE_MAX_OUTPUT_FILES=50)
allowed "the same output under a limit of 50 files" "$d"
d=$(case_dir sz-bytes); mkdir -p "$d/out/media"
python3 -I -c "import sys; [open(f'{sys.argv[1]}/v{i}.mp4','wb').write(b'x' * (900 * 1024)) for i in range(3)]" "$d/out/media"
RUN_ENV=(NOTIFT_LOVABLE_MAX_OUTPUT_MB=2)
refused size "more bytes than the limit (lowered to 2 MB for the test)" "$d" "" "over the limit of 2 MB"
RUN_ENV=(NOTIFT_LOVABLE_MAX_OUTPUT_MB=abc)
run "$d"; [ "$RC" -eq 2 ] && pass "an invalid limit is a usage error (exit 2)" || bad "an invalid limit gave exit $RC"
RUN_ENV=(NOTIFT_LOVABLE_MAX_OUTPUT_FILES=20001)
run "$d"; [ "$RC" -eq 2 ] && pass "a limit above the hard cap is a usage error (exit 2)" || bad "a limit above the cap gave exit $RC"
RUN_ENV=()

printf '\n  %s8. Third-party scripts%s\n' "$C_BOLD" "$C_OFF"
d=$(case_dir tp-gtm); subst "$d/out/over/index.html" '</head>' '<script async src="https://www.googletagmanager.com/gtag/js?id=G-X"></script></head>'
refused third-party "a Google Tag Manager script" "$d"
d=$(case_dir tp-proto); subst "$d/out/over/index.html" '</head>' '<script src="//cdn.example.com/chat.js"></script></head>'
refused third-party "a protocol-relative external script" "$d"
d=$(case_dir tp-preload); subst "$d/out/over/index.html" '</head>' '<link rel="modulepreload" href="https://cdn.example.com/x.js"></head>'
refused third-party "an external modulepreload" "$d"
d=$(case_dir tp-turnstile); subst "$d/out/over/index.html" '</head>' '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script></head>'
allowed "Turnstile, the one host the hosting itself loads" "$d"
UMAMI='<script defer src="https://stats.notift.app/script.js" data-website-id="00000000-0000-0000-0000-000000000000" data-domains="example.nl"></script>'
d=$(case_dir tp-umami); subst "$d/out/over/index.html" '</head>' "$UMAMI</head>"
allowed "Notift's own analytics, https://stats.notift.app/script.js" "$d"
d=$(case_dir tp-umami-path); subst "$d/out/over/index.html" '</head>' '<script src="https://stats.notift.app/other.js"></script></head>'
refused third-party "another path on stats.notift.app" "$d" "" "stats.notift.app/other.js"
d=$(case_dir tp-umami-query); subst "$d/out/over/index.html" '</head>' '<script src="https://stats.notift.app/script.js?v=2"></script></head>'
refused third-party "stats.notift.app/script.js with a query" "$d"
d=$(case_dir tp-umami-http); subst "$d/out/over/index.html" '</head>' '<script src="http://stats.notift.app/script.js"></script></head>'
refused third-party "stats.notift.app over plain http" "$d"
d=$(case_dir tp-umami-look); subst "$d/out/over/index.html" '</head>' '<script src="https://stats.notift.app.evil.example/script.js"></script></head>'
refused third-party "a lookalike host (stats.notift.app.evil.example)" "$d"
d=$(case_dir tp-umami-user); subst "$d/out/over/index.html" '</head>' '<script src="https://stats.notift.app@evil.example/script.js"></script></head>'
refused third-party "user info that hides another host" "$d"

if [ $# -ge 2 ]; then
  printf '\n%s== The real build: %s ==%s\n\n' "$C_BOLD" "$2" "$C_OFF"
  WANT="${3:-0}"
  REAL_RC=0
  REAL_OUT="$(python3 -I "$CHECK" --source "$1" --output "$2" 2>&1)" || REAL_RC=$?
  printf '%s\n' "$REAL_OUT" | sed 's/^/  /'
  if [ "$REAL_RC" -eq "$WANT" ] && ! printf '%s\n' "$REAL_OUT" | grep -q '^Traceback'; then
    pass "the real build exits $REAL_RC, as expected"
  else
    bad "the real build exits $REAL_RC, expected $WANT"
  fi
fi

printf '\n'
if [ "$FAILED" -ne 0 ]; then
  printf '  %sSomething is wrong with the check itself.%s\n\n' "$C_ERR" "$C_OFF" >&2
  exit 1
fi
printf '  %sEverything that must be refused is refused, and warnings do not block.%s\n\n' "$C_OK" "$C_OFF"
