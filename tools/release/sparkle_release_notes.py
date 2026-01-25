#!/usr/bin/env python3
import argparse
import html
import os
import re
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple


@dataclass(frozen=True)
class NotesBundle:
    version: str
    title: str
    highlights: List[str]
    other: List[str]
    baseline_version: Optional[str]
    baseline_items: List[str]
    github_url: Optional[str]


def _read_file(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _write_file(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def _parse_changelog_sections(changelog: str) -> Dict[str, str]:
    """
    Returns version -> raw section body (excluding the version header line).
    Supports headers like:
      ## [2.10.2] - 2026-01-24
      ## [2.10] - 2026-01-16
    """
    lines = changelog.splitlines()
    sections: Dict[str, List[str]] = {}
    current_ver: Optional[str] = None

    header_re = re.compile(r"^##\s+\[([0-9]+(?:\.[0-9]+){1,2})\](?:\s+-\s+.*)?$")

    for line in lines:
        m = header_re.match(line.strip())
        if m:
            current_ver = m.group(1)
            if current_ver not in sections:
                sections[current_ver] = []
            continue

        if current_ver is not None:
            # Stop on next "## [" header handled above; otherwise collect.
            sections[current_ver].append(line.rstrip("\n"))

    return {k: "\n".join(v).strip() for k, v in sections.items()}


def _split_headings(section_body: str) -> List[Tuple[Optional[str], List[str]]]:
    """
    Splits a section body into (heading, lines) chunks where heading is the
    "### ..." title (without ###). Lines before the first heading use None.
    """
    chunks: List[Tuple[Optional[str], List[str]]] = []
    current_heading: Optional[str] = None
    current_lines: List[str] = []

    for raw in section_body.splitlines():
        line = raw.rstrip("\n")
        if line.startswith("### "):
            if current_heading is not None or current_lines:
                chunks.append((current_heading, current_lines))
            current_heading = line.removeprefix("### ").strip()
            current_lines = []
        else:
            current_lines.append(line)

    if current_heading is not None or current_lines:
        chunks.append((current_heading, current_lines))
    return chunks


def _extract_bullets(lines: List[str]) -> List[str]:
    bullets: List[str] = []
    for line in lines:
        s = line.strip()
        if s.startswith("- "):
            bullets.append(s[2:].strip())
    return bullets


def _items_by_heading(section_body: str) -> Dict[str, List[str]]:
    items: Dict[str, List[str]] = {}
    for heading, lines in _split_headings(section_body):
        if not heading:
            continue
        bullets = _extract_bullets(lines)
        if bullets:
            items[heading] = bullets
    return items


def _pick_highlights(items: Dict[str, List[str]], max_items: int = 6) -> List[str]:
    """
    Heuristic:
      - Prefer Fixed + Security + Added/Changed
      - Preserve intra-heading order
    """
    priority = ["Security", "Fixed", "Added", "Changed", "Performance", "Removed", "Deprecated"]
    highlights: List[str] = []
    seen = set()

    def take_from(heading: str, limit: int) -> None:
        nonlocal highlights
        for item in items.get(heading, []):
            if len(highlights) >= max_items:
                return
            if item in seen:
                continue
            highlights.append(item)
            seen.add(item)
            if len(highlights) >= limit and limit < max_items:
                # For per-heading caps.
                return

    # Per-heading caps to keep "Highlights" balanced.
    take_from("Security", 2)
    take_from("Fixed", 3)
    take_from("Added", 2)
    take_from("Changed", 2)

    # If still short, fill from remaining headings in a stable order.
    if len(highlights) < max_items:
        for heading in priority:
            if heading in ("Security", "Fixed", "Added", "Changed"):
                continue
            for item in items.get(heading, []):
                if len(highlights) >= max_items:
                    break
                if item in seen:
                    continue
                highlights.append(item)
                seen.add(item)

    if len(highlights) < max_items:
        for heading in sorted(items.keys()):
            for item in items[heading]:
                if len(highlights) >= max_items:
                    break
                if item in seen:
                    continue
                highlights.append(item)
                seen.add(item)

    return highlights


def _other_changes(items: Dict[str, List[str]], highlights: List[str], max_items: int = 10) -> List[str]:
    remainder: List[str] = []
    highlight_set = set(highlights)

    # Preserve the changelog's category ordering where possible.
    preferred_order = ["Added", "Changed", "Fixed", "Performance", "Security", "Deprecated", "Removed"]
    headings = [h for h in preferred_order if h in items] + [h for h in items.keys() if h not in preferred_order]

    for heading in headings:
        for item in items.get(heading, []):
            if item in highlight_set:
                continue
            remainder.append(item)
            if len(remainder) >= max_items:
                return remainder

    return remainder


def _baseline_version_for(version: str, sections: Dict[str, str]) -> Optional[str]:
    """
    - For A.B.C, baseline is A.B (parent major/minor)
    - For A.B, baseline is A.(B-1) if present
    """
    m = re.match(r"^([0-9]+)\.([0-9]+)\.([0-9]+)$", version)
    if m:
        return f"{m.group(1)}.{m.group(2)}"

    m2 = re.match(r"^([0-9]+)\.([0-9]+)$", version)
    if not m2:
        return None

    major = int(m2.group(1))
    minor = int(m2.group(2))
    if minor <= 0:
        return None
    candidate = f"{major}.{minor - 1}"
    return candidate if candidate in sections else None


def _baseline_summary(section_body: str, max_items: int = 4) -> List[str]:
    """
    Prefer TL;DR bullets if present, otherwise fall back to first bullets of the section.
    """
    chunks = _split_headings(section_body)
    for heading, lines in chunks:
        if heading and heading.strip().lower() == "tl;dr":
            bullets = _extract_bullets(lines)
            return bullets[:max_items]

    # Fallback: first bullets in the section across headings.
    by_heading = _items_by_heading(section_body)
    flat: List[str] = []
    for h in by_heading.keys():
        flat.extend(by_heading[h])
        if len(flat) >= max_items:
            break
    return flat[:max_items]


def build_notes_bundle(version: str, changelog_path: str, github_url: Optional[str]) -> NotesBundle:
    changelog = _read_file(changelog_path)
    sections = _parse_changelog_sections(changelog)

    if version not in sections:
        raise SystemExit(f"ERROR: CHANGELOG missing section for [{version}]")

    current_items = _items_by_heading(sections[version])
    highlights = _pick_highlights(current_items, max_items=6)
    other = _other_changes(current_items, highlights, max_items=10)

    baseline_version = _baseline_version_for(version, sections)
    baseline_items: List[str] = []
    if baseline_version and baseline_version in sections:
        baseline_items = _baseline_summary(sections[baseline_version], max_items=4)

    title = f"What's New in {version}"
    return NotesBundle(
        version=version,
        title=title,
        highlights=highlights,
        other=other,
        baseline_version=baseline_version,
        baseline_items=baseline_items,
        github_url=github_url,
    )


def _render_list(items: List[str]) -> str:
    if not items:
        return ""
    li = "\n".join(f"<li>{html.escape(x)}</li>" for x in items)
    return f"<ul>\n{li}\n</ul>"


def render_html(bundle: NotesBundle) -> str:
    parts: List[str] = [f"<h2>{html.escape(bundle.title)}</h2>"]

    if bundle.highlights:
        parts.append("<h3>Highlights</h3>")
        parts.append(_render_list(bundle.highlights))

    if bundle.other:
        parts.append("<h3>Other Changes</h3>")
        parts.append(_render_list(bundle.other))

    if bundle.baseline_version and bundle.baseline_items:
        parts.append(f"<h3>Reminder: What You Got in {html.escape(bundle.baseline_version)}</h3>")
        parts.append(_render_list(bundle.baseline_items))

    if bundle.github_url:
        parts.append(f'<p>Full release notes: <a href="{html.escape(bundle.github_url)}">{html.escape(bundle.github_url)}</a></p>')

    return "\n".join(parts).strip() + "\n"


def render_plaintext(bundle: NotesBundle) -> str:
    out: List[str] = [bundle.title, ""]

    if bundle.highlights:
        out.append("Highlights:")
        out.extend([f"- {x}" for x in bundle.highlights])
        out.append("")

    if bundle.other:
        out.append("Other Changes:")
        out.extend([f"- {x}" for x in bundle.other])
        out.append("")

    if bundle.baseline_version and bundle.baseline_items:
        out.append(f"Reminder: What You Got in {bundle.baseline_version}:")
        out.extend([f"- {x}" for x in bundle.baseline_items])
        out.append("")

    if bundle.github_url:
        out.append(f"Full release notes: {bundle.github_url}")

    return "\n".join(out).rstrip() + "\n"


def update_appcast_description(appcast_path: str, version: str, description_html: str) -> None:
    xml = _read_file(appcast_path)

    item_re = re.compile(
        r"(<item>.*?<sparkle:shortVersionString>\s*"
        + re.escape(version)
        + r"\s*</sparkle:shortVersionString>.*?</item>)",
        re.DOTALL,
    )
    m = item_re.search(xml)
    if not m:
        raise SystemExit(f"ERROR: Could not find <item> for shortVersionString={version} in {appcast_path}")

    item = m.group(1)

    desc_block = "            <description><![CDATA[\n" + description_html + "            ]]></description>"

    if "<description" in item:
        item2 = re.sub(r"\s*<description>.*?</description>\s*", "\n" + desc_block + "\n", item, flags=re.DOTALL)
    else:
        if "</pubDate>" in item:
            item2 = item.replace("</pubDate>", "</pubDate>\n" + desc_block, 1)
        elif "<sparkle:shortVersionString" in item:
            item2 = re.sub(
                r"(</sparkle:shortVersionString>)",
                r"\1\n" + desc_block,
                item,
                count=1,
            )
        else:
            item2 = item.replace("</item>", desc_block + "\n</item>", 1)

    updated = xml[: m.start(1)] + item2 + xml[m.end(1) :]
    _write_file(appcast_path, updated)


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate Sparkle release notes and optionally inject into appcast.xml.")
    ap.add_argument("--version", required=True)
    ap.add_argument("--changelog", required=True)
    ap.add_argument("--appcast", default=None)
    ap.add_argument("--github-url", default=None)
    ap.add_argument("--out-html", default=None)
    ap.add_argument("--out-text", default=None)
    args = ap.parse_args()

    bundle = build_notes_bundle(args.version, args.changelog, args.github_url)
    html_out = render_html(bundle)
    text_out = render_plaintext(bundle)

    if args.out_html:
        _write_file(args.out_html, html_out)
    if args.out_text:
        _write_file(args.out_text, text_out)

    if args.appcast:
        update_appcast_description(args.appcast, args.version, html_out)

    # Always print a readable preview for logs.
    sys.stdout.write(text_out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
