#!/usr/bin/env python3
"""Guard what docs/ publishes to jazzyalex.github.io/agent-sessions.

Two failure modes this catches, both silent otherwise:

1. A new root-level `docs/*.md` is served publicly the moment it lands, because
   GitHub Pages runs `jekyll-optional-front-matter` and renders markdown with no
   front matter as a page. Internal specs, plans, and competitive notes have to be
   named in `_config.yml`'s `exclude:` list or they publish. This already happened
   once: `competitive-codexbar.md` was live and in the sitemap for months.

2. A must-serve path is added to `exclude:`. Excluding `appcast.xml` breaks the
   Sparkle feed and therefore auto-update for every installed copy.

No third-party imports: this runs in CI before anything is installed. The
`exclude:` block is parsed by hand, with enough assertions that a silent
mis-parse fails loudly instead of passing everything.
"""

import glob
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(REPO_ROOT, "docs", "_config.yml")

# Root-level docs/*.md that are meant to be public. Adding a name here is a
# deliberate publishing decision — it means the file is written for readers of
# the site, not for us.
PUBLIC_ROOT_MARKDOWN = {
    "adding-a-session-source.md",
}

# Excluding any of these breaks something users depend on.
MUST_SERVE = {
    "index.html",
    "404.html",
    "appcast.xml",
    "assets",
    "guides",
    "blog",
    "bench",
    "prompts",
}

# A real exclude list is long. If we ever parse fewer entries than this, the
# parser has drifted from the file and every check below is meaningless.
MIN_EXPECTED_EXCLUDES = 20

ITEM = re.compile(r'^\s{1,4}-\s+"?([^"\n]+?)"?\s*$')


def parse_excludes(path):
    """Return the entries under the top-level `exclude:` key."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    start = None
    for i, line in enumerate(lines):
        if line.rstrip() == "exclude:":
            start = i + 1
            break
    if start is None:
        die("no top-level `exclude:` key in docs/_config.yml — parser is out of date")

    entries = []
    for line in lines[start:]:
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        if not line.startswith((" ", "\t")):
            break  # next top-level key: the block ended
        match = ITEM.match(line)
        if not match:
            die("unparsable line in the `exclude:` block: %r" % line)
        entries.append(match.group(1))

    if len(entries) < MIN_EXPECTED_EXCLUDES:
        die(
            "parsed only %d exclude entries (expected >= %d) — the parser has drifted "
            "and would pass everything" % (len(entries), MIN_EXPECTED_EXCLUDES)
        )
    return entries


def die(message):
    print("ERROR: " + message, file=sys.stderr)
    raise SystemExit(1)


def main():
    excludes = set(parse_excludes(CONFIG))

    problems = []

    root_markdown = sorted(
        os.path.basename(p) for p in glob.glob(os.path.join(REPO_ROOT, "docs", "*.md"))
    )
    for name in root_markdown:
        if name in PUBLIC_ROOT_MARKDOWN:
            continue
        if name not in excludes:
            problems.append(
                "docs/%s would be published. Add it to `exclude:` in docs/_config.yml, "
                "or to PUBLIC_ROOT_MARKDOWN in this script if it is meant to be public."
                % name
            )

    for name in sorted(MUST_SERVE & excludes):
        problems.append(
            "docs/%s is in `exclude:` but must stay served. Remove it." % name
        )

    for name in sorted(PUBLIC_ROOT_MARKDOWN):
        if not os.path.exists(os.path.join(REPO_ROOT, "docs", name)):
            problems.append(
                "PUBLIC_ROOT_MARKDOWN lists docs/%s, which does not exist. "
                "Drop it from this script." % name
            )

    if problems:
        for problem in problems:
            print("ERROR: " + problem, file=sys.stderr)
        raise SystemExit(1)

    print(
        "OK: %d root docs/*.md checked, %d excluded, %d intentionally public"
        % (len(root_markdown), len(excludes), len(PUBLIC_ROOT_MARKDOWN))
    )


main()
