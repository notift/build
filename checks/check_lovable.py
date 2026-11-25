#!/usr/bin/env python3
"""Refuses a Lovable (TanStack Start) project that breaks Notift's hosting rules.

Usage:
    check_lovable.py --source <repo-dir> --output <output-dir>    job 1: source and output
    check_lovable.py --output-only --output <output-dir>          job 2: output only

Exit 0 = ok (warnings allowed), 1 = refuse, 2 = usage error. Every finding is one
line on stderr: REFUSE or WARN, the rule, the file, and what is wrong. Text that comes
from the client (file names, HTML values) is escaped to one inert line (audit 2, N7).

Two modes (audit 2, finding N1). The source checks and the required routes run only in
job 1, which holds no publish token. Job 2 holds packages: write and runs --output-only on
the exact Docker context: it never opens the client's source tree. Every file this script
opens, in either mode, goes through Tree below: each path component is opened relative to
its parent without following a link, so nothing outside the given folder is ever opened.

This runs next to check_output.py, not instead of it. check_output.py already
refuses a page without a title, a missing index.html, an empty shell and secrets,
and warns on a missing description or language. This script only adds what is
specific to a Lovable project: its source tree carries server and storage features
that a static host cannot run, and its own AGENTS.md hosting rules.

The source tree is untrusted client code. It is only read, never executed or
imported. Standard library only, because this runs on a bare runner.

Rules (docs: NOTES-lovable-checks.md and NOTES-repair-checks.md in the work folder,
later 07-bouwlaag.md):
  prerender        vite.config.ts keeps prerender enabled; every required route has
                   its HTML in the output (the list: see "Required routes" below)      REFUSE
  lovable-storage  no *.asset.json, no /__l5e/, no Lovable storage hosts               REFUSE
  server-side      no server functions, API routes, Supabase, Lovable Cloud, AI
                   gateway or connectors; no server bundle in the output               REFUSE
  symlink          no link in the output; no link out of the source folder; a known
                   file (Vite config, routeTree.gen.ts, notift.routes.json, src/routes,
                   supabase, drizzle) is never read through a link                     REFUSE
  media            no file over 10 MB (REFUSE); a .mov file (WARN)
  size             output within MAX_OUTPUT_BYTES and MAX_OUTPUT_FILES               REFUSE
  forms            forms post to /_notift/forms/<name> on the site itself, with
                   method post and the hosting forms script with a site key;
                   no field named website                                              REFUSE
                   (a same-site GET form without the Notift path: WARN)
  page             lang nl, exactly one h1, unique titles and descriptions,
                   a canonical link                                                      WARN
  noindex          no noindex for any search crawler (meta, X-Robots-Tag in _headers),
                   no robots.txt that blocks the whole site for a search crawler       REFUSE
  third-party      no external <script src> outside the allowlist                      REFUSE

Evidence: findings from the output (what is published) are facts. Findings from source
text are pattern matches and say so with "[source heuristic]" in the message; they
still refuse where they concern server-side code or Lovable storage, because a miss
there means visitor data or our servers are involved.

Required routes (rule prerender): the union of
  1. the page routes derived from the file names under src/routes,
  2. the paths in FileRoutesByFullPath of src/routeTree.gen.ts, if present,
  3. the literal `tanstackStart.pages[].path` entries in the Vite config,
  4. the "pages" list in notift.routes.json at the source root, if present.
Every path from every source is normalized the same way first (percent-decoded as nginx
does, no empty, '.' or '..' segment, no slash or control character inside a segment). The
file nginx serves for it (try_files $uri $uri.html $uri/) must be a plain .html file inside
the output. A static route must have HTML. A dynamic route ($param) must have at least one listed
path (3 or 4) that matches it, and every listed path must have HTML. A catch-all route
($) without a listed path warns: only what was prerendered exists.

Limits on the output: MAX_OUTPUT_BYTES and MAX_OUTPUT_FILES. Notift can raise them per
site through NOTIFT_LOVABLE_MAX_OUTPUT_MB and NOTIFT_LOVABLE_MAX_OUTPUT_FILES, set by the
build layer (never by the client repo), capped at HARD_MAX_OUTPUT_*.
"""

import argparse
import errno
import json
import os
import re
import stat
import sys
from urllib.parse import unquote_to_bytes, urljoin, urlsplit

# No __pycache__ next to the build layer: release.sh copies checks/ as a whole.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_output  # noqa: E402  (next to this script; reuse its HTML reader and page list)

# ---------------------------------------------------------------------------
# Limits and lists.

MAX_FILE_BYTES = 10 * 1024 * 1024      # rule 4: no single published file over 10 MB
MAX_SOURCE_READ = 16 * 1024 * 1024     # a source code file larger than this is not readable for us

# Rule size (audit finding 11). Defaults fit a Lovable marketing site many times over (the JKE test
# build is 19 MB in 94 files). Notift raises them per site through the environment, never above the
# hard caps, which follow Cloudflare Pages (20,000 files) and GitHub Pages (1 GB per site).
MAX_OUTPUT_BYTES = 200 * 1024 * 1024
MAX_OUTPUT_FILES = 5000
HARD_MAX_OUTPUT_BYTES = 1024 * 1024 * 1024
HARD_MAX_OUTPUT_FILES = 20000
ENV_MAX_MB = "NOTIFT_LOVABLE_MAX_OUTPUT_MB"
ENV_MAX_FILES = "NOTIFT_LOVABLE_MAX_OUTPUT_FILES"

# A list of routes the client states explicitly (rule prerender, audit finding 9).
ROUTES_FILE = "notift.routes.json"
MAX_LISTED_ROUTES = 2000
MAX_ROUTE_LEN = 300
MAX_ROUTES_FILE = 1024 * 1024

# Diagnostics (audit 2, finding N7): at most this many finding lines, and GitHub shows ten
# error annotations per step anyway.
MAX_PRINTED = 300
MAX_ANNOTATIONS = 10

# Build outputs and installed packages. Everything else in the repo is scanned,
# because anything else can be imported by the build.
SKIP_SOURCE_DIRS = {
    "node_modules", ".git", ".output", "dist", ".wrangler", ".vinxi", ".nitro",
    ".tanstack", ".vercel", ".netlify",
}
CODE_EXT = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
TEXT_EXT = CODE_EXT + (".css", ".scss", ".sass", ".less", ".html", ".htm", ".json",
                       ".svg", ".xml", ".webmanifest", ".txt", ".map")
# Lockfiles list registry URLs, never bundled.
SKIP_SOURCE_FILES = {"package-lock.json", "bun.lock", "pnpm-lock.yaml", "yarn.lock"}

ROUTE_EXT = (".tsx", ".ts", ".jsx", ".js")

# Pages that do not need to be found; reuse the list of check_output.py.
TECHNICAL_PAGES = check_output.TECHNISCHE_PAGINAS

# Rule 8. External scripts a page may load from a <script src> tag or a script preload.
# Only what Notift itself brings, as (host, exact path or None for any path), https only
# (a protocol-relative URL counts as https, the sites are served over https only):
#   - challenges.cloudflare.com: Turnstile, which the forms script loads (decision 108 in
#     docs/11-formulieren.md).
#   - stats.notift.app/script.js: Notift's own Umami analytics (Leon, 25 November 2026), the
#     same tag MD Coach carries. Exactly that path, no query, no port: another path on the
#     host or a lookalike host stays refused.
# A project exception belongs in a Notift-controlled place (see the notes), never in this
# file per client and never in the client repo.
HOSTING_SCRIPTS = (
    ("challenges.cloudflare.com", None),
    ("stats.notift.app", "/script.js"),
)

FORM_PATH = re.compile(r"^/_notift/forms/[a-z0-9-]{1,40}$")  # same as infra/build/embed/forms.js
HONEYPOT_FIELD = "website"                                   # decision 43, docs/11-formulieren.md
FORMS_SCRIPT = "/_notift/embed/forms.js"                     # 11-formulieren.md, the script of the own domain
SITEKEY = re.compile(r"^[0-9A-Za-z_-]{8,64}$")               # same as infra/build/embed/forms.js
SITE_ORIGIN = "https://site.notift.invalid"                  # to resolve relative URLs of a page

# Rule noindex. Search crawlers whose robots.txt group or meta tag must not block the site.
# Lower case product tokens, RFC 9309. Other agents (AI crawlers and the like) are the client's choice.
SEARCH_CRAWLERS = (
    "googlebot", "googlebot-image", "googlebot-news", "googlebot-video",
    "bingbot", "msnbot", "adidxbot", "duckduckbot", "yandex", "yandexbot", "baiduspider",
    "slurp", "applebot", "naverbot", "seznambot", "qwantify",
)

L5E = re.compile(rb"/__l5e/")
LOVABLE_HOST = re.compile(
    rb"(?<![A-Za-z0-9.-])((?:[A-Za-z0-9-]+\.)*(?:lovable\.(?:app|dev|cloud)|lovableproject\.com))(?![A-Za-z0-9-])",
    re.IGNORECASE,
)
# Plain links to Lovable's own site are harmless; everything else is a Lovable service.
LOVABLE_LINK_HOSTS = {"lovable.dev", "www.lovable.dev", "docs.lovable.dev"}
SUPABASE_HOST = re.compile(rb"(?<![A-Za-z0-9.-])[A-Za-z0-9-]+\.supabase\.(?:co|in)(?![A-Za-z0-9-])", re.IGNORECASE)

# Rule 3: TanStack Start server features. Matched on source with comments removed.
SERVER_PATTERNS = [
    (re.compile(r"\bcreateServerFn\b"), "a server function (createServerFn)"),
    (re.compile(r"\bcreateServerFileRoute\b"), "a server route (createServerFileRoute)"),
    (re.compile(r"\bcreateServerRoute\b"), "a server route (createServerRoute)"),
    (re.compile(r"\bcreateAPIFileRoute\b"), "an API route (createAPIFileRoute)"),
    (re.compile(r"\bcreateAPIRoute\b"), "an API route (createAPIRoute)"),
    (re.compile(r"\bserver\s*:\s*\{[^{}]*?\bhandlers\s*:", re.S), "server route handlers (server.handlers)"),
    (re.compile(r"\bLOVABLE_API_KEY\b"), "the Lovable AI gateway or a connector (LOVABLE_API_KEY)"),
]
IMPORT_SPEC = re.compile(
    r"""(?:\bimport\s*(?:type\s+)?(?:[\w$*{}\s,]+\s*from\s*)?|\bexport\s+[\w$*{}\s,]+\s*from\s*|\bimport\s*\(\s*|\brequire\s*\(\s*)["']([^"'\n]+)["']"""
)
ALLOWED_LOVABLE_PACKAGES = {"@lovable.dev/vite-tanstack-config"}  # build config only, never bundled


def forbidden_import(spec):
    if spec.startswith("@supabase/"):
        return "Supabase"
    if re.search(r"(^|/)integrations/supabase(/|$)", spec):
        return "Lovable Cloud (Supabase client)"
    if spec.startswith("@lovable.dev/") and spec not in ALLOWED_LOVABLE_PACKAGES:
        return "a Lovable service package (Cloud, AI gateway or connector)"
    return None


# ---------------------------------------------------------------------------
# Bounded file access (audit 2, finding N1).

O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)


class LinkRefused(Exception):
    """A component of the path is a link. Nothing behind it was opened."""


class Tree:
    """One folder of untrusted files, read only through file descriptors.

    Every component below the root, start folders like src/routes, supabase or drizzle
    included, is opened relative to its parent with O_NOFOLLOW. A link anywhere on the
    way therefore fails before anything behind it is opened. A file is read only when
    fstat on the open descriptor says it is a regular file, and never more than the
    caller's limit plus one byte. Links are reported to the caller, never followed. The
    root itself is the caller's own argument (it may sit behind a system link like /tmp).
    Paths are relative, with '/' between components.
    """

    DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | O_CLOEXEC
    FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | O_CLOEXEC

    def __init__(self, root):
        self.root = root
        self.real = os.path.realpath(root)

    @staticmethod
    def parts(rel):
        parts = rel.split("/") if rel else []
        if any(p in ("", ".", "..") or "\0" in p for p in parts):
            raise ValueError(f"not a plain relative path: {rel!r}")
        return parts

    @staticmethod
    def _is_link(dir_fd, name):
        try:
            return stat.S_ISLNK(os.stat(name, dir_fd=dir_fd, follow_symlinks=False).st_mode)
        except OSError:
            return False

    def _open_dir(self, parts):
        """A descriptor of the folder at parts. Raises LinkRefused, or OSError when absent."""
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | O_CLOEXEC)
        try:
            for i, name in enumerate(parts):
                try:
                    nxt = os.open(name, self.DIR_FLAGS, dir_fd=fd)
                except OSError as e:
                    if e.errno in (errno.ELOOP, errno.ENOTDIR, errno.EMLINK) and self._is_link(fd, name):
                        raise LinkRefused("/".join(parts[:i + 1]))
                    raise
                os.close(fd)
                fd = nxt
            return fd
        except BaseException:
            os.close(fd)
            raise

    def kind(self, rel):
        """'file', 'dir', 'link', 'special' or 'missing', without following a link."""
        parts = self.parts(rel)
        if not parts:
            return "dir"
        try:
            dfd = self._open_dir(parts[:-1])
        except LinkRefused:
            return "link"
        except OSError:
            return "missing"
        try:
            mode = os.stat(parts[-1], dir_fd=dfd, follow_symlinks=False).st_mode
        except OSError:
            return "missing"
        finally:
            os.close(dfd)
        if stat.S_ISLNK(mode):
            return "link"
        if stat.S_ISDIR(mode):
            return "dir"
        return "file" if stat.S_ISREG(mode) else "special"

    def size(self, rel):
        parts = self.parts(rel)
        try:
            dfd = self._open_dir(parts[:-1])
        except (LinkRefused, OSError):
            return None
        try:
            st = os.stat(parts[-1], dir_fd=dfd, follow_symlinks=False)
            return st.st_size if stat.S_ISREG(st.st_mode) else None
        except OSError:
            return None
        finally:
            os.close(dfd)

    def read(self, rel, limit):
        """(status, data). status is 'ok', 'missing', 'link', 'dir', 'special' or 'unreadable';
        data (status 'ok') holds at most limit + 1 bytes, so a caller sees a larger file."""
        parts = self.parts(rel)
        if not parts:
            return "dir", None
        try:
            dfd = self._open_dir(parts[:-1])
        except LinkRefused:
            return "link", None
        except (FileNotFoundError, NotADirectoryError):
            return "missing", None
        except OSError:
            return "unreadable", None
        try:
            try:
                fd = os.open(parts[-1], self.FILE_FLAGS, dir_fd=dfd)
            except FileNotFoundError:
                return "missing", None
            except OSError:
                return ("link" if self._is_link(dfd, parts[-1]) else "unreadable"), None
            with os.fdopen(fd, "rb") as fh:
                mode = os.fstat(fh.fileno()).st_mode
                if stat.S_ISDIR(mode):
                    return "dir", None
                if not stat.S_ISREG(mode):
                    return "special", None
                try:
                    return "ok", fh.read(limit + 1)
                except OSError:
                    return "unreadable", None
        finally:
            os.close(dfd)

    def walk(self, start="", skip_dirs=()):
        """(rel, 'file' | 'link') for every regular file and link under start, sorted, depth
        first. A link is reported, never followed; special files are skipped. A folder that
        turns into a link while walking is reported as a link. Raises LinkRefused or OSError
        when start itself cannot be opened as a plain folder."""
        stack = [start]
        first = True
        while stack:
            rel = stack.pop()
            try:
                fd = self._open_dir(self.parts(rel))
            except LinkRefused:
                if first:
                    raise
                yield rel, "link"
                continue
            except OSError:
                if first:
                    raise
                continue
            first = False
            try:
                with os.scandir(fd) as it:
                    entries = sorted(it, key=lambda e: e.name)
            except OSError:
                entries = []
            finally:
                os.close(fd)
            subdirs = []
            for e in entries:
                child = f"{rel}/{e.name}" if rel else e.name
                try:
                    if e.is_symlink():
                        if e.name not in skip_dirs:
                            yield child, "link"
                    elif e.is_dir(follow_symlinks=False):
                        if e.name not in skip_dirs:
                            subdirs.append(child)
                    elif e.is_file(follow_symlinks=False):
                        yield child, "file"
                except OSError:
                    continue
            stack.extend(reversed(subdirs))

    def link_leaves(self, rel):
        """True when the link at rel resolves to a place outside the root. Uses only lstat and
        readlink on the way (os.path.realpath), never an open of the target."""
        target = os.path.realpath(os.path.join(self.real, *self.parts(rel)))
        return not inside(target, self.real)


# ---------------------------------------------------------------------------

class Findings:
    def __init__(self):
        self.refusals = []
        self.warnings = []

    def refuse(self, rule, where, what):
        self.refusals.append((rule, where, what))

    def warn(self, rule, where, what):
        self.warnings.append((rule, where, what))


def line(kind, rule, where, what):
    return f"{kind} lovable/{rule}: {where}: {what}" if where else f"{kind} lovable/{rule}: {what}"


# ---------------------------------------------------------------------------
# Reading JavaScript without running it.

def strip_comments(text):
    """Blank out // and /* */ comments, keep strings intact.

    A comment is not code, so a commented-out server function is not a finding.
    Strings are kept because import specifiers live in them. Regex literals are
    skipped by a heuristic on the previous character, good enough for configs.
    """
    out = []
    i, n = 0, len(text)
    prev = ""  # last non-space code character
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if c == "/" and nxt == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
            continue
        if c in "'\"`":
            j = i + 1
            while j < n and text[j] != c:
                if text[j] == "\\":
                    j += 1
                elif c != "`" and text[j] == "\n":
                    break
                j += 1
            j = min(j + 1, n)
            out.append(text[i:j])
            i = j
            prev = c
            continue
        if c == "/" and (prev == "" or prev in "(,=:[!&|?{};+-*%<>~^"):
            # A regex literal: copy it as is, so its quotes or slashes do not start anything.
            j, in_class = i + 1, False
            while j < n and text[j] != "\n":
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == "[":
                    in_class = True
                elif text[j] == "]":
                    in_class = False
                elif text[j] == "/" and not in_class:
                    break
                j += 1
            j = min(j + 1, n)
            out.append(text[i:j])
            i = j
            prev = "/"
            continue
        out.append(c)
        if not c.isspace():
            prev = c
        i += 1
    return "".join(out)


TOKEN = re.compile(
    r"""\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`|\.\.\.|[A-Za-z_$][\w$]*|\d[\w.]*|\S"""
)


def tokens_of(code):
    return [m.group(0) for m in TOKEN.finditer(code)]


def unquote(tok):
    if len(tok) >= 2 and tok[0] in "'\"" and tok[-1] == tok[0]:
        return tok[1:-1]
    return tok


def skip_expr(toks, j):
    """Advance to the ',' or closing bracket that ends this value."""
    depth = 0
    while j < len(toks):
        t = toks[j]
        if t in "([{":
            depth += 1
        elif t in ")]}":
            if depth == 0:
                return j
            depth -= 1
        elif t == "," and depth == 0:
            return j
        j += 1
    return j


def parse_object(toks, i):
    """toks[i] is '{'. Returns (props, opaque): props maps key -> index of its value
    (None when the value is not a plain 'key: value'), opaque is True when a spread
    or a computed key makes the object impossible to verify by reading."""
    props, opaque = {}, False
    j = i + 1
    while j < len(toks) and toks[j] != "}":
        t = toks[j]
        if t == "...":
            opaque = True
            j = skip_expr(toks, j + 1)
        elif t == "[":
            opaque = True
            j = skip_expr(toks, j)
        else:
            key = unquote(t)
            j += 1
            if j < len(toks) and toks[j] == ":":
                props[key] = j + 1
                j = skip_expr(toks, j + 1)
            else:
                props[key] = None
                j = skip_expr(toks, j)
        if j < len(toks) and toks[j] == ",":
            j += 1
    return props, opaque


def literal_pages(toks, ts_props):
    """Literal `tanstackStart.pages: [{ path: "/x" }, ...]` entries. Anything that is not a
    literal string path is ignored here; notift.routes.json can state it instead."""
    out = []
    i = ts_props.get("pages")
    if i is None or i >= len(toks) or toks[i] != "[":
        return out
    j = i + 1
    while j < len(toks) and toks[j] != "]":
        if toks[j] == "{":
            props, _ = parse_object(toks, j)
            v = props.get("path")
            if v is not None and v + 1 < len(toks) and toks[v][:1] in "'\"" and toks[v + 1] in (",", "}"):
                out.append(unquote(toks[v]))
        j = skip_expr(toks, j)
        if j < len(toks) and toks[j] == ",":
            j += 1
    return out


def read_plain(tree, rel, f, rule, limit):
    """The bytes of a known source file, or None when it is absent. A link or a special file in its
    place is refused on `rule` (None: skipped quietly), and never opened (audit 2, finding N1)."""
    status, data = tree.read(rel, limit)
    if status == "ok":
        if len(data) > limit:
            if rule:
                f.refuse(rule, rel, f"over {limit // 1024} KiB, too large to verify")
            return None
        return data
    if status != "missing" and rule:
        what = {"link": "is a link (or lies behind one); the check reads only a plain file in the repo",
                "dir": "is a folder, not a file"}.get(status, "is not a readable plain file")
        f.refuse(rule, rel, what)
    return None


VITE_CONFIGS = ["vite.config.ts", "vite.config.mts", "vite.config.js", "vite.config.mjs",
                "vite.config.cts", "vite.config.cjs"]


def check_vite_config(tree, f):
    """Checks the literal prerender setting and returns the literal tanstackStart.pages paths."""
    found = [n for n in VITE_CONFIGS if tree.kind(n) != "missing"]
    if not found:
        f.refuse("prerender", "vite.config.ts", "missing: cannot verify that every page prerenders to HTML")
        return []
    if len(found) > 1:
        f.refuse("prerender", ", ".join(found), "more than one Vite config: cannot tell which one the build uses")
        return []
    name = found[0]
    data = read_plain(tree, name, f, "prerender", MAX_SOURCE_READ)
    if data is None:
        return []
    code = strip_comments(data.decode("utf-8", "replace"))
    toks = tokens_of(code)
    start = None
    for k in range(len(toks) - 4):
        if toks[k:k + 5] == ["export", "default", "defineConfig", "(", "{"]:
            start = k + 4
            break
    expected = "keep `tanstackStart: { prerender: { enabled: true, crawlLinks: false } }` (AGENTS.md hosting rule 2)"
    if start is None:
        f.refuse("prerender", name, f"no `export default defineConfig({{ ... }})` found; {expected}")
        return []
    cfg, opaque = parse_object(toks, start)
    if opaque:
        f.refuse("prerender", name, f"the config object uses a spread or computed key and cannot be verified; {expected}")
        return []
    ts = cfg.get("tanstackStart")
    if ts is None or ts >= len(toks) or toks[ts] != "{":
        f.refuse("prerender", name, f"`tanstackStart` is missing or not an object literal; {expected}")
        return []
    ts_props, opaque = parse_object(toks, ts)
    if opaque:
        f.refuse("prerender", name, f"`tanstackStart` uses a spread or computed key and cannot be verified; {expected}")
        return []
    pages = literal_pages(toks, ts_props)
    pr = ts_props.get("prerender")
    if pr is None or pr >= len(toks) or toks[pr] != "{":
        f.refuse("prerender", name, f"`prerender` is missing inside `tanstackStart` or not an object literal; {expected}")
        return pages
    pr_props, opaque = parse_object(toks, pr)
    if opaque:
        f.refuse("prerender", name, f"`prerender` uses a spread or computed key and cannot be verified; {expected}")
        return pages
    en = pr_props.get("enabled")
    if en is None or toks[en] != "true" or en + 1 >= len(toks) or toks[en + 1] not in (",", "}"):
        f.refuse("prerender", name, f"`prerender.enabled` is not literally `true`; {expected}")
    return pages


# ---------------------------------------------------------------------------
# Source tree.

def inside(path, root_real):
    return path == root_real or path.startswith(root_real.rstrip(os.sep) + os.sep)


def lovable_hosts(data):
    hosts = set()
    for m in LOVABLE_HOST.finditer(data):
        host = m.group(1).decode("ascii", "ignore").lower()
        if host not in LOVABLE_LINK_HOSTS:
            hosts.add(host)
    return hosts


def host_rule(host):
    if "gateway" in host or host.endswith("lovable.cloud") or "connector" in host:
        return "server-side", "a Lovable service host (AI gateway, connector or Cloud)"
    return "lovable-storage", "a Lovable storage or preview host, which does not exist on Notift hosting"


HEURISTIC = "[source heuristic]"


def check_source(tree, f):
    for top in ("supabase", "drizzle"):
        kind = tree.kind(top)
        if kind == "link":
            f.refuse("server-side", top + "/", "a link where database or edge-function files belong; "
                                               "nothing server-side runs on Notift hosting")
        elif kind == "dir" and any(True for _ in tree.walk(top)):
            f.refuse("server-side", top + "/",
                     "database or edge-function files (Supabase, Lovable Cloud or Drizzle); nothing server-side runs on Notift hosting")

    for rel, kind in tree.walk("", SKIP_SOURCE_DIRS):
        if kind == "link":
            # Never followed. One that leaves the repo is refused: the build could read the runner.
            if tree.link_leaves(rel):
                f.refuse("symlink", rel,
                         "a link to outside the source folder; the build could read files of the build machine into the site")
            continue
        name = rel.rsplit("/", 1)[-1]
        low = name.lower()
        parts = rel.split("/")

        if low.endswith(".asset.json"):
            f.refuse("lovable-storage", rel, "a Lovable asset pointer; put the file under public/ and reference it by a / path")
            continue
        if parts[0] == "supabase" or parts[0] == "drizzle":
            continue  # reported once above
        if not low.endswith(TEXT_EXT) or name in SKIP_SOURCE_FILES:
            continue

        status, data = tree.read(rel, MAX_SOURCE_READ)
        if status != "ok":
            if status == "link":
                f.refuse("symlink", rel, "became a link while the check ran; nothing behind it was read")
            continue
        if len(data) > MAX_SOURCE_READ:
            if low.endswith(CODE_EXT):
                f.refuse("server-side", rel, f"source file over {MAX_SOURCE_READ // (1024 * 1024)} MB, too large to verify")
            continue

        is_code = low.endswith(CODE_EXT)
        text = data.decode("utf-8", "replace")
        if is_code:
            text = strip_comments(text)
        scan = text.encode("utf-8", "replace")

        if L5E.search(scan):
            f.refuse("lovable-storage", rel, f"{HEURISTIC} references Lovable storage (/__l5e/), which does not exist on Notift hosting")
        for host in sorted(lovable_hosts(scan)):
            rule, what = host_rule(host)
            f.refuse(rule, rel, f"{HEURISTIC} references {host}: {what}")

        if not is_code:
            continue
        for pattern, what in SERVER_PATTERNS:
            if pattern.search(text):
                f.refuse("server-side", rel, f"{HEURISTIC} {what}; nothing server-side runs on Notift hosting")
        for m in IMPORT_SPEC.finditer(text):
            why = forbidden_import(m.group(1))
            if why:
                f.refuse("server-side", rel, f"{HEURISTIC} imports {m.group(1)} ({why}); nothing server-side runs on Notift hosting")

    data = read_plain(tree, "package.json", f, None, MAX_SOURCE_READ)
    if data:
        for dep in sorted(set(re.findall(rb'"(@supabase/[^"]+|@lovable\.dev/[^"]+)"\s*:', data))):
            dep = dep.decode("utf-8", "replace")
            if dep not in ALLOWED_LOVABLE_PACKAGES:
                f.warn("server-side", "package.json",
                       f"depends on {dep}; not imported, so not built in, but it should go")


# ---------------------------------------------------------------------------
# Routes (rule 1, second half).

def segment_pattern(seg):
    """A regex for one URL segment of a TanStack route, or None for a splat ($)."""
    if seg == "$":
        return None
    out, i = [], 0
    while i < len(seg):
        m = re.match(r"\{-?\$[A-Za-z_][\w]*\}|\$[A-Za-z_][\w]*", seg[i:])
        if m:
            out.append("[^/]+")
            i += m.end()
        else:
            out.append(re.escape(seg[i]))
            i += 1
    return "".join(out)


def route_regex(url):
    """A full-path regex for a route given as URL segments. {-$x} segments are optional,
    a final $ matches the rest of the path (at least one segment)."""
    parts = []
    for s in url:
        if s == "$":
            parts.append("(?:/.+)")
            break
        pat = segment_pattern(s)
        if re.fullmatch(r"\{-\$[A-Za-z_]\w*\}", s):
            parts.append(f"(?:/{pat})?")
        else:
            parts.append("/" + pat)
    return re.compile("^" + ("".join(parts) or "/") + "$")


def kind_of(url):
    for s in url:
        if s == "$":
            return "splat"
        if "$" in s:
            return "dynamic"
    return "static"


def route_paths(tree, f):
    """Yields (rel_file, url_segments, kind) for every page route in src/routes.
    kind is 'static', 'dynamic', 'splat' or 'api'. Derived from file names only."""
    kind = tree.kind("src/routes")
    if kind == "link":
        f.refuse("prerender", "src/routes", "is a link (or lies behind one); route files must be plain files in the repo")
        return
    if kind != "dir":
        f.refuse("prerender", "src/routes", "missing: cannot verify that every route prerenders")
        return
    for rel, entry in tree.walk("src/routes"):
        rel_routes = rel[len("src/routes/"):]
        if entry == "link":
            f.refuse("prerender", rel, "a link among the route files; route files must be plain files in the repo")
            continue
        if not rel_routes.endswith(ROUTE_EXT) or rel_routes.endswith(".d.ts"):
            continue
        if re.search(r"\.(test|spec)\.[jt]sx?$", rel_routes):
            continue
        stem = re.sub(r"\.(tsx|ts|jsx|js)$", "", rel_routes)
        stem = re.sub(r"\.lazy$", "", stem)
        segs = []
        for part in stem.split("/"):
            segs.extend(part.replace("[.]", "\0").split("."))
        segs = [s.replace("\0", ".") for s in segs]
        if any(s.startswith("-") for s in segs):
            continue  # ignored by the router (routeFileIgnorePrefix)
        last = segs[-1]
        if last == "__root" or last == "route" or last.startswith("_"):
            continue  # root shell, directory route config or pathless layout
        if segs[0] == "api":
            yield rel, segs, "api"
            continue
        url = []
        for s in segs:
            if s.startswith("_") or (s.startswith("(") and s.endswith(")")):
                continue
            url.append(s.rstrip("_") if s.endswith("_") else s)
        if url and url[-1] == "index":
            url = url[:-1]
        url = [re.sub(r"\[(.)\]", r"\1", s) for s in url]
        yield rel, url, kind_of(url)


def generated_routes(tree, f):
    """Full paths from the router's own generated tree, when the repo carries it."""
    data = read_plain(tree, "src/routeTree.gen.ts", f, "prerender", MAX_SOURCE_READ)
    if not data:
        return []
    text = data.decode("utf-8", "replace")
    m = re.search(r"interface\s+FileRoutesByFullPath\s*\{([^}]*)\}", text)
    if not m:
        return []
    paths = []
    for key in re.findall(r"""^\s*['"]([^'"\n]+)['"]\s*:""", m.group(1), re.M):
        if key.startswith("/"):
            paths.append(key)
    return paths


def listed_routes(tree, f):
    """The pages a client lists in notift.routes.json: {"pages": ["/blog/eerste-week", ...]}."""
    data = read_plain(tree, ROUTES_FILE, f, "prerender", MAX_ROUTES_FILE)
    if data is None:
        return []
    try:
        data = json.loads(data.decode("utf-8"))
    except ValueError as e:
        f.refuse("prerender", ROUTES_FILE, f"not readable JSON ({e.__class__.__name__})")
        return []
    pages = data.get("pages") if isinstance(data, dict) else None
    if not isinstance(pages, list) or len(pages) > MAX_LISTED_ROUTES:
        f.refuse("prerender", ROUTES_FILE, f'needs {{"pages": [...]}} with at most {MAX_LISTED_ROUTES} paths')
        return []
    return pages


def normalize_route(path):
    """A route path as nginx looks it up: (segments, trailing slash), or None when it is not a
    plain site path. The same for every route source, before any file test (audit 2, N3): a
    string of at most MAX_ROUTE_LEN that starts with '/', no query or fragment, percent-decoded
    the way nginx decodes it, and no empty, '.' or '..' segment, no slash or backslash inside a
    segment and no control character."""
    if not isinstance(path, str) or not path.startswith("/") or len(path) > MAX_ROUTE_LEN:
        return None
    if "?" in path or "#" in path:
        return None
    raw = path[1:]
    trailing = raw.endswith("/")
    if trailing:
        raw = raw[:-1]
        if not raw:
            return None
    segs = []
    for seg in raw.split("/") if raw else []:
        try:
            dec = unquote_to_bytes(seg).decode("utf-8")
        except UnicodeDecodeError:
            return None
        if dec in ("", ".", "..") or "/" in dec or "\\" in dec or not dec.isprintable():
            return None
        segs.append(dec)
    return segs, trailing


def route_key(norm):
    segs, trailing = norm
    return "/" + "/".join(segs) + ("/" if trailing and segs else "")


def html_for(tree, norm):
    """(ok, what) for a normalized route: the file nginx serves for it must be an .html regular file
    inside the output (base/nginx.conf: a trailing slash redirects to the page without one when that
    .html exists, else $uri/index.html; without a slash try_files $uri $uri.html $uri/). The first
    candidate that exists decides, as in nginx; a link is never opened (audit 2, N3)."""
    segs, trailing = norm
    if not segs:
        candidates = ["index.html"]
    else:
        p = "/".join(segs)
        if trailing and tree.kind(p + ".html") == "missing":
            candidates = [p + "/index.html"]
        else:
            candidates = [p, p + ".html", p + "/index.html"]
    for rel in candidates:
        kind = tree.kind(rel)
        if kind in ("missing", "dir"):
            continue
        if kind != "file":
            return False, f"nginx would serve {rel}, which is a link or a special file, not a plain file"
        if not rel.lower().endswith((".html", ".htm")):
            return False, f"nginx would serve {rel}, which is not an .html page"
        status, _ = tree.read(rel, 0)
        if status != "ok":
            return False, f"{rel} is not a readable plain file"
        return True, rel
    return False, f"no {candidates[-1]} in the output"


def check_routes(source, output, f, config_pages=()):
    """Every required route must have HTML in the output (audit finding 9). Every path, from
    whatever source, is normalized and validated first (audit 2, finding N3)."""
    routes = []        # (where, url segments, kind)
    for rel, url, kind in route_paths(source, f):
        if kind == "api":
            f.refuse("server-side", rel, "an API route under src/routes/api; nothing server-side runs on Notift hosting")
            continue
        routes.append((rel, url, kind))
    for full in generated_routes(source, f):
        url = [x for x in full.strip("/").split("/") if x]
        if url and url[0] == "api":
            continue  # the route files themselves are refused above
        routes.append(("src/routeTree.gen.ts", url, kind_of(url)))

    listed = []        # (canonical path, where, normalized): normalized once, kept for the file test (audit 3, N3)
    for raw, where in [(p, "vite.config (tanstackStart.pages)") for p in config_pages] + \
                      [(p, ROUTES_FILE) for p in listed_routes(source, f)]:
        norm = normalize_route(raw)
        if norm is None:
            f.refuse("prerender", where if where == ROUTES_FILE else "vite.config",
                     f"not a plain site path: {str(raw)[:80]}")
            continue
        listed.append((route_key(norm), where, norm))

    required = {}      # canonical path -> (where, normalized)
    patterns = []      # (regex, where, kind, prefix)

    def require(path, where):
        norm = normalize_route(path)
        if norm is None:
            f.refuse("prerender", where, f"route {path[:80]} is not a plain site path")
            return
        required.setdefault(route_key(norm), (where, norm))

    for where, url, kind in routes:
        if kind == "static":
            require("/" + "/".join(url), where)
            continue
        if any(re.fullmatch(r"\{-\$[A-Za-z_]\w*\}", x) for x in url) and kind == "dynamic":
            plain = [x for x in url if not re.fullmatch(r"\{-\$[A-Za-z_]\w*\}", x)]
            if kind_of(plain) == "static":
                require("/" + "/".join(plain), where)
        prefix = "/" + "/".join(x for x in url[:next(i for i, x in enumerate(url) if "$" in x)])
        patterns.append((route_regex(url), where, kind, prefix))

    listed_set = {(path, where) for path, where, _ in listed}
    for path, where, norm in listed:
        # The key is already decoded: decoding it again would turn %2520 into a space (audit 3, N3).
        required.setdefault(path, (where, norm))

    def covered_by_specific(path):
        """A listed path that a static or dynamic route serves does not count for a catch-all."""
        norm = path.rstrip("/") or "/"
        return norm in {r.rstrip("/") or "/" for r, (w, _) in required.items() if (r, w) not in listed_set} \
            or any(rx.match(norm) for rx, _, k, _ in patterns if k == "dynamic")

    for rx, where, kind, prefix in patterns:
        if any(rx.match(p.rstrip("/") or "/") and (kind == "dynamic" or not covered_by_specific(p))
               for p, _, _ in listed):
            continue
        if kind == "splat":
            f.warn("prerender", where, f"catch-all route under {prefix}: no path listed, so only what the build "
                                       f"prerendered exists on Notift hosting; list paths in {ROUTES_FILE}")
        else:
            f.refuse("prerender", where, f"dynamic route under {prefix} has no listed path; list its prerendered "
                                         f"paths in {ROUTES_FILE} or tanstackStart.pages")

    for path in sorted(required):
        where, norm = required[path]
        ok, want = html_for(output, norm)
        if not ok:
            f.refuse("prerender", where, f"required route {path}: {want}; it would be an empty shell or a 404")
    return len(required)


# ---------------------------------------------------------------------------
# Output (rules 2 to 8).

class Page(check_output.Pagina):
    """check_output's reader, plus what this check needs: h1 count, canonical,
    robots, forms with their controls, and external scripts."""

    FIELDS = {"input", "select", "textarea", "button"}

    def __init__(self):
        super().__init__()
        self.h1 = 0
        self.lang_seen = None
        self.canonical = False
        self.noindex_by = []   # what said noindex, for the message (check_output owns self.noindex)
        self.forms = []        # dicts: action (None if absent), method, submit, fields, overrides
        self.loose = []        # (formaction, formmethod) of controls outside any form
        self.fields = []       # every field name on the page
        self.scripts = []      # src of <script> and script preloads
        self.forms_scripts = []  # data-sitekey of each <script src> that is the hosting forms script
        self.styles = []       # href of stylesheets
        self._form = None

    def handle_starttag(self, tag, attrs):
        super().handle_starttag(tag, attrs)
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "html" and self.lang_seen is None:
            self.lang_seen = a.get("lang", "")
        if tag == "h1" and self.diepte_negeren == 0:
            self.h1 += 1
        if tag == "meta":
            name = (a.get("name") or "").strip().lower()
            equiv = (a.get("http-equiv") or "").strip().lower()
            content = (a.get("content") or "").lower()
            if (name == "robots" or name in SEARCH_CRAWLERS or equiv == "x-robots-tag") \
                    and re.search(r"\b(noindex|none)\b", content):
                self.noindex_by.append(f'<meta {"name" if name else "http-equiv"}="{name or equiv}" content="{content.strip()}">')
        if tag == "link":
            rel = (a.get("rel") or "").lower().split()
            if "canonical" in rel and a.get("href"):
                self.canonical = True
            if ("modulepreload" in rel or ("preload" in rel and (a.get("as") or "").lower() == "script")) and a.get("href"):
                self.scripts.append(a["href"])
            if "stylesheet" in rel and a.get("href"):
                self.styles.append(a["href"])
        if tag == "script" and a.get("src"):
            self.scripts.append(a["src"])
            if resolve(a["src"], "/") == ("local", FORMS_SCRIPT):
                self.forms_scripts.append(a.get("data-sitekey", ""))
        if tag == "form":
            self._form = {
                "action": a["action"] if "action" in a else None,
                "method": (a.get("method") or "get").strip().lower(),
                "submit": False, "fields": [], "overrides": [],
            }
            self.forms.append(self._form)
        if tag in self.FIELDS:
            typ = (a.get("type") or ("submit" if tag == "button" else "")).strip().lower()
            if a.get("name"):
                self.fields.append(a["name"])
            if self._form is not None:
                if a.get("name"):
                    self._form["fields"].append(a["name"])
                # forms.js wires only an element matching [type="submit"], so the attribute must be there.
                if (a.get("type") or "").strip().lower() == "submit":
                    self._form["submit"] = True
            if typ in ("submit", "image") and ("formaction" in a or "formmethod" in a):
                override = (a.get("formaction") if "formaction" in a else None,
                            (a.get("formmethod") or "").strip().lower() or None)
                if self._form is not None:
                    self._form["overrides"].append(override)
                else:
                    self.loose.append(override)

    def handle_endtag(self, tag):
        super().handle_endtag(tag)
        if tag == "form":
            self._form = None


def resolve(ref, page_path):
    """('local', path) for a URL on the site itself, ('external', host) for another
    host, ('other', scheme) for javascript:, mailto: and the like."""
    ref = (ref or "").strip()
    base = SITE_ORIGIN + page_path
    try:
        parts = urlsplit(urljoin(base, ref))
    except ValueError:
        return ("other", "invalid")
    if parts.scheme not in ("http", "https"):
        return ("other", parts.scheme)
    if f"{parts.scheme}://{parts.netloc}" != SITE_ORIGIN:
        return ("external", (parts.hostname or "").lower())
    return ("local", parts.path)


def page_url(rel):
    """The URL path a file in the output is served at (nginx: /over/ for over/index.html,
    /over for over.html), used to resolve relative form actions the way a browser does."""
    rel = rel.replace(os.sep, "/")
    if rel == "index.html":
        return "/"
    if rel.endswith("/index.html"):
        return "/" + rel[: -len("index.html")]
    if rel.endswith(".html"):
        return "/" + rel[: -len(".html")]
    return "/" + rel


def external_host(ref):
    ref = ref.strip()
    if ref.startswith("//") or re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", ref):
        parts = urlsplit(ref if not ref.startswith("//") else "https:" + ref)
        if parts.scheme in ("http", "https"):
            return (parts.hostname or "").lower()
    return None


def hosting_script(ref):
    """True for a script URL on HOSTING_SCRIPTS: https (or protocol-relative), no port,
    no user info, the exact host, and the exact path where one is given (no query)."""
    ref = ref.strip()
    if ref.startswith("//"):
        ref = "https:" + ref
    try:
        parts = urlsplit(ref)
        port = parts.port
    except ValueError:
        return False
    if parts.scheme != "https" or port is not None or "@" in parts.netloc:
        return False
    host = (parts.hostname or "").lower()
    for allowed_host, path in HOSTING_SCRIPTS:
        if host != allowed_host:
            continue
        if path is None:
            return True
        return parts.path == path and not parts.query and not parts.fragment
    return False


def check_form(rel, page, form, f):
    """One form (audit finding 10). A Notift form is one whose action, or a submit
    button's formaction, resolves to /_notift/forms/... on the site itself, or one that
    clearly means to be one (it posts and the page loads the hosting forms script)."""
    path = page_url(rel)
    targets = [(form["action"], form["method"], "form action")]
    targets += [(act if act is not None else form["action"], meth or form["method"], "formaction")
                for act, meth in form["overrides"]]
    notift = False
    for action, method, what in targets:
        if action is None or not action.strip():
            # Without an action a browser posts to the page itself, a static file. A form that posts,
            # or carries the Notift _redirect field, clearly means to be a Notift form: refuse.
            if method == "post" or "_redirect" in form["fields"]:
                f.refuse("forms", rel, "a form that posts without an action; a Notift form posts to "
                                       "/_notift/forms/<name>, and forms.js only handles that path")
            else:
                f.warn("forms", rel, "a form without an action; it does not reach the Notift form handler")
            continue
        kind, where = resolve(action, path)
        raw = action.strip()
        looks_notift = "_notift/forms" in raw
        if kind == "external":
            f.refuse("forms", rel, f"{what} {raw} sends visitor data off the site; use /_notift/forms/<name>")
            continue
        if kind == "other":
            f.refuse("forms", rel, f"{what} {raw} is not a site path; use /_notift/forms/<name>")
            continue
        if FORM_PATH.match(where):
            notift = True
            if method != "post":
                f.refuse("forms", rel, f'Notift form to {where} has method="{method}"; it must be method="post"')
            continue
        if looks_notift or where.startswith("/_notift/"):
            f.refuse("forms", rel, f"{what} {raw} resolves to {where}: a Notift form posts to /_notift/forms/<name>, "
                                   f"name in lowercase letters, digits and hyphens, at most 40")
            continue
        if method == "get":
            f.warn("forms", rel, f"a GET form to {where}; it stays on the site but is not a Notift form")
            continue
        f.refuse("forms", rel, f"{what} {raw} posts to a static page that cannot receive it; use /_notift/forms/<name>")
    if not notift:
        return
    if not page.forms_scripts:
        f.refuse("forms", rel, f'a Notift form without <script src="{FORMS_SCRIPT}" data-sitekey="..."> on the page; '
                               f"without it the post never reaches the handler")
    elif not any(SITEKEY.match(k or "") for k in page.forms_scripts):
        f.refuse("forms", rel, f"the forms script has no valid data-sitekey; every submission would fail")
    if not form["submit"]:
        f.refuse("forms", rel, 'a Notift form without a control with type="submit"; forms.js only wires that one')


def check_output_tree(tree, f, limits=(MAX_OUTPUT_BYTES, MAX_OUTPUT_FILES)):
    # Server bundle (rule 3) and stray platform files. Links are never followed (audit 2, N1): the
    # transfer to job 2 carries none, so any link here is refused.
    files = []
    for rel, kind in tree.walk(""):
        if kind == "link":
            if tree.link_leaves(rel):
                f.refuse("symlink", rel, "a link to outside the output folder; it would publish files of the build machine")
            else:
                f.refuse("symlink", rel, "a link inside the output; Notift publishes only plain files")
            continue
        files.append(rel)
    for rel in files:
        parts = rel.split("/")
        n = parts[-1]
        for i, d in enumerate(parts[:-1]):
            if d in ("server", "_ssr", "_worker.js", "node_modules") and (
                    d in ("_worker.js", "node_modules") or n.endswith((".mjs", ".js", ".cjs"))):
                f.refuse("server-side", "/".join(parts[:i + 1]) + "/",
                         "a server bundle in the output; publish only the static folder (.output/public)")
                break
        if n in ("nitro.json", "wrangler.json", "wrangler.jsonc", "wrangler.toml", "_worker.js", "_routes.json") \
                or (len(parts) == 1 and n == "index.mjs"):
            f.refuse("server-side", rel, "a server or edge-runtime file in the output; publish only the static folder")
        if len(parts) == 1 and n == "_headers":
            f.warn("server-side", rel, "a Cloudflare _headers file; Notift hosting ignores it")
            check_headers_file(tree, rel, f)

    # Rule size (audit finding 11): the whole output, not only each file.
    max_bytes, max_files = limits
    total = 0
    for rel in files:
        low = rel.lower()
        size = tree.size(rel)
        if size is None:
            continue
        total += size
        if size > MAX_FILE_BYTES:
            f.refuse("media", rel, f"{size / (1024 * 1024):.1f} MB, over the 10 MB limit per file; compress it")
        if low.endswith(".mov"):
            f.warn("media", rel, "a .mov file; not every browser plays it, use a compressed .mp4")
        if low.endswith(".asset.json"):
            f.refuse("lovable-storage", rel, "a Lovable asset pointer in the output")
        if low.endswith(TEXT_EXT) and size <= 4 * MAX_FILE_BYTES:
            status, data = tree.read(rel, 4 * MAX_FILE_BYTES)
            if status != "ok" or not data:
                continue
            if L5E.search(data):
                f.refuse("lovable-storage", rel, "references Lovable storage (/__l5e/), which does not exist on Notift hosting")
            for host in sorted(lovable_hosts(data)):
                rule, what = host_rule(host)
                f.refuse(rule, rel, f"references {host}: {what}")
            for host in sorted({m.group(0).decode("ascii", "ignore").lower() for m in SUPABASE_HOST.finditer(data)}):
                f.refuse("server-side", rel, f"calls Supabase ({host}); nothing server-side runs on Notift hosting")
    if len(files) > max_files:
        f.refuse("size", "", f"{len(files)} files in the output, over the limit of {max_files}; "
                             f"a higher limit is a Notift exception ({ENV_MAX_FILES})")
    if total > max_bytes:
        f.refuse("size", "", f"{total / (1024 * 1024):.1f} MB in the output, over the limit of "
                             f"{max_bytes // (1024 * 1024)} MB; a higher limit is a Notift exception ({ENV_MAX_MB})")

    blocks = None
    if tree.kind("robots.txt") == "file":
        blocks = check_robots(tree, f)

    check_pages(tree, files, f, blocks)


def check_headers_file(tree, rel, f):
    """An X-Robots-Tag noindex in a Cloudflare/Netlify _headers file (audit finding 11).
    nginx does not apply this file, but it states the intent and would apply on the next
    host or a later header mapping, so it is treated like the meta tag."""
    status, data = tree.read(rel, 1024 * 1024)
    data = (data if status == "ok" else b"").decode("utf-8", "replace")
    pattern = None
    for raw in data.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw[:1].isspace():
            pattern = raw.strip()
            continue
        if ":" not in raw:
            continue
        name, value = (x.strip() for x in raw.split(":", 1))
        if name.lower() != "x-robots-tag":
            continue
        # The value may name a crawler first: "googlebot: noindex". Any noindex or none counts.
        if not re.search(r"\b(noindex|none)\b", value.lower()):
            continue
        rx = "^" + "".join(".*" if c == "*" else re.escape(c) for c in re.sub(r":[A-Za-z]\w*", "*", pattern or "")) + "$"
        if pattern and (re.match(rx, "/") or re.match(rx, "/index.html")):
            f.refuse("noindex", "_headers", f"X-Robots-Tag: {value} for {pattern}; the live site must be findable")
        else:
            f.warn("noindex", "_headers", f"X-Robots-Tag: {value} for {pattern}; those paths drop out of search")


def robots_groups(text):
    """RFC 9309 groups: [(agents, [(allow, pattern)])]."""
    groups, agents, rules = [], [], None
    for raw in text.splitlines():
        ln = raw.split("#", 1)[0].strip()
        if ":" not in ln:
            continue
        key, val = (x.strip() for x in ln.split(":", 1))
        key = key.lower()
        if key == "user-agent":
            if rules is not None:
                groups.append((agents, rules))
                agents, rules = [], None
            agents.append(val.lower())
        elif key in ("allow", "disallow") and agents:
            if rules is None:
                rules = []
            if val:
                rules.append((key == "allow", val))
    if agents:
        groups.append((agents, rules or []))
    return groups


def robots_rules_for(groups, crawler):
    """The merged rules of the group that applies to a crawler: its own token, else the
    part before a hyphen (googlebot-news uses googlebot), else '*'."""
    for token in (crawler, crawler.split("-", 1)[0], "*"):
        rules = [r for agents, rs in groups if token in agents for r in rs]
        if rules or any(token in agents for agents, _ in groups):
            return rules
    return []


def robots_allows(rules, path):
    """Longest match wins, allow wins a tie (RFC 9309 section 2.2.2)."""
    best = None
    for allow, pattern in rules:
        rx = "^" + "".join(".*" if c == "*" else re.escape(c) for c in pattern.rstrip("$")) + ("$" if pattern.endswith("$") else "")
        if re.match(rx, path):
            key = (len(pattern), allow)
            if best is None or key > best:
                best = key
    return best is None or best[1]


def check_robots(tree, f):
    """Refuses a robots.txt that keeps a search crawler off the home page, whatever the
    group or pattern (audit finding 11). Returns a function that lists the crawlers kept
    off a given page, for a warning per page."""
    status, data = tree.read("robots.txt", 1024 * 1024)
    text = (data if status == "ok" else b"").decode("utf-8-sig", "replace")
    groups = robots_groups(text)
    rules = {c: robots_rules_for(groups, c) for c in SEARCH_CRAWLERS}
    for crawler in SEARCH_CRAWLERS:
        if not robots_allows(rules[crawler], "/"):
            f.refuse("noindex", "robots.txt", f"keeps {crawler} off the home page; the live site must be findable")
            break
    return lambda url: [c for c in SEARCH_CRAWLERS if not robots_allows(rules[c], url)]


def check_pages(tree, files, f, robots_blocks=None):
    titles, descriptions = {}, {}
    for rel in files:
        if not rel.lower().endswith((".html", ".htm")):
            continue
        status, data = tree.read(rel, 4 * MAX_FILE_BYTES)
        if status != "ok":
            continue
        raw = data.decode("utf-8", "replace")
        p = Page()
        try:
            p.feed(raw)
            p.close()
        except Exception:
            continue  # check_output.py refuses unreadable HTML

        for name in p.fields:
            if name.strip() == HONEYPOT_FIELD:
                f.refuse("forms", rel, f'a field named "{HONEYPOT_FIELD}"; that name is the Notift honeypot and its submissions are dropped')
        for form in p.forms:
            check_form(rel, p, form, f)
        for act, meth in p.loose:
            if act and ("_notift/forms" in act or resolve(act, page_url(rel))[0] != "local"):
                f.refuse("forms", rel, f"a formaction {act.strip()} outside a form; use a form with a /_notift/forms/<name> action")

        for ref in p.scripts:
            host = external_host(ref)
            if host is not None and not hosting_script(ref):
                f.refuse("third-party", rel, f"external script {ref.strip()[:120]}; third-party scripts need an exception from Notift")
        for ref in p.styles:
            host = external_host(ref)
            if host is not None:
                f.warn("third-party", rel, f"external stylesheet from {host}; host fonts and CSS on the site itself")

        technical = rel.rsplit("/", 1)[-1] in TECHNICAL_PAGES
        if p.noindex_by and not technical:
            f.refuse("noindex", rel, f"{p.noindex_by[0]}; the live site must be findable for search engines")
        if robots_blocks and not technical:
            for crawler in robots_blocks(page_url(rel)):
                f.warn("noindex", rel, f"robots.txt keeps {crawler} from this page")
                break
        if technical:
            continue

        lang = (p.lang_seen or "").strip().lower()
        if lang and lang != "nl" and not lang.startswith("nl-"):
            f.warn("page", rel, f'<html lang="{p.lang_seen}">, expected lang="nl"')
        if p.h1 != 1:
            f.warn("page", rel, f"{p.h1} <h1> elements, expected exactly one")
        if not p.canonical:
            f.warn("page", rel, "no canonical link")
        title = " ".join(p.titel.split())
        if title:
            titles.setdefault(title, []).append(rel)
        desc = " ".join(p.omschrijving.split())
        if desc:
            descriptions.setdefault(desc, []).append(rel)

    for what, seen in (("title", titles), ("meta description", descriptions)):
        for value, pages in sorted(seen.items()):
            if len(pages) > 1:
                f.warn("page", ", ".join(sorted(pages)), f'same {what} "{value[:60]}" on {len(pages)} pages')


# ---------------------------------------------------------------------------

def annotate(kind, text):
    """One GitHub error annotation, its data escaped to one inert line (audit 2, finding N7)."""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::{kind} title=Lovable check::{check_output.annotation_data(text)}")


def output_limits(env):
    """The size limits, raised only by Notift through the build layer's environment."""
    out = []
    for name, default, hard, unit in ((ENV_MAX_MB, MAX_OUTPUT_BYTES, HARD_MAX_OUTPUT_BYTES, 1024 * 1024),
                                      (ENV_MAX_FILES, MAX_OUTPUT_FILES, HARD_MAX_OUTPUT_FILES, 1)):
        raw = env.get(name, "")
        if raw == "":
            out.append(default)
            continue
        if not re.fullmatch(r"[1-9][0-9]{0,5}", raw) or int(raw) * unit > hard:
            raise ValueError(f"{name}={raw[:20]} is not a whole number up to {hard // unit}")
        out.append(int(raw) * unit)
    return tuple(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Refuse a Lovable project that breaks Notift's hosting rules.")
    ap.add_argument("--source", help="job 1: the Lovable repository (read only, never through a link)")
    ap.add_argument("--output", required=True, help="the static output folder, normally .output/public")
    ap.add_argument("--output-only", action="store_true",
                    help="job 2: check only the output; the source tree is never opened")
    args = ap.parse_args(argv)

    if args.output_only == (args.source is not None):
        print(line("REFUSE", "usage", "", "give --source <dir> (job 1) or --output-only (job 2), exactly one"),
              file=sys.stderr)
        return 2
    if args.source is not None and not os.path.isdir(args.source):
        print(check_output.safe_line(line("REFUSE", "usage", args.source, "source folder does not exist")), file=sys.stderr)
        return 2
    if not os.path.isdir(args.output):
        print(check_output.safe_line(line("REFUSE", "prerender", args.output,
                                          "output folder does not exist; the build produced no static site")),
              file=sys.stderr)
        return 1

    try:
        limits = output_limits(os.environ)
    except ValueError as e:
        print(check_output.safe_line(line("REFUSE", "usage", "", str(e))), file=sys.stderr)
        return 2

    f = Findings()
    output = Tree(args.output)
    required = None
    if args.source is not None:
        source = Tree(args.source)
        pages = check_vite_config(source, f)
        check_source(source, f)
        required = check_routes(source, output, f, pages)
    check_output_tree(output, f, limits)

    # Every finding is one escaped line on stderr, at most MAX_PRINTED of them, and at most
    # MAX_ANNOTATIONS error annotations (audit 2, finding N7).
    seen, printed, annotated = set(), 0, 0
    for kind, items in (("WARN", f.warnings), ("REFUSE", f.refusals)):
        for rule, where, what in items:
            raw = line(kind, rule, where, what)
            msg = check_output.safe_line(raw)
            if msg in seen:
                continue
            seen.add(msg)
            if printed < MAX_PRINTED:
                print(msg, file=sys.stderr)
                printed += 1
            if kind == "REFUSE" and annotated < MAX_ANNOTATIONS:
                annotate("error", raw)
                annotated += 1
    if len(seen) > printed:
        print(f"check_lovable: {len(seen) - printed} more finding(s) not shown", file=sys.stderr)
    refusals = len({check_output.safe_line(line("REFUSE", *x)) for x in f.refusals})
    warnings = len({check_output.safe_line(line("WARN", *x)) for x in f.warnings})
    mode = "output only, " if required is None else ""
    if refusals:
        print(f"check_lovable: refused, {mode}{refusals} refusal(s), {warnings} warning(s)", file=sys.stderr)
        return 1
    found = "" if required is None else f", {required} required route(s) found"
    print(f"check_lovable: ok, {mode}{warnings} warning(s){found}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
