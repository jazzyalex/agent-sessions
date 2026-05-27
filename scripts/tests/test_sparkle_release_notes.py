import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "release" / "sparkle_release_notes.py"

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
