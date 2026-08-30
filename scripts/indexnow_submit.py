#!/usr/bin/env python3
"""Submit the site's URLs to IndexNow (Bing, DuckDuckGo, Brave, Yandex, Seznam…).

Why this exists: Google Search Console rations manual indexing to 11 URLs per
property per day, and its sitemap fetch for this property has failed repeatedly.
IndexNow is a separate path with a far higher ceiling, and it feeds the engines
that already send traffic to the repo. One submission reaches every participating
engine — api.indexnow.org forwards to all of them.

Ownership is proved by a key file hosted under the path being submitted. Per the
spec, a key at `https://host/agent-sessions/<key>.txt` authorizes exactly the URLs
starting `https://host/agent-sessions/` — which is what makes this work at all on
a github.io subpath, where we cannot put anything at the host root.

Usage:
    scripts/indexnow_submit.py              # submit every URL in the live sitemap
    scripts/indexnow_submit.py --dry-run    # print the payload, send nothing
    scripts/indexnow_submit.py <url> ...    # submit specific URLs
"""

import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(REPO_ROOT, "docs")

HOST = "jazzyalex.github.io"
BASE = "https://jazzyalex.github.io/agent-sessions/"
SITEMAP = BASE + "sitemap.xml"
ENDPOINT = "https://api.indexnow.org/indexnow"

# What each status means, from the IndexNow spec.
STATUS = {
    200: "OK — URLs submitted successfully",
    202: "Accepted — URLs received, key validation pending",
    400: "Bad request — invalid format",
    403: "Forbidden — key not found, or file found but key not in it",
    422: "Unprocessable — URLs don't belong to the host, or key schema mismatch",
    429: "Too many requests — throttled as potential spam",
}


def die(message):
    print("ERROR: " + message, file=sys.stderr)
    raise SystemExit(1)


def find_key():
    """The key file is the bare-hex .txt at the docs root, named for its own contents."""
    candidates = []
    for path in glob.glob(os.path.join(DOCS, "*.txt")):
        name = os.path.basename(path)[:-4]
        if not re.fullmatch(r"[A-Za-z0-9-]{8,128}", name):
            continue
        with open(path, encoding="utf-8") as handle:
            body = handle.read().strip()
        if body == name:
            candidates.append(name)
    if not candidates:
        die(
            "no IndexNow key file in docs/. Expected a <key>.txt whose contents are "
            "exactly <key>, 8-128 chars of [A-Za-z0-9-]."
        )
    if len(candidates) > 1:
        die("multiple IndexNow key files in docs/: %s. Keep one." % ", ".join(candidates))
    return candidates[0]


def fetch(url, timeout=30):
    request = urllib.request.Request(url, headers={"User-Agent": "agent-sessions-indexnow"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, response.read().decode("utf-8", "replace")


def sitemap_urls():
    status, body = fetch(SITEMAP)
    if status != 200:
        die("sitemap returned HTTP %d" % status)
    urls = re.findall(r"<loc>(.*?)</loc>", body)
    if not urls:
        die("no <loc> entries in the sitemap")
    return urls


def main():
    argv = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry_run = "--dry-run" in sys.argv[1:]

    key = find_key()
    key_location = BASE + key + ".txt"

    # The key file must be live before submitting, or every engine answers 403.
    try:
        status, body = fetch(key_location)
    except urllib.error.HTTPError as error:
        die("key file %s is not reachable (HTTP %d). Push and wait for Pages to deploy."
            % (key_location, error.code))
    if status != 200 or body.strip() != key:
        die("key file %s served HTTP %d with body %r; expected the key %r"
            % (key_location, status, body[:80], key))

    urls = argv or sitemap_urls()
    outside = [u for u in urls if not u.startswith(BASE)]
    if outside:
        die("these URLs are outside the key's authorized prefix %s: %s"
            % (BASE, ", ".join(outside)))

    payload = {"host": HOST, "key": key, "keyLocation": key_location, "urlList": urls}

    print("endpoint     %s" % ENDPOINT)
    print("key file     %s (verified live)" % key_location)
    print("urls         %d" % len(urls))
    for u in urls:
        print("             " + u)
    if dry_run:
        print("\n--dry-run: nothing sent")
        return

    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        ENDPOINT, data=body,
        headers={"Content-Type": "application/json; charset=utf-8"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            code, text = response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        code, text = error.code, error.read().decode("utf-8", "replace")

    print("\nHTTP %d — %s" % (code, STATUS.get(code, "unexpected status")))
    if text.strip():
        print(text.strip()[:500])
    if code not in (200, 202):
        raise SystemExit(1)


main()
