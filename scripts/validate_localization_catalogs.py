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

EXPECTED_INFO_PLIST_KEYS = {
    "CFBundleDisplayName",
    "CFBundleName",
    "NSAppleEventsUsageDescription",
    "NSDownloadsFolderUsageDescription",
    "NSDesktopFolderUsageDescription",
    "NSDocumentsFolderUsageDescription",
}
PLANNED_TRANSLATION_LOCALES = {"zh-Hans"}
EXPECTED_LOCALIZABLE_KEY_COUNT = 140
EXPECTED_LOCALIZABLE_KEY_SHA256 = (
    "cc40e94e086354ab3446069ed6b1f550ae73d87b640eb2e0835de59565c146ba"
)
PRESERVED_TERMS = (
    "Agent Sessions",
    "Claude Code",
    "Codex CLI",
    "OpenCode",
    "iTerm2",
    "Codex",
    "Claude",
    "Finder",
    "Terminal",
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
            "Localizable catalog key set differs from the reviewed 140-key "
            f"foundation baseline; count={len(keys)}, sha256={digest}"
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
) -> tuple[int, int, set[str]]:
    localizable_catalog = load_catalog(localizable_path)
    localizable_keys, localizable_locales = validate_shape(
        localizable_path, localizable_catalog
    )
    validate_localizable_key_baseline(localizable_keys)
    info_keys, info_locales = validate_shape(
        info_plist_path, load_catalog(info_plist_path)
    )
    if info_keys != EXPECTED_INFO_PLIST_KEYS:
        missing = sorted(EXPECTED_INFO_PLIST_KEYS - info_keys)
        unexpected = sorted(info_keys - EXPECTED_INFO_PLIST_KEYS)
        fail(f"InfoPlist catalog keys differ; missing={missing}, unexpected={unexpected}")
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
