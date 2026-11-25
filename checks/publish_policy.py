#!/usr/bin/env python3
"""When a run may build and publish, and with which publication fields. Both jobs of build-and-publish.yml.

Usage:
    publish_policy.py gate    <repo-dir> <manifest-path>   job 1: go=true or go=false, before any client code
    publish_policy.py publish <repo-dir> <manifest-path>   job 2: the publication fields, or a refusal

Environment (set by the workflow from GitHub's own context, never from job 1):
    EVENT        github.event_name
    REF          github.ref
    POLICY       the caller's input 'policy': empty, or 'lovable-on-request'
  publish only:
    COMMIT       github.sha
    RUN_ID       github.run_id
    RUN_ATTEMPT  github.run_attempt
    NOTIFT_BUILD_TIME   optional, YYYYmmdd-HHMM, for the proofs; otherwise the current UTC minute

The rules, the same in both jobs:
  1. Only refs/heads/main publishes.
  2. Only push and workflow_dispatch publish.
  3. POLICY 'lovable-on-request' is Notift policy, set in the protected caller workflow: the manifest
     must say profile lovable, and only workflow_dispatch builds, whatever build.trigger says.
  4. Without a policy the manifest decides (existing sites, DWY variant A): build.trigger manual means
     only workflow_dispatch builds.
In job 1 a run that may not publish under rule 1, 2 or 4 becomes go=false (a green run that builds nothing).
A wrong policy (rule 3 broken, or an unknown POLICY) is an error in both jobs. In job 2 every rule is
an error: job 2 only runs when job 1 said go, so reaching job 2 against the rules means job 1 lied.

publish prints, as key=value lines for GITHUB_OUTPUT, fields that job 2 read itself from the manifest it
fetched on its own (only that blob, at the exact commit) with the validator of check_output.py: organisation, project, module, plan, package (always
ghcr.io/notift/<module>), profile, build (UTC date plus short commit) and tag (build plus run and
attempt, so two runs never write the same tag). Nothing here comes from job 1.

Exit 0 = ok, 1 = refused (reason on stderr), 2 = usage. Standard library only; run with python3 -I.
"""

import datetime
import os
import re
import stat
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_output  # noqa: E402  (next to this script, in the trusted build layer checkout)

MAIN_REF = "refs/heads/main"
PUBLISH_EVENTS = ("push", "workflow_dispatch")
POLICIES = ("", "lovable-on-request")
MANIFEST_PATH = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*(?:/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\.json$")


class Refused(Exception):
    pass


def manifest_file(repo, rel):
    """The manifest inside the checkout: a plain relative path, no link anywhere on the way."""
    if not MANIFEST_PATH.fullmatch(rel or "") or any(p in (".", "..") for p in rel.split("/")):
        raise Refused(f"het manifestpad is geen gewoon relatief .json-pad: {rel!r}")
    current = os.path.realpath(repo)
    for part in rel.split("/"):
        current = os.path.join(current, part)
        try:
            st = os.lstat(current)
        except FileNotFoundError:
            raise Refused(f"{rel} ontbreekt in deze repo. Zie de README van de bouwlaag.")
        if stat.S_ISLNK(st.st_mode):
            raise Refused(f"het manifest loopt via een verwijzing: {rel}")
    if not stat.S_ISREG(st.st_mode):
        raise Refused(f"het manifest is geen gewoon bestand: {rel}")
    return current


def read_manifest(repo, rel):
    path = manifest_file(repo, rel)
    try:
        return check_output.lees_manifest(path)
    except SystemExit as e:  # the validator reports with sys.exit(<reason>)
        raise Refused(str(e.code))
    except (ValueError, OSError) as e:
        raise Refused(f"het manifest is niet leesbaar: {e}")


def decide(manifest, env):
    """Returns (go, reason). Raises Refused for a policy error that must turn the run red."""
    policy = env.get("POLICY", "")
    event = env.get("EVENT", "")
    ref = env.get("REF", "")
    if policy not in POLICIES:
        raise Refused(f"onbekend beleid in de aanroeper: {policy!r}")
    profile = manifest["build"]["profile"]
    trigger = manifest["build"]["trigger"]
    if policy == "lovable-on-request":
        if profile != "lovable":
            raise Refused(f"het beleid van deze repo is lovable-on-request, maar het manifest zegt profiel {profile}")
        trigger = "manual"
    if ref != MAIN_REF:
        return False, f"alleen {MAIN_REF} publiceert, deze run is {ref or 'zonder ref'}"
    if event not in PUBLISH_EVENTS:
        return False, f"alleen push en workflow_dispatch publiceren, deze run is {event or 'zonder event'}"
    if trigger == "manual" and event != "workflow_dispatch":
        return False, f"dit project bouwt alleen op verzoek; {event} bouwt niets"
    return True, ""


def gate(repo, rel, env):
    m = read_manifest(repo, rel)
    go, reason = decide(m, env)
    if not go:
        print(f"::notice title=Niet gebouwd::{check_output.annotation_data(reason)}", file=sys.stderr)
        summary = env.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as f:
                f.write(f"### Niet gebouwd\n\n{check_output.safe_line(reason)}. Er is niets gepubliceerd.\n")
    print(f"go={'true' if go else 'false'}")


def publish(repo, rel, env):
    m = read_manifest(repo, rel)
    go, reason = decide(m, env)
    if not go:
        raise Refused(f"job 2 publiceert niet: {reason}")
    commit = env.get("COMMIT", "")
    run_id = env.get("RUN_ID", "")
    attempt = env.get("RUN_ATTEMPT", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise Refused(f"geen volledige commit van GitHub: {commit!r}")
    if not re.fullmatch(r"[1-9][0-9]{0,19}", run_id) or not re.fullmatch(r"[1-9][0-9]{0,4}", attempt):
        raise Refused("geen geldige run of poging van GitHub")
    moment = env.get("NOTIFT_BUILD_TIME") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M")
    if not re.fullmatch(r"[0-9]{8}-[0-9]{4}", moment):
        raise Refused(f"ongeldige bouwtijd: {moment!r}")
    build = f"{moment}-{commit[:7]}"
    tag = f"{build}-{run_id}-{attempt}"
    package = m["package"].lower()
    if package != f"ghcr.io/notift/{m['module']}":  # check_output already demands this; bind it here too
        raise Refused(f"pakket {package} hoort niet bij module {m['module']}")
    fields = {
        "organisation": m["organisation"], "project": m["project"], "module": m["module"],
        "plan": m["plan"], "package": package, "profile": m["build"]["profile"],
        "build": build, "tag": tag,
    }
    for name, value in fields.items():
        # One line each, and safe in a build-arg line and a Docker tag.
        if not re.fullmatch(r"[A-Za-z0-9._/:-]{1,128}", value):
            raise Refused(f"publicatieveld {name} heeft een ongeldige vorm")
        print(f"{name}={value}")


def main(argv):
    if len(argv) != 4 or argv[1] not in ("gate", "publish"):
        print("Gebruik: publish_policy.py gate|publish <repo-dir> <manifest-path>", file=sys.stderr)
        return 2
    try:
        (gate if argv[1] == "gate" else publish)(argv[2], argv[3], os.environ)
    except Refused as e:
        # The reason can carry client text (manifest keys and values, JSON errors): one inert line (N7).
        print(f"::error title=Publicatiebeleid::{check_output.annotation_data(e)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
