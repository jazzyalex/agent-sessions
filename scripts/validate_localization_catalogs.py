#!/usr/bin/env python3
"""Validate the repository's String Catalog foundation.

This is intentionally a small, deterministic gate. It validates the committed
catalog shape and asks Apple's compiler to parse each catalog without writing
build products into the repository. It does not sync source extraction into a
catalog: that operation is intentionally performed against a temporary copy in
CI so a build cannot rewrite translation data as a side effect.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, NoReturn


ROOT = Path(__file__).resolve().parents[1]
CATALOG_DIR = ROOT / "AgentSessions" / "Resources"
LOCALIZABLE = CATALOG_DIR / "Localizable.xcstrings"
INFO_PLIST = CATALOG_DIR / "InfoPlist.xcstrings"
INFO_PLIST_SOURCE = ROOT / "AgentSessions" / "Info.plist"

EXPECTED_INFO_PLIST_KEYS = {
    "CFBundleDisplayName",
    "CFBundleName",
    "NSAppleEventsUsageDescription",
    "NSDownloadsFolderUsageDescription",
    "NSDesktopFolderUsageDescription",
    "NSDocumentsFolderUsageDescription",
}
PLANNED_TRANSLATION_LOCALES = {"zh-Hans"}
REQUIRED_INFO_COMMENT_KEYS = {"CFBundleDisplayName", "CFBundleName"}
EXPECTED_LOCALIZABLE_KEY_COUNT = 1287
EXPECTED_LOCALIZABLE_KEY_SHA256 = (
    "ad49f9ec628c30e8f9aed3c33a6d85f884855347276d7c24a4ac183e784339f6"
)
PRESERVED_TERMS = (
    "Agent Sessions",
    "GitHub Copilot CLI",
    "GitHub Discussions",
    "Antigravity CLI",
    "Claude Desktop",
    "Claude Code",
    "Codex CLI",
    "Qwen Code",
    "Kimi Code",
    "Grok CLI",
    "Devin CLI",
    "OpenCode",
    "OpenClaw",
    "iTerm2",
    "GitHub",
    "Codex",
    "Claude",
    "Copilot",
    "Antigravity",
    "Cursor",
    "Hermes",
    "Droid",
    "Qwen",
    "Kimi",
    "Grok",
    "Devin",
    "MIT License",
    "Terminal App",
    "VS Code",
    "Finder",
    "Terminal",
    "macOS",
    "Web API",
    "OAuth",
    "JSONL",
    "JSON",
    "Markdown",
    "Sparkle",
    "tmux",
    "launchd",
    "github.com/jazzyalex/agent-sessions",
    "jazzyalex.github.io/agent-sessions",
    "jazzyalex@gmail.com",
    "fx",
    "⌥⌘F",
    "⌘F",
    "#side",
    "Option-Command-F",
    "Shift-Command-G",
    "Command-Plus",
    "Command-Minus",
    "Command-1",
    "Command-2",
    "Command-F",
    "Command-G",
)
# Xcode extracts these literals from controls that intentionally display raw
# symbols, provider names, format fragments, or path examples. Keep this list
# exact so any new extracted key must either enter the catalog or be reviewed
# here as deliberately verbatim.
EXPECTED_VERBATIM_EXTRACTED_KEYS = {
    "",
    " ",
    " %@",
    " ▸4h 59m",
    "%@ %@",
    "%@ --  %@",
    "%@ —",
    "%@ — %@",
    "%@: %@%@",
    "%lld",
    "%lld%%",
    "(%lld%%)",
    "(%lld)",
    "+",
    "/path/to/agent",
    "/path/to/agy",
    "/path/to/claude",
    "/path/to/codex",
    "/path/to/copilot",
    "/path/to/devin",
    "/path/to/droid",
    "/path/to/fx",
    "/path/to/grok",
    "/path/to/hermes",
    "/path/to/kimi",
    "/path/to/openclaw",
    "/path/to/opencode",
    "/path/to/pi",
    "/path/to/qwen",
    ">",
    "@jazzyalex",
    "A",
    "AS",
    "F",
    "M",
    "Pi",
    "S",
    "T",
    "W",
    "|",
    "~/.copilot/session-state",
    "~/.cursor",
    "~/.cursor/chats/*/*/store.db",
    "~/.cursor/projects/*/agent-transcripts/",
    "~/.factory/projects",
    "~/.factory/sessions",
    "~/.fx/sessions",
    "~/.grok/sessions",
    "~/.hermes/sessions",
    "~/.kimi-code/sessions",
    "~/.local/share/devin/cli",
    "~/.openclaw",
    "~/.pi/agent/sessions",
    "~/.qwen/projects",
    "·",
    "· %@",
    "—",
    "↻",
    "−",
    "★",
}
FORMAT_TOKEN = re.compile(
    r"%#@[^@]+@|%arg|%%|%(?:\d+\$)?(?:lld|llu|ld|lu|d|u|f|g|@)"
)


def fail(message: str) -> NoReturn:
    print(f"localization validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def load_catalog(path: Path) -> dict[str, Any]:
    if not path.is_file():
        fail(f"missing catalog {display_path(path)}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot parse {display_path(path)}: {error}")
    if not isinstance(value, dict):
        fail(f"catalog root must be an object: {display_path(path)}")
    return value


def load_info_plist(path: Path) -> dict[str, Any]:
    if not path.is_file():
        fail(f"missing source Info.plist {display_path(path)}")
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot parse source Info.plist {display_path(path)}: {error}")
    if not isinstance(value, dict):
        fail(f"source Info.plist root must be a dictionary: {display_path(path)}")
    return value


def string_units(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, dict):
        return []
    units: list[dict[str, Any]] = []
    unit = value.get("stringUnit")
    if isinstance(unit, dict):
        units.append(unit)
    for child_key, child in value.items():
        if child_key != "stringUnit":
            units.extend(string_units(child))
    return units


def validate_string_unit(path: Path, key: str, locale: str, localization: Any) -> None:
    units = string_units(localization)
    if not units:
        fail(f"{display_path(path)}:{key}:{locale} must contain a string unit or variation")
    for unit in units:
        if unit.get("state") != "translated":
            fail(f"{display_path(path)}:{key}:{locale} must have translated string units")
        if not isinstance(unit.get("value"), str) or not unit["value"]:
            fail(f"{display_path(path)}:{key}:{locale} must have non-empty values")


def localization_values(localization: Any) -> list[str]:
    return [
        unit["value"]
        for unit in string_units(localization)
        if isinstance(unit.get("value"), str) and unit["value"]
    ]


def has_translatable_text(value: str) -> bool:
    stripped = FORMAT_TOKEN.sub("", value)
    for term in PRESERVED_TERMS:
        stripped = stripped.replace(term, "")
    return any(character.isalpha() for character in stripped)


def validate_preserved_terms(
    path: Path,
    key: str,
    locale: str,
    source_localization: Any,
    localization: Any,
) -> None:
    if locale == "en":
        return
    source_text = "\n".join(localization_values(source_localization))
    translated_text = "\n".join(localization_values(localization))
    changed = sorted(
        term
        for term in PRESERVED_TERMS
        if source_text.count(term) != translated_text.count(term)
    )
    if changed:
        fail(
            f"{display_path(path)}:{key}:{locale} must preserve literal terms "
            f"and occurrence counts: {changed}"
        )


def validate_translation_changed(
    path: Path,
    key: str,
    locale: str,
    source_localization: Any,
    localization: Any,
) -> None:
    if locale == "en":
        return
    source_values = {
        value
        for value in localization_values(source_localization)
        if has_translatable_text(value)
    }
    unchanged = sorted(source_values & set(localization_values(localization)))
    if unchanged:
        fail(
            f"{display_path(path)}:{key}:{locale} contains untranslated source "
            f"values: {unchanged[:3]}"
        )


def requires_translation_comment(key: str) -> bool:
    return "%" in key or "Command-" in key or "#side" in key


def localizable_key_digest(keys: set[str]) -> str:
    payload = "\n".join(sorted(keys)) + "\n"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def validate_localizable_key_baseline(keys: set[str]) -> None:
    digest = localizable_key_digest(keys)
    if (
        len(keys) != EXPECTED_LOCALIZABLE_KEY_COUNT
        or digest != EXPECTED_LOCALIZABLE_KEY_SHA256
    ):
        fail(
            "Localizable catalog key set differs from the reviewed foundation "
            f"baseline; count={len(keys)}, sha256={digest}"
        )


def validate_info_plist_source_values(
    catalog_path: Path,
    catalog: dict[str, Any],
    source_path: Path,
) -> None:
    source_values = load_info_plist(source_path)
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        fail(f"{display_path(catalog_path)} has no strings object")

    for key in sorted(EXPECTED_INFO_PLIST_KEYS):
        entry = strings.get(key)
        if not isinstance(entry, dict):
            fail(f"{display_path(catalog_path)}:{key} must be an object")
        if key in REQUIRED_INFO_COMMENT_KEYS:
            comment = entry.get("comment")
            if not isinstance(comment, str) or not comment.strip():
                fail(f"{display_path(catalog_path)}:{key} requires a translator comment")

        english = entry.get("localizations", {}).get("en")
        catalog_values = localization_values(english)
        source_value = source_values.get(key)
        if not isinstance(source_value, str):
            fail(f"{display_path(source_path)}:{key} must contain a string value")
        if catalog_values != [source_value]:
            fail(
                f"{display_path(catalog_path)}:{key} English value differs from "
                f"{display_path(source_path)}"
            )


def validate_shape(path: Path, catalog: dict[str, Any]) -> tuple[set[str], set[str]]:
    relative = display_path(path)
    if catalog.get("sourceLanguage") != "en":
        fail(f"{relative} must declare sourceLanguage en")
    if catalog.get("version") != "1.0":
        fail(f"{relative} must declare String Catalog version 1.0")
    strings = catalog.get("strings")
    if not isinstance(strings, dict) or not strings:
        fail(f"{relative} must contain a non-empty strings object")

    keys: set[str] = set()
    translated_locales: set[str] = set()
    for key, entry in strings.items():
        if not isinstance(key, str) or not key:
            fail(f"{relative} contains an empty or non-string key")
        keys.add(key)
        if not isinstance(entry, dict):
            fail(f"{relative}:{key} must be an object")
        if entry.get("extractionState") == "stale":
            fail(f"{relative}:{key} is marked stale; remove it or restore its source use")
        if requires_translation_comment(key):
            comment = entry.get("comment")
            if not isinstance(comment, str) or not comment.strip():
                fail(f"{relative}:{key} requires a translator comment")
        localizations = entry.get("localizations")
        if not isinstance(localizations, dict) or "en" not in localizations:
            fail(f"{relative}:{key} must contain the English source value")
        unexpected = set(localizations) - {"en"} - PLANNED_TRANSLATION_LOCALES
        if unexpected:
            fail(f"{relative}:{key} contains unreviewed locales: {sorted(unexpected)}")
        source_localization = localizations["en"]
        for locale, localization in localizations.items():
            validate_string_unit(path, key, locale, localization)
            validate_preserved_terms(
                path, key, locale, source_localization, localization
            )
            validate_translation_changed(
                path, key, locale, source_localization, localization
            )
            if locale != "en":
                translated_locales.add(locale)

    for locale in sorted(translated_locales):
        missing = sorted(
            key for key, entry in strings.items()
            if locale not in entry.get("localizations", {})
        )
        if missing:
            sample = ", ".join(repr(key) for key in missing[:5])
            suffix = "" if len(missing) <= 5 else f" (and {len(missing) - 5} more)"
            fail(f"{relative}:{locale} is incomplete; missing {sample}{suffix}")
    return keys, translated_locales


def validate_xcstringstool(path: Path) -> None:
    xcrun = shutil.which("xcrun")
    if xcrun is None:
        fail("xcrun is required to validate String Catalog syntax")
    with tempfile.TemporaryDirectory(prefix="agent-sessions-xcstrings-") as output:
        command = [
            xcrun,
            "xcstringstool",
            "compile",
            str(path),
            "--output-directory",
            output,
            "--dry-run",
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            details = (result.stderr or result.stdout).strip()
            fail(f"xcstringstool rejected {display_path(path)}: {details}")


def extraction_files(extraction_root: Path) -> list[Path]:
    if not extraction_root.is_dir():
        fail(f"stringsdata extraction root does not exist: {extraction_root}")
    files = sorted(extraction_root.rglob("*.stringsdata"))
    if not files:
        fail(f"no .stringsdata files found under {extraction_root}")
    return files


def english_payload(entry: dict[str, Any], path: Path, key: str) -> dict[str, Any]:
    localizations = entry.get("localizations")
    en = localizations.get("en") if isinstance(localizations, dict) else None
    if not isinstance(en, dict):
        fail(f"{display_path(path)}:{key} has no English localization after sync")
    return en


def validate_extracted_key_coverage(
    original_strings: dict[str, Any], synced_strings: dict[str, Any]
) -> None:
    extracted_only = set(synced_strings) - set(original_strings)
    if extracted_only != EXPECTED_VERBATIM_EXTRACTED_KEYS:
        unexpected = sorted(extracted_only - EXPECTED_VERBATIM_EXTRACTED_KEYS)
        missing = sorted(EXPECTED_VERBATIM_EXTRACTED_KEYS - extracted_only)
        fail(
            "extracted keys outside the catalog differ from the reviewed verbatim set; "
            f"unexpected={unexpected[:5]}, missing={missing[:5]}"
        )


def validate_extraction_drift(
    extraction_root: Path,
    catalog_path: Path,
    original_catalog: dict[str, Any],
) -> None:
    """Sync a temporary catalog and reject stale or changed committed entries.

    The complete application emits many stringsdata files. Syncing a temporary
    copy lets CI detect a renamed/removed source key without allowing a build to
    rewrite the reviewed catalog or silently add the rest of the app's backlog.
    """
    files = extraction_files(extraction_root)
    xcrun = shutil.which("xcrun")
    if xcrun is None:
        fail("xcrun is required for extraction drift validation")

    original_strings = original_catalog.get("strings")
    if not isinstance(original_strings, dict):
        fail("Localizable catalog strings are unavailable for drift validation")

    with tempfile.TemporaryDirectory(prefix="agent-sessions-xcstrings-drift-") as temporary:
        temporary_catalog = Path(temporary) / LOCALIZABLE.name
        shutil.copy2(catalog_path, temporary_catalog)
        command = [xcrun, "xcstringstool", "sync", str(temporary_catalog)]
        for stringsdata in files:
            command.extend(("--stringsdata", str(stringsdata)))
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            details = (result.stderr or result.stdout).strip()
            fail(f"xcstringstool drift sync failed: {details}")

        synced = load_catalog(temporary_catalog)
        synced_strings = synced.get("strings")
        if not isinstance(synced_strings, dict):
            fail("temporary synced catalog has no strings object")

        validate_extracted_key_coverage(original_strings, synced_strings)

        stale = sorted(
            key
            for key in original_strings
            if not isinstance(synced_strings.get(key), dict)
            or synced_strings[key].get("extractionState") == "stale"
        )
        if stale:
            fail(
                "committed app keys are not present in current source extraction: "
                + ", ".join(repr(key) for key in stale)
            )

        changed = sorted(
            key
            for key, original_entry in original_strings.items()
            if isinstance(original_entry, dict)
            and english_payload(original_entry, LOCALIZABLE, key)
            != english_payload(synced_strings[key], temporary_catalog, key)
        )
        if changed:
            fail(
                "committed English values differ from current source extraction: "
                + ", ".join(repr(key) for key in changed)
            )

    print(f"localization extraction drift valid: checked {len(original_strings)} committed app keys against {len(files)} stringsdata files")


def validate_catalogs(
    localizable_path: Path,
    info_plist_path: Path,
    *,
    skip_xcstringstool: bool,
    extraction_root: Path | None = None,
    info_plist_source_path: Path = INFO_PLIST_SOURCE,
) -> tuple[int, int, set[str]]:
    localizable_catalog = load_catalog(localizable_path)
    localizable_keys, localizable_locales = validate_shape(
        localizable_path, localizable_catalog
    )
    validate_localizable_key_baseline(localizable_keys)
    info_catalog = load_catalog(info_plist_path)
    info_keys, info_locales = validate_shape(info_plist_path, info_catalog)
    if info_keys != EXPECTED_INFO_PLIST_KEYS:
        missing = sorted(EXPECTED_INFO_PLIST_KEYS - info_keys)
        unexpected = sorted(info_keys - EXPECTED_INFO_PLIST_KEYS)
        fail(f"InfoPlist catalog keys differ; missing={missing}, unexpected={unexpected}")
    validate_info_plist_source_values(
        info_plist_path, info_catalog, info_plist_source_path
    )
    if localizable_locales != info_locales:
        fail(
            "translation locales must be complete in both catalogs; "
            f"Localizable={sorted(localizable_locales)}, InfoPlist={sorted(info_locales)}"
        )

    if not skip_xcstringstool:
        validate_xcstringstool(localizable_path)
        validate_xcstringstool(info_plist_path)
        if extraction_root is not None:
            validate_extraction_drift(
                extraction_root.resolve(), localizable_path, localizable_catalog
            )

    return len(localizable_keys), len(info_keys), localizable_locales


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skip-xcstringstool",
        action="store_true",
        help="Only validate JSON shape (useful on non-macOS development hosts).",
    )
    parser.add_argument(
        "--extraction-root",
        type=Path,
        help="After a build, sync this .stringsdata tree into a temporary catalog and check committed-key drift.",
    )
    args = parser.parse_args()

    localizable_count, info_count, localizable_locales = validate_catalogs(
        LOCALIZABLE,
        INFO_PLIST,
        skip_xcstringstool=args.skip_xcstringstool,
        extraction_root=args.extraction_root,
    )

    print(
        "localization catalogs valid: "
        f"{localizable_count} app keys, {info_count} Info.plist keys, "
        f"translations={sorted(localizable_locales) or 'none'}"
    )
    return 0


if __name__ == "__main__":
    main()
