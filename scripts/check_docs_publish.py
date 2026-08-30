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

3. A published markdown page links to something that only exists in the repo.
   `jekyll-relative-links` rewrites `[x](../AgentSessions/Foo.swift)` into a site
   URL that 404s, because Swift sources are not part of the site. That link works
   perfectly when the same file is read on GitHub, so it is invisible until
   someone loads the published page. `adding-a-session-source.md` shipped 21 of
   them. Repo files must be linked by absolute github.com/blob URL.

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


MD_LINK = re.compile(r"\]\(\s*([^)\s]+)")
DOCS = os.path.join(REPO_ROOT, "docs")


def published_markdown():
    """Markdown files that GitHub Pages actually serves as pages."""
    paths = [os.path.join(DOCS, name) for name in sorted(PUBLIC_ROOT_MARKDOWN)]
    paths += sorted(glob.glob(os.path.join(DOCS, "prompts", "*.md")))
    paths += sorted(glob.glob(os.path.join(DOCS, "bench", "*.md")))
    return [p for p in paths if os.path.exists(p)]


def check_relative_links(excludes):
    """A relative link that escapes docs/ (or hits an excluded file) 404s on the site."""
    problems = []
    for path in published_markdown():
        rel_page = os.path.relpath(path, REPO_ROOT)
        for target in set(MD_LINK.findall(open(path, encoding="utf-8").read())):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith(("#", "//")):
                continue
            bare = target.split("#")[0].split("?")[0]
            if not bare:
                continue
            resolved = os.path.normpath(os.path.join(os.path.dirname(path), bare))
            inside = os.path.commonpath([DOCS, resolved]) == DOCS
            if not inside:
                problems.append(
                    "%s links to %s, which is outside docs/ and 404s on the site. "
                    "Link repo files by absolute github.com/.../blob/main/ URL."
                    % (rel_page, target)
                )
            elif os.path.relpath(resolved, DOCS) in excludes:
                problems.append(
                    "%s links to %s, which is in `exclude:` and therefore not served."
                    % (rel_page, target)
                )
    return problems


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

    problems += check_relative_links(excludes)

    if problems:
        for problem in problems:
            print("ERROR: " + problem, file=sys.stderr)
        raise SystemExit(1)

    print(
        "OK: %d root docs/*.md checked, %d excluded, %d intentionally public, "
        "%d published markdown pages link-checked"
        % (
            len(root_markdown),
            len(excludes),
            len(PUBLIC_ROOT_MARKDOWN),
            len(published_markdown()),
        )
    )


main()
