#!/usr/bin/env python3
"""The transfer of a built site from job 1 to job 2 of build-and-publish.yml, and the Docker context.

Usage:
    transfer.py pack <stage-dir> <tar-file>            job 1: the staged output as one plain tar
    transfer.py unpack <download-dir> <dest-dir>        job 2: bounded unpack of <download-dir>/site.tar
    transfer.py assemble <checked-tree> <context-dir>   job 2: <context-dir>/site from checked files only
    transfer.py verify-context <context-dir>            job 2: the context holds exactly what we put there

Job 1 runs client code, so job 2 treats the artifact as hostile bytes. The artifact is one uncompressed
tar, uploaded without the zip of upload-artifact and downloaded without its unzip, so only this script
unpacks it. Unpacking refuses, before a byte is written: symlinks, hardlinks, devices, fifos, sparse
files and anything that is not a plain file or directory; absolute paths, '..', '.', empty segments,
backslashes and control characters; duplicate paths; more than MAX_FILES files, a file over
MAX_FILE_BYTES, or more than MAX_TOTAL_BYTES in total. Files are written with O_EXCL and O_NOFOLLOW
into directories this script created, mode 0644, so nothing pre-existing or linked is ever written to.

Hidden paths. Only .well-known/ travels (RFC 8615: security.txt, app links, ACME). Job 1 leaves any
other path with a segment starting with a dot out of the stage, as upload-artifact did before; job 2
refuses one if it arrives anyway, because then job 1 was tampered with.

Every message that can carry text from the artifact (names, paths, OSError details) goes through the one
single-line formatter of check_output.py (audit 3b, N7): '::' and '##[' are broken wherever they appear,
control and ignorable characters are escaped, and the line is cut to a fixed length. Job 2 runs this script
before any other check, so a planted name can never become a workflow command in its log.

Exit 0 = done, 1 = refused (reason on stderr), 2 = usage.
Standard library only: this runs on a bare runner. Run it with python3 -I.
"""

import gzip
import os
import stat
import sys
import tarfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_output  # noqa: E402  (next to this script, in the trusted build layer checkout)

TAR_NAME = "site.tar"


def _limit(name, default):
    """A limit, which the environment can only make stricter (the proofs use that). Never looser."""
    try:
        value = int(os.environ.get("NOTIFT_TRANSFER_" + name, default))
    except ValueError:
        return default
    return max(1, min(value, default))


MAX_FILES = _limit("MAX_FILES", 10_000)
MAX_DIRS = _limit("MAX_DIRS", 5_000)
MAX_FILE_BYTES = _limit("MAX_FILE_BYTES", 100 * 1024 * 1024)
MAX_TOTAL_BYTES = _limit("MAX_TOTAL_BYTES", 512 * 1024 * 1024)
MAX_PATH_BYTES = 400
MAX_DEPTH = 32
# A tar spends at most a few blocks of headers per entry; anything bigger is not our pack.
MAX_TAR_BYTES = MAX_TOTAL_BYTES + (MAX_FILES + MAX_DIRS) * 4096 + 1024 * 1024
CHUNK = 1024 * 1024

# Paths in the output that belong to Notift, never to the client. Dropped when the context is assembled;
# job 2 writes its own (_notift/embed/forms.js, _health) afterwards.
RESERVED_TOP = {"_notift"}
RESERVED_FILES = {"_health"}
HIDDEN_ALLOWED_TOP = ".well-known"

O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_BINARY = getattr(os, "O_BINARY", 0)


class Refused(Exception):
    pass


def refuse(reason):
    raise Refused(reason)


def notice(text):
    print(f"::notice title=Overdracht::{check_output.annotation_data(text)}", file=sys.stderr)


def warn(text):
    print(f"::warning title=Overdracht::{check_output.annotation_data(text)}", file=sys.stderr)


def error(text):
    print(f"::error title=Overdracht::{check_output.annotation_data(text)}", file=sys.stderr)


def say(text):
    """A progress line on stdout, through the same formatter: it can hold a name from the artifact."""
    print(check_output.safe_line(text))


def check_name(rel):
    """A relative path in the site: plain segments only. Returns the list of segments."""
    if not isinstance(rel, str) or not rel:
        refuse("een leeg pad")
    if len(rel.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES:
        refuse(f"een pad langer dan {MAX_PATH_BYTES} bytes: {rel[:80]!r}")
    if rel.startswith("/") or "\\" in rel:
        refuse(f"een absoluut pad of een backslash: {rel!r}")
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in rel):
        refuse(f"een stuurteken in een pad: {rel!r}")
    parts = rel.split("/")
    if any(p in ("", ".", "..") for p in parts):
        refuse(f"een pad met een leeg, '.' of '..' deel: {rel!r}")
    if len(parts) > MAX_DEPTH:
        refuse(f"een pad dieper dan {MAX_DEPTH}: {rel!r}")
    return parts


def is_hidden(parts):
    """True when the path is hidden and not under .well-known/ (which travels)."""
    for i, p in enumerate(parts):
        if p.startswith("."):
            if i == 0 and p == HIDDEN_ALLOWED_TOP:
                continue
            return True
    return False


def open_regular(path):
    """Opens a plain file without following a link, and checks it is one file with one name."""
    # O_NONBLOCK: opening a fifo must not hang; the fstat below refuses it.
    fd = os.open(path, os.O_RDONLY | O_NOFOLLOW | O_BINARY | getattr(os, "O_NONBLOCK", 0))
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        os.close(fd)
        refuse(f"geen gewoon bestand: {path}")
    if st.st_nlink != 1:
        os.close(fd)
        refuse(f"een bestand met meer dan een naam (hardlink): {path}")
    return fd, st


def create_file(path):
    return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_BINARY, 0o644)


def walk_plain(root):
    """Yields (rel, full, is_dir) for everything under root; refuses links and special files."""
    root_st = os.lstat(root)
    if not stat.S_ISDIR(root_st.st_mode):
        refuse(f"de wortel is geen gewone map: {root}")
    stack = [""]
    while stack:
        rel_dir = stack.pop()
        full_dir = os.path.join(root, rel_dir) if rel_dir else root
        for name in sorted(os.listdir(full_dir)):
            rel = f"{rel_dir}/{name}" if rel_dir else name
            full = os.path.join(full_dir, name)
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                refuse(f"een verwijzing (symlink): {rel}")
            if stat.S_ISDIR(st.st_mode):
                yield rel, full, True
                stack.append(rel)
            elif stat.S_ISREG(st.st_mode):
                if st.st_nlink != 1:
                    refuse(f"een bestand met meer dan een naam (hardlink): {rel}")
                yield rel, full, False
            else:
                refuse(f"een bestand dat geen gewoon bestand is: {rel}")


class Budget:
    def __init__(self):
        self.files = 0
        self.dirs = 0
        self.bytes = 0

    def add_dir(self, rel):
        self.dirs += 1
        if self.dirs > MAX_DIRS:
            refuse(f"meer dan {MAX_DIRS} mappen")

    def add_file(self, rel, size):
        self.files += 1
        if self.files > MAX_FILES:
            refuse(f"meer dan {MAX_FILES} bestanden")
        if size > MAX_FILE_BYTES:
            refuse(f"een bestand boven {MAX_FILE_BYTES} bytes: {rel}")
        self.bytes += size
        if self.bytes > MAX_TOTAL_BYTES:
            refuse(f"samen meer dan {MAX_TOTAL_BYTES} bytes")


def copy_fd(src_fd, dst_fd, expected):
    done = 0
    while True:
        block = os.read(src_fd, CHUNK)
        if not block:
            break
        done += len(block)
        if done > expected:
            refuse("een bestand groeide tijdens het kopieren")
        view = memoryview(block)
        while view:
            n = os.write(dst_fd, view)
            view = view[n:]
    if done != expected:
        refuse("een bestand veranderde van grootte tijdens het kopieren")


# ---------------------------------------------------------------------------------------------------------


def pack(stage, tar_path):
    if os.path.lexists(tar_path):
        refuse(f"het pakket bestaat al: {tar_path}")
    budget = Budget()
    entries = []
    for rel, full, is_dir in walk_plain(stage):
        parts = check_name(rel)
        if is_hidden(parts):
            refuse(f"een verborgen pad in de klaarzetmap: {rel}")
        if is_dir:
            budget.add_dir(rel)
        entries.append((rel, full, is_dir))
    if not any(not d for _, _, d in entries):
        refuse("de klaarzetmap is leeg")
    fd = create_file(tar_path)
    with os.fdopen(fd, "wb") as raw, tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for rel, full, is_dir in sorted(entries):
            if is_dir:
                info = tarfile.TarInfo(rel)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.mtime = int(os.lstat(full).st_mtime)
                tf.addfile(info)
                continue
            src, st = open_regular(full)
            try:
                budget.add_file(rel, st.st_size)
                info = tarfile.TarInfo(rel)
                info.type = tarfile.REGTYPE
                info.mode = 0o644
                info.size = st.st_size
                info.mtime = int(st.st_mtime)
                with os.fdopen(src, "rb", closefd=False) as f:
                    tf.addfile(info, f)
            finally:
                os.close(src)
    say(f"{budget.files} bestanden, {budget.bytes} bytes ingepakt in {os.path.basename(tar_path)}")


def unpack(download_dir, dest):
    st = os.lstat(download_dir)
    if not stat.S_ISDIR(st.st_mode):
        refuse(f"de downloadmap is geen gewone map: {download_dir}")
    names = sorted(os.listdir(download_dir))
    if names != [TAR_NAME]:
        refuse(f"de downloadmap moet precies {TAR_NAME} bevatten, niet: {', '.join(names) or 'niets'}")
    tar_path = os.path.join(download_dir, TAR_NAME)
    if os.path.lexists(dest):
        refuse(f"de uitpakmap bestaat al: {dest}")
    src, tst = open_regular(tar_path)
    if tst.st_size > MAX_TAR_BYTES:
        os.close(src)
        refuse(f"het pakket is {tst.st_size} bytes, meer dan {MAX_TAR_BYTES}")
    os.mkdir(dest, 0o755)
    made_dirs = {""}
    seen = set()
    budget = Budget()
    with os.fdopen(src, "rb") as raw:
        try:
            tf = tarfile.open(fileobj=raw, mode="r:")  # plain tar only: no decompression to bound
        except tarfile.TarError as e:
            refuse(f"geen leesbaar tar-pakket: {e}")
        with tf:
            while True:
                try:
                    m = tf.next()
                except tarfile.TarError as e:
                    refuse(f"een kapotte kop in het pakket: {e}")
                if m is None:
                    break
                rel = m.name[:-1] if m.name.endswith("/") and m.isdir() else m.name
                parts = check_name(rel)
                if rel in seen:
                    refuse(f"een pad dat twee keer voorkomt: {rel}")
                seen.add(rel)
                if is_hidden(parts):
                    refuse(f"een verborgen pad, alleen .well-known/ mag mee: {rel}")
                if m.issym() or m.islnk():
                    refuse(f"een verwijzing in het pakket: {rel}")
                if m.issparse() or not (m.isreg() or m.isdir()) or m.type not in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE):
                    refuse(f"iets anders dan een gewoon bestand of een map: {rel}")
                parent = "/".join(parts[:-1])
                for i in range(1, len(parts)):
                    d = "/".join(parts[:i])
                    if d in made_dirs:
                        continue
                    if d in seen and d not in made_dirs:
                        refuse(f"een bestand en een map met dezelfde naam: {d}")
                    budget.add_dir(d)
                    os.mkdir(os.path.join(dest, *parts[:i]), 0o755)
                    made_dirs.add(d)
                target = os.path.join(dest, *parts)
                if m.isdir():
                    if rel not in made_dirs:
                        budget.add_dir(rel)
                        os.mkdir(target, 0o755)
                        made_dirs.add(rel)
                    continue
                if parent not in made_dirs:
                    refuse(f"een bestand onder iets dat geen map is: {rel}")
                if rel in made_dirs:
                    refuse(f"een bestand en een map met dezelfde naam: {rel}")
                budget.add_file(rel, m.size)
                data = tf.extractfile(m)
                out = create_file(target)
                try:
                    written = 0
                    while True:
                        block = data.read(CHUNK)
                        if not block:
                            break
                        written += len(block)
                        if written > m.size:
                            refuse(f"meer bytes dan de kop zegt: {rel}")
                        os.write(out, block)
                    if written != m.size:
                        refuse(f"minder bytes dan de kop zegt: {rel}")
                finally:
                    os.close(out)
    if budget.files == 0:
        refuse("het pakket bevat geen bestanden")
    # Defence in depth: the tree on disk is what the headers said, and nothing else.
    for rel, _, is_dir in walk_plain(dest):
        if not is_dir and rel not in seen:
            refuse(f"een onverwacht bestand na het uitpakken: {rel}")
    say(f"{budget.files} bestanden, {budget.bytes} bytes uitgepakt")


def assemble(tree, context):
    if os.path.lexists(context):
        refuse(f"de bouwcontext bestaat al: {context}")
    entries = list(walk_plain(tree))
    os.mkdir(context, 0o755)
    site = os.path.join(context, "site")
    os.mkdir(site, 0o755)
    budget = Budget()
    dropped_gz, dropped_reserved = [], []
    for rel, full, is_dir in entries:
        parts = check_name(rel)
        if is_hidden(parts):
            refuse(f"een verborgen pad, alleen .well-known/ mag mee: {rel}")
        if parts[0] in RESERVED_TOP or (len(parts) == 1 and parts[0] in RESERVED_FILES):
            dropped_reserved.append(rel)
            continue
        if not is_dir and parts[-1].lower().endswith(".gz"):
            # Every .gz that nginx serves (gzip_static) is made by job 2, from the checked file.
            dropped_gz.append(rel)
            continue
        target = os.path.join(site, *parts)
        if is_dir:
            budget.add_dir(rel)
            os.mkdir(target, 0o755)
            continue
        src, st = open_regular(full)
        try:
            budget.add_file(rel, st.st_size)
            out = create_file(target)
            try:
                copy_fd(src, out, st.st_size)
            finally:
                os.close(out)
        finally:
            os.close(src)
    if dropped_gz:
        warn(f"{len(dropped_gz)} .gz-bestand(en) van de build weggelaten; de bouwlaag comprimeert zelf: "
             + ", ".join(dropped_gz[:10]) + (" ..." if len(dropped_gz) > 10 else ""))
    if dropped_reserved:
        notice("gereserveerd voor Notift en weggelaten: " + ", ".join(sorted(dropped_reserved)[:10]))
    if budget.files == 0:
        refuse("er blijft niets over om te publiceren")
    say(f"bouwcontext: {budget.files} bestanden, {budget.bytes} bytes")


def verify_context(context):
    names = sorted(os.listdir(context))
    if names != ["Dockerfile", "redirects.map", "site"]:
        refuse(f"de bouwcontext bevat iets anders dan Dockerfile, redirects.map en site/: {', '.join(names)}")
    for name in ("Dockerfile", "redirects.map"):
        fd, _ = open_regular(os.path.join(context, name))
        os.close(fd)
    site = os.path.join(context, "site")
    files = set()
    for rel, _, is_dir in walk_plain(site):
        parts = check_name(rel)
        if is_hidden(parts):
            refuse(f"een verborgen pad in de bouwcontext: {rel}")
        if not is_dir:
            files.add(rel)
    if "_health" not in files:
        refuse("site/_health ontbreekt")
    for rel in sorted(f for f in files if f.endswith(".gz")):
        plain = rel[:-3]
        if plain not in files:
            refuse(f"een .gz zonder het bestand ernaast: {rel}")
        with open(os.path.join(site, *plain.split("/")), "rb") as f:
            want = f.read()
        with gzip.open(os.path.join(site, *rel.split("/")), "rb") as g:
            got = g.read(len(want) + 1)
        if got != want:
            refuse(f"een .gz die niet de gecomprimeerde vorm van zijn buur is: {rel}")
    say(f"bouwcontext nagekeken: {len(files)} bestanden in site/, plus Dockerfile en redirects.map")


COMMANDS = {"pack": pack, "unpack": unpack, "assemble": assemble, "verify-context": verify_context}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    func = COMMANDS[argv[1]]
    want = 1 if argv[1] == "verify-context" else 2
    if len(argv) != 2 + want:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        func(*argv[2:])
    except Refused as e:
        error(e)
        return 1
    except OSError as e:
        error(f"{e.strerror}: {e.filename}")
        return 1
    except Exception as e:  # noqa: BLE001  (no traceback with an artifact name in it reaches the log raw)
        error(f"onverwachte fout ({type(e).__name__}): {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
