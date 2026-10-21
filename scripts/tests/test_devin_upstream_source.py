"""Devin's upstream source: the stable CLI changelog page.

Devin is steward-verified and normally not installed on the maintainer machine,
so the configured upstream source is the only signal a sweep can raise (SKILL
1g). These tests pin the configured regex against the page's real heading shape
without touching the network.
"""
import json
from pathlib import Path

import agent_watch

REPO = Path(__file__).resolve().parents[2]

# Shape of https://docs.devin.ai/cli/changelog/stable.md as fetched 2026-10-21:
# a bold version line per release, prose that quotes older versions, and the
# early calendar-versioned entries at the bottom.
CHANGELOG = """> ## Documentation Index
> Fetch the complete documentation index at: https://docs.devin.ai/llms.txt

# Changelog (Stable)

**v3000.11.92**

### Added

* Repaired a regression that was introduced in v3000.99.1 (prose, not a heading)

**v3000.11.3**

### Fixed

* Something

**v3000.6.7**

**v2026.8.18**
"""


def _devin_source() -> dict:
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text(encoding="utf-8"))
    sources = cfg["agents"]["devin"]["upstream"]
    assert len(sources) == 1
    return sources[0]


def test_devin_upstream_reads_the_stable_changelog_headings(monkeypatch):
    source = _devin_source()
    assert source["kind"] == "url_regex_semver_max"
    assert source["url"] == "https://docs.devin.ai/cli/changelog/stable.md"

    seen: list[str] = []

    def fake_get(url, timeout):
        seen.append(url)
        return CHANGELOG

    monkeypatch.setattr(agent_watch, "_http_get_text", fake_get)
    result = agent_watch._fetch_upstream(source, timeout=5)

    assert seen == [source["url"]]
    assert result["ok"] is True
    # Headings only: the prose mention of v3000.99.1 must not win.
    assert result["version"] == "3000.11.92"


def test_devin_upstream_compares_against_the_steward_build_label():
    # The matrix keeps the steward's commit beside the version.
    assert agent_watch._upstream_newer_than_verified("devin", "3000.11.92", "3000.6.7 (260a97c8)") is True
    assert agent_watch._upstream_newer_than_verified("devin", "3000.6.7", "3000.6.7 (260a97c8)") is False


def test_devin_upstream_fails_closed_when_the_page_changes_shape(monkeypatch):
    monkeypatch.setattr(agent_watch, "_http_get_text", lambda url, timeout: "# Changelog\n\nv3000.12.1 shipped\n")
    result = agent_watch._fetch_upstream(_devin_source(), timeout=5)
    assert result["ok"] is False
    assert result["error"] == "no_versions_found"
