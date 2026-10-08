#!/usr/bin/env python3
"""Publicatiebericht: geen geheim in argv, stdout of foutdetails."""
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request


def publication(environ):
    event = "github-" + environ["RUN_ID"] + "-" + environ["RUN_ATTEMPT"]
    body = json.dumps({
        "schema": 1, "event_id": event,
        "repository": environ["REPOSITORY"].lower(), "ref": environ["REF"],
        "commit": environ["COMMIT"], "module": environ["MODULE"],
        "project": environ["PROJECT"], "package": environ["PACKAGE"],
        "build": environ["BUILD"], "image": environ["IMAGE"],
        "workflow_sha": environ["WORKFLOW"],
        "run_id": environ["RUN_ID"], "run_attempt": environ["RUN_ATTEMPT"],
    }, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    timestamp = str(int(time.time()))
    signature = hmac.new(environ["NOTIFT_DEPLOY_SECRET"].encode(),
                         timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()
    return body, {"Content-Type": "application/json", "X-Notift-Event-Id": event,
                  "X-Notift-Timestamp": timestamp, "X-Notift-Signature": "sha256=" + signature}


def main():
    if not os.environ.get("NOTIFT_DEPLOY_SECRET"):
        print("::warning::NOTIFT_DEPLOY_SECRET ontbreekt, publicatie blijft beschikbaar zonder stagingmelding")
        return 0
    if os.environ["REF"] != "refs/heads/main":
        print("Geen stagingmelding voor deze branch")
        return 0
    body, headers = publication(os.environ)
    request = urllib.request.Request("https://app.notift.nl/api/deployments",
                                     data=body, headers=headers, method="POST")
    # Geen redirects: de HMAC-headers mogen nooit naar een andere host gaan.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            if response.status != 202:
                print("::error::deployment-not-accepted", file=sys.stderr)
                return 1
    except (urllib.error.URLError, TimeoutError):
        print("::error::deployment-not-accepted", file=sys.stderr)
        return 1
    print("Stagingmelding geaccepteerd (202)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
