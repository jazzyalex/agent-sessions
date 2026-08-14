import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "release" / "sparkle_release_notes.py"
DEPLOY_SCRIPT_PATH = ROOT / "tools" / "release" / "deploy-agent-sessions.sh"

spec = importlib.util.spec_from_file_location("sparkle_release_notes", MODULE_PATH)
sparkle_release_notes = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(sparkle_release_notes)


def test_lint_rejects_bug_fixes_before_headline():
    text = """What's New in 3.8.1

Bug Fixes:
- Resume: Hardened Warp tab config generation.

Improvements:
- Resume workflows can now open every supported CLI agent in Warp.
"""

    errors = sparkle_release_notes.lint_plaintext_notes(text)

    assert any("Bug Fixes appears before" in error for error in errors)
    assert any("internal/process wording" in error for error in errors)


def test_lint_accepts_current_user_facing_notes():
    text = """What's New in 3.8.1

Highlights:
- Resume workflows can now open every supported CLI agent in Warp or WarpPreview.
- Terminal selection is now shared across agents.
"""

    assert sparkle_release_notes.lint_plaintext_notes(text) == []


def test_update_appcast_description_preserves_following_field_indent(tmp_path):
    appcast = tmp_path / "appcast.xml"
    appcast.write_text(
        """<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <item>
            <title>3.8.1</title>
            <description><![CDATA[
<h2>Old</h2>
            ]]></description>
            <sparkle:version>47</sparkle:version>
            <sparkle:shortVersionString>3.8.1</sparkle:shortVersionString>
        </item>
    </channel>
</rss>
""",
        encoding="utf-8",
    )

    sparkle_release_notes.update_appcast_description(
        str(appcast),
        "3.8.1",
        "<h2>What's New in 3.8.1</h2>\n",
    )

    updated = appcast.read_text(encoding="utf-8")
    assert "<h2>What's New in 3.8.1</h2>" in updated
    assert "\n            <sparkle:version>47</sparkle:version>" in updated


def test_deploy_rejects_notes_file_override():
    script = DEPLOY_SCRIPT_PATH.read_text(encoding="utf-8")

    assert "NOTES_FILE=${NOTES_FILE:-}" not in script
    assert "NOTES_FILE override is no longer supported" in script
    assert 'gh release edit "$TAG" --notes-file "$RELEASE_NOTES_FILE"' in script
    assert 'gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Agent Sessions ${VERSION}" --notes-file "$RELEASE_NOTES_FILE"' in script


def test_markdown_links_become_anchors():
    """Contributor credits are the reason this exists.

    The panel used to show raw `[@name](https://…)` to the user, because the inline
    renderer handled bold and code but never links — while the stylesheet shipped an
    `.rn a` rule the whole time.
    """
    out = sparkle_release_notes._md_inline_html(
        "Contributed by [@thedavidweng](https://github.com/thedavidweng) "
        "in [#55](https://github.com/jazzyalex/agent-sessions/pull/55)."
    )

    assert '<a href="https://github.com/jazzyalex/agent-sessions/pull/55">#55</a>' in out
    assert '<a href="https://github.com/thedavidweng">@thedavidweng</a>' in out
    assert "](" not in out, "no literal markdown link syntax may survive"


def test_link_text_still_renders_bold_and_code():
    out = sparkle_release_notes._md_inline_html("see [**the** `flag`](https://example.com/x)")

    assert '<a href="https://example.com/x">' in out
    assert "<strong>the</strong>" in out
    assert "<code>flag</code>" in out


def test_unsafe_link_scheme_is_left_as_literal_text():
    """A hand-written changelog should never yield a script URL; if one appears, show it
    rather than turning it into a working anchor."""
    out = sparkle_release_notes._md_inline_html("[click](javascript:alert(1))")

    assert "<a " not in out
    assert "javascript:" in out


def test_link_rendering_does_not_break_escaping():
    out = sparkle_release_notes._md_inline_html(
        "keeps <system-reminder> escaped next to [a link](https://example.com/a?x=1&y=2)"
    )

    assert "&lt;system-reminder&gt;" in out
    assert "<system-reminder>" not in out
    # `&` inside the URL must stay escaped inside the attribute.
    assert 'href="https://example.com/a?x=1&amp;y=2"' in out
