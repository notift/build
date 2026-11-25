#!/usr/bin/env python3
"""Copies exactly build.output into a fresh staging folder. Job 1 of build-and-publish.yml.

Usage:
    stage_output.py <repo-dir> <build.output> <stage-dir>

Only what is inside build.output can reach job 2, and so the image. The artifact is uploaded from the
staging folder, never from the repo: a sibling such as .output/server (the server bundle of a TanStack
Start project) is not under build.output and is never read.

Refused, with exit code 1 and the reason on stderr:
  - an output path that leaves the repo, is the repo itself, or passes through a symlink or .git;
  - an output that is missing or is not a directory;
  - a symlink that points outside the output folder, a directory symlink, or a special file;
  - a file with more than one name (a hardlink): its content could be the server bundle under another name.
A file symlink that stays inside the output is copied as a regular file with the target's content.
Files are read through O_NOFOLLOW and checked on the open descriptor, so a swap between check and read
cannot point the copy elsewhere.

Hidden paths: only .well-known/ is staged. Any other path with a segment that starts with a dot
(.DS_Store, .vite/, .env) stays behind, with a notice, as upload-artifact did before this script. Job 2
refuses such a path if it arrives anyway (transfer.py).

This is job 1, on the same runner as the client's code: it keeps an honest build honest. The boundary
is job 2, which unpacks and checks everything again (transfer.py, check_output.py, check_lovable.py).

Standard library only: this runs on a bare runner.
"""

import os
import stat
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import transfer  # noqa: E402  (next to this script: the same name and hidden-path rules as job 2)


def fail(reason):
    print(f"::error title=Uitvoer klaarzetten::{reason}", file=sys.stderr)
    sys.exit(1)


def resolve_output(repo, output):
    repo_real = os.path.realpath(repo)
    parts = output.split("/")
    if any(p in ("", ".", "..", ".git") for p in parts) or os.path.isabs(output):
        fail(f"build.output moet een gewone relatieve map zijn: {output}")
    current = repo_real
    for part in parts:
        current = os.path.join(current, part)
        if os.path.islink(current):
            fail(f"build.output loopt via een verwijzing: {os.path.relpath(current, repo_real)}")
    if not os.path.exists(current):
        fail(f"de build leverde geen map {output} op")
    if not os.path.isdir(current):
        fail(f"{output} is geen map")
    real = os.path.realpath(current)
    if real == repo_real or not real.startswith(repo_real + os.sep):
        fail(f"{output} ligt niet binnen de repo")
    return real


def copy_tree(src_root, dst_root):
    count = 0
    hidden = []
    for dirpath, dirnames, filenames in os.walk(src_root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, src_root)
        target_dir = dst_root if rel_dir == "." else os.path.join(dst_root, rel_dir)
        if rel_dir != ".":
            os.mkdir(target_dir, 0o755)
        for name in list(dirnames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, src_root)
            if os.path.islink(path):
                fail(f"een mapverwijzing in de uitvoer: {rel}")
            if transfer.is_hidden(rel.split("/")):
                hidden.append(rel + "/")
                dirnames.remove(name)
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, src_root)
            if transfer.is_hidden(rel.split("/")):
                hidden.append(rel)
                continue
            try:
                transfer.check_name(rel)
            except transfer.Refused as e:
                fail(str(e))
            source = path
            if os.path.islink(path):
                target = os.path.realpath(path)
                if not target.startswith(src_root + os.sep):
                    fail(f"een verwijzing die uit de uitvoermap wijst: {rel}")
                if not os.path.exists(target):
                    fail(f"een verwijzing naar niets: {rel}")
                source = target
            if not stat.S_ISREG(os.lstat(source).st_mode):
                fail(f"een bestand dat geen gewoon bestand is: {rel}")
            try:
                fd, st = transfer.open_regular(source)
            except (OSError, transfer.Refused) as e:
                fail(f"{e}: {rel}" if isinstance(e, transfer.Refused) else f"een bestand dat geen gewoon bestand is: {rel}")
            try:
                out = transfer.create_file(os.path.join(target_dir, name))
                try:
                    transfer.copy_fd(fd, out, st.st_size)
                except transfer.Refused as e:
                    fail(f"{e}: {rel}")
                finally:
                    os.close(out)
            finally:
                os.close(fd)
            count += 1
    if hidden:
        print(f"::notice title=Uitvoer klaarzetten::{len(hidden)} verborgen pad(en) niet meegenomen "
              f"(alleen .well-known/ gaat mee): {', '.join(sorted(hidden)[:10])}", file=sys.stderr)
    return count


def main():
    if len(sys.argv) != 4:
        sys.exit("Gebruik: stage_output.py <repo-dir> <build.output> <stage-dir>")
    repo, output, stage = sys.argv[1], sys.argv[2], sys.argv[3]
    src = resolve_output(repo, output)
    if os.path.lexists(stage):
        fail(f"de klaarzetmap bestaat al: {stage}")
    os.makedirs(stage, mode=0o755)
    stage_real = os.path.realpath(stage)
    if stage_real == src or stage_real.startswith(src + os.sep) or src.startswith(stage_real + os.sep):
        fail("de klaarzetmap en de uitvoermap overlappen")
    count = copy_tree(src, stage_real)
    if count == 0:
        fail(f"{output} is leeg")
    print(f"{count} bestanden uit {output} klaargezet")
    return 0


if __name__ == "__main__":
    sys.exit(main())
