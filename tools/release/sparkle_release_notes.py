#!/usr/bin/env python3
import argparse
import html
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple


@dataclass(frozen=True)
class NotesBundle:
    version: str
    title: str
    highlights: List[str]
    other: List[str]
    features: List[str] = field(default_factory=list)
    improvements: List[str] = field(default_factory=list)
    bug_fixes: List[str] = field(default_factory=list)
    baseline_version: Optional[str] = None
    baseline_items: List[str] = field(default_factory=list)
    github_url: Optional[str] = None


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

    header_re = re.compile(r"^##\s+\[([0-9]+(?:\.[0-9]+){1,3})\](?:\s+-\s+.*)?$")

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


def _items_with_fallback(section_body: str) -> Dict[str, List[str]]:
    """
    Returns changelog items keyed by heading.
    If a section uses plain bullets without "###" headings, map them to Changed.
    """
    items = _items_by_heading(section_body)
    if items:
        return items

    flat_bullets = _extract_bullets(section_body.splitlines())
    if flat_bullets:
        return {"Changed": flat_bullets}

    return {}


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


def _dedupe_keep_order(items: List[str]) -> List[str]:
    seen = set()
    out: List[str] = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out


def _normalized_heading(heading: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", heading.strip().lower()).strip()


def _structured_sections(items: Dict[str, List[str]]) -> Tuple[List[str], List[str], List[str]]:
    features: List[str] = []
    improvements: List[str] = []
    bug_fixes: List[str] = []

    for heading, bullets in items.items():
        key = _normalized_heading(heading)
        if key in {"features", "feature", "major features", "new features"}:
            features.extend(bullets)
            continue
        if key in {"improvements", "improvement", "improved", "major changes", "major updates"}:
            improvements.extend(bullets)
            continue
        if key in {"bug fixes", "bug fix", "fixes", "critical fixes", "major bug fixes"}:
            bug_fixes.extend(bullets)
            continue

    # Fallback map for changelog sections that still use Added/Changed/Fixed headings.
    if not features:
        features.extend(items.get("Added", []))
    if not improvements:
        improvements.extend(items.get("Changed", []))
        improvements.extend(items.get("Performance", []))
    if not bug_fixes:
        bug_fixes.extend(items.get("Fixed", []))

    return (
        _dedupe_keep_order(features)[:6],
        _dedupe_keep_order(improvements)[:6],
        _dedupe_keep_order(bug_fixes)[:6],
    )


def _baseline_version_for(version: str, sections: Dict[str, str]) -> Optional[str]:
    """
    Only patch releases get a baseline reminder:
    - For A.B.C, baseline is A.B (parent major/minor)
    - For A.B, no baseline reminder is shown
    """
    m = re.match(r"^([0-9]+)\.([0-9]+)\.([0-9]+)$", version)
    if m:
        return f"{m.group(1)}.{m.group(2)}"
    return None


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

    current_items = _items_with_fallback(sections[version])

    # An explicit "### Highlights" section always leads and is never dropped.
    explicit_highlights: List[str] = []
    for heading, bullets in current_items.items():
        if _normalized_heading(heading) in {"highlights", "highlight"}:
            explicit_highlights.extend(bullets)

    features, improvements, bug_fixes = _structured_sections(current_items)

    if explicit_highlights:
        highlights = _dedupe_keep_order(explicit_highlights)
        other = []
    elif features or improvements or bug_fixes:
        # Grouped sections carry the content; no separate heuristic highlights.
        highlights = []
        other = []
    else:
        highlights = _pick_highlights(current_items, max_items=6)
        other = _other_changes(current_items, highlights, max_items=10)

    if not highlights and not other and not (features or improvements or bug_fixes):
        highlights = ["Small bug fixes and stability improvements."]

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
        features=features,
        improvements=improvements,
        bug_fixes=bug_fixes,
        baseline_version=baseline_version,
        baseline_items=baseline_items,
        github_url=github_url,
    )


_BOLD_RE = re.compile(r"\*\*(.+?)\*\*")
_CODE_RE = re.compile(r"`([^`]+?)`")


def _md_inline_html(text: str) -> str:
    """Escape, then render inline markdown (**bold**, `code`) to HTML."""
    t = html.escape(text)
    t = _BOLD_RE.sub(r"<strong>\1</strong>", t)
    t = _CODE_RE.sub(r"<code>\1</code>", t)
    return t


def _render_list(items: List[str], cls: str = "") -> str:
    if not items:
        return ""
    li = "\n".join(f"<li>{_md_inline_html(x)}</li>" for x in items)
    cls_attr = f' class="{cls}"' if cls else ""
    return f"<ul{cls_attr}>\n{li}\n</ul>"


_NOTES_STYLE = """<style>
.rn { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; font-size: 13px; line-height: 1.55; color: #1d1d1f; -webkit-font-smoothing: antialiased; padding: 2px; }
.rn h2 { font-size: 18px; font-weight: 700; letter-spacing: -0.01em; margin: 0 0 2px; }
.rn h3 { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: #86868b; margin: 18px 0 6px; }
.rn h3.hl { color: #0071e3; }
.rn ul { margin: 0; padding-left: 18px; }
.rn li { margin: 5px 0; }
.rn ul.highlights li { margin: 9px 0; }
.rn strong { font-weight: 650; }
.rn code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; background: rgba(0,0,0,0.06); padding: 1px 5px; border-radius: 5px; }
.rn a { color: #0071e3; text-decoration: none; }
.rn .more { color: #86868b; font-size: 12px; margin-top: 16px; }
@media (prefers-color-scheme: dark) {
  .rn { color: #f5f5f7; }
  .rn h3 { color: #98989d; }
  .rn h3.hl { color: #2997ff; }
  .rn code { background: rgba(255,255,255,0.13); }
  .rn a { color: #2997ff; }
}
</style>"""


def render_html(bundle: NotesBundle) -> str:
    parts: List[str] = [_NOTES_STYLE, '<div class="rn">', f"<h2>{html.escape(bundle.title)}</h2>"]

    if bundle.highlights:
        parts.append('<h3 class="hl">Highlights</h3>')
        parts.append(_render_list(bundle.highlights, cls="highlights"))

    if bundle.features:
        parts.append("<h3>Features</h3>")
        parts.append(_render_list(bundle.features))

    if bundle.improvements:
        parts.append("<h3>Improvements</h3>")
        parts.append(_render_list(bundle.improvements))

    if bundle.bug_fixes:
        parts.append("<h3>Bug Fixes</h3>")
        parts.append(_render_list(bundle.bug_fixes))

    if bundle.other:
        parts.append("<h3>Other Changes</h3>")
        parts.append(_render_list(bundle.other))

    if bundle.baseline_version and bundle.baseline_items:
        parts.append(f'<h3>Reminder: What You Got in {html.escape(bundle.baseline_version)}</h3>')
        parts.append(_render_list(bundle.baseline_items))

    if bundle.github_url:
        parts.append(f'<p class="more">Full release notes: <a href="{html.escape(bundle.github_url)}">{html.escape(bundle.github_url)}</a></p>')

    parts.append("</div>")
    return "\n".join(parts).strip() + "\n"


def render_plaintext(bundle: NotesBundle) -> str:
    out: List[str] = [bundle.title, ""]

    if bundle.highlights:
        out.append("Highlights:")
        out.extend([f"- {x}" for x in bundle.highlights])
        out.append("")

    if bundle.features:
        out.append("Features:")
        out.extend([f"- {x}" for x in bundle.features])
        out.append("")

    if bundle.improvements:
        out.append("Improvements:")
        out.extend([f"- {x}" for x in bundle.improvements])
        out.append("")

    if bundle.bug_fixes:
        out.append("Bug Fixes:")
        out.extend([f"- {x}" for x in bundle.bug_fixes])
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


def lint_plaintext_notes(text: str) -> List[str]:
    """
    Catch release-note copy that is syntactically valid but not suitable for
    Sparkle's user-facing update dialog.
    """
    errors: List[str] = []
    lowered = text.lower()

    internal_patterns = [
        r"\binternal\b",
        r"\bimplementation\b",
        r"\bpre-release\b",
        r"\bvalidation fix(?:es)?\b",
        r"\bcleanup\b",
        r"\bhardened\b",
        r"\bhardening\b",
    ]
    for pattern in internal_patterns:
        if re.search(pattern, lowered):
            errors.append(
                "release notes include internal/process wording; keep Sparkle notes focused on user-facing shipped behavior"
            )
            break

    headline_positions = [
        idx
        for heading in ("Highlights:", "Features:", "Improvements:")
        if (idx := text.find(heading)) >= 0
    ]
    bug_fix_pos = text.find("Bug Fixes:")
    if bug_fix_pos >= 0 and headline_positions and bug_fix_pos < min(headline_positions):
        errors.append("Bug Fixes appears before the headline user-facing change")

    return errors


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
        item2 = re.sub(r"\s*<description>.*?</description>", "\n" + desc_block, item, flags=re.DOTALL)
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
    ap.add_argument("--lint", action="store_true", help="Fail if the generated notes look unsuitable for user-facing Sparkle copy.")
    args = ap.parse_args()

    bundle = build_notes_bundle(args.version, args.changelog, args.github_url)
    html_out = render_html(bundle)
    text_out = render_plaintext(bundle)

    if args.lint:
        errors = lint_plaintext_notes(text_out)
        if errors:
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
            print("", file=sys.stderr)
            print(text_out, file=sys.stderr)
            return 2

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
