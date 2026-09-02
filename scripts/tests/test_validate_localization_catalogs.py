import contextlib
import copy
import hashlib
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import validate_localization_catalogs as validator


def string_entry(value: str, *, comment: str = "Fixture copy.") -> dict:
    return {
        "comment": comment,
        "localizations": {
            "en": {
                "stringUnit": {
                    "state": "translated",
                    "value": value,
                }
            }
        },
    }


def catalog(strings: dict[str, dict]) -> dict:
    return {
        "sourceLanguage": "en",
        "strings": strings,
        "version": "1.0",
    }


class LocalizationCatalogValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="agent-sessions-localization-tests-"
        )
        self.root = Path(self.temporary.name)
        self.localizable_path = self.root / "Localizable.xcstrings"
        self.info_path = self.root / "InfoPlist.xcstrings"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_catalog(self, path: Path, payload: dict) -> None:
        path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def info_strings(self) -> dict[str, dict]:
        values = {
            "CFBundleDisplayName": "Agent Sessions",
            "CFBundleName": "Agent Sessions",
            "NSAppleEventsUsageDescription": (
                "Agent Sessions controls Terminal to resume Codex sessions."
            ),
            "NSDownloadsFolderUsageDescription": (
                "Agent Sessions saves exports to Downloads."
            ),
            "NSDesktopFolderUsageDescription": (
                "Agent Sessions reads session files on Desktop."
            ),
            "NSDocumentsFolderUsageDescription": (
                "Agent Sessions reads session files in Documents."
            ),
        }
        return {key: string_entry(value) for key, value in values.items()}

    @staticmethod
    def add_zh_hans(strings: dict[str, dict]) -> None:
        for entry in strings.values():
            source = entry["localizations"]["en"]["stringUnit"]["value"]
            translated = source if source == "Agent Sessions" else f"已翻译：{source}"
            entry["localizations"]["zh-Hans"] = {
                "stringUnit": {
                    "state": "translated",
                    "value": translated,
                }
            }

    def validate_fixture(
        self,
        app_strings: dict[str, dict],
        info_strings: dict[str, dict] | None = None,
    ) -> tuple[int, int, set[str]]:
        info_strings = info_strings or self.info_strings()
        self.write_catalog(self.localizable_path, catalog(app_strings))
        self.write_catalog(self.info_path, catalog(info_strings))
        keys = set(app_strings)
        with (
            mock.patch.object(validator, "EXPECTED_LOCALIZABLE_KEY_COUNT", len(keys)),
            mock.patch.object(
                validator,
                "EXPECTED_LOCALIZABLE_KEY_SHA256",
                validator.localizable_key_digest(keys),
            ),
        ):
            return validator.validate_catalogs(
                self.localizable_path,
                self.info_path,
                skip_xcstringstool=True,
            )

    def assert_validation_fails(self, callback, message: str) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            callback()
        self.assertIn(message, stderr.getvalue())

    def test_current_catalogs_pass_full_validation(self) -> None:
        counts = validator.validate_catalogs(
            validator.LOCALIZABLE,
            validator.INFO_PLIST,
            skip_xcstringstool=False,
        )
        self.assertEqual(counts, (140, 6, set()))

    def test_complete_zh_hans_in_both_catalogs_passes(self) -> None:
        app_strings = {"Hello": string_entry("Hello")}
        info_strings = self.info_strings()
        self.add_zh_hans(app_strings)
        self.add_zh_hans(info_strings)
        self.assertEqual(self.validate_fixture(app_strings, info_strings), (1, 6, {"zh-Hans"}))

    def test_partial_zh_hans_fails(self) -> None:
        app_strings = {
            "Hello": string_entry("Hello"),
            "Welcome": string_entry("Welcome"),
        }
        app_strings["Hello"]["localizations"]["zh-Hans"] = {
            "stringUnit": {"state": "translated", "value": "你好"}
        }
        self.assert_validation_fails(
            lambda: self.validate_fixture(app_strings),
            "zh-Hans is incomplete",
        )

    def test_mismatched_catalog_locale_sets_fail(self) -> None:
        app_strings = {"Hello": string_entry("Hello")}
        self.add_zh_hans(app_strings)
        self.assert_validation_fails(
            lambda: self.validate_fixture(app_strings),
            "translation locales must be complete in both catalogs",
        )

    def test_empty_translation_fails(self) -> None:
        app_strings = {"Hello": string_entry("Hello")}
        app_strings["Hello"]["localizations"]["zh-Hans"] = {
            "stringUnit": {"state": "translated", "value": ""}
        }
        self.assert_validation_fails(
            lambda: self.validate_fixture(app_strings),
            "must have non-empty values",
        )

    def test_source_identical_translation_fails(self) -> None:
        app_strings = {"Hello": string_entry("Hello")}
        app_strings["Hello"]["localizations"]["zh-Hans"] = copy.deepcopy(
            app_strings["Hello"]["localizations"]["en"]
        )
        self.assert_validation_fails(
            lambda: self.validate_fixture(app_strings),
            "contains untranslated source values",
        )

    def test_translated_protected_name_fails(self) -> None:
        app_strings = {"About Agent Sessions": string_entry("About Agent Sessions")}
        app_strings["About Agent Sessions"]["localizations"]["zh-Hans"] = {
            "stringUnit": {"state": "translated", "value": "关于代理会话"}
        }
        self.assert_validation_fails(
            lambda: self.validate_fixture(app_strings),
            "must preserve literal terms",
        )

    def test_unknown_locale_fails(self) -> None:
        app_strings = {"Hello": string_entry("Hello")}
        app_strings["Hello"]["localizations"]["fr"] = {
            "stringUnit": {"state": "translated", "value": "Bonjour"}
        }
        self.assert_validation_fails(
            lambda: self.validate_fixture(app_strings),
            "contains unreviewed locales",
        )

    def test_missing_reviewed_key_fails_baseline(self) -> None:
        expected = {"Hello", "Welcome"}
        with (
            mock.patch.object(validator, "EXPECTED_LOCALIZABLE_KEY_COUNT", 2),
            mock.patch.object(
                validator,
                "EXPECTED_LOCALIZABLE_KEY_SHA256",
                validator.localizable_key_digest(expected),
            ),
        ):
            self.assert_validation_fails(
                lambda: validator.validate_localizable_key_baseline({"Hello"}),
                "differs from the reviewed 140-key foundation baseline",
            )

    def test_stale_source_key_fails(self) -> None:
        app_strings = {"Hello": string_entry("Hello")}
        app_strings["Hello"]["extractionState"] = "stale"
        self.assert_validation_fails(
            lambda: self.validate_fixture(app_strings),
            "is marked stale",
        )

    def test_wrong_info_plist_key_set_fails(self) -> None:
        info_strings = self.info_strings()
        del info_strings["CFBundleName"]
        info_strings["UnexpectedKey"] = string_entry("Unexpected")
        self.assert_validation_fails(
            lambda: self.validate_fixture({"Hello": string_entry("Hello")}, info_strings),
            "InfoPlist catalog keys differ",
        )

    def test_interpolation_shortcut_and_operator_require_comments(self) -> None:
        for key in ("Step %lld", "Use Command-F", "Use #side"):
            with self.subTest(key=key):
                entry = string_entry(key, comment="")
                self.assert_validation_fails(
                    lambda entry=entry: self.validate_fixture({key: entry}),
                    "requires a translator comment",
                )

    def test_valid_plural_variation_compiles(self) -> None:
        payload = catalog(
            {
                "%lld files": {
                    "comment": "File count. Preserve the numeric placeholder.",
                    "localizations": {
                        "en": {
                            "variations": {
                                "plural": {
                                    "one": {
                                        "stringUnit": {
                                            "state": "translated",
                                            "value": "%lld file",
                                        }
                                    },
                                    "other": {
                                        "stringUnit": {
                                            "state": "translated",
                                            "value": "%lld files",
                                        }
                                    },
                                }
                            }
                        }
                    },
                }
            }
        )
        path = self.root / "ValidPlural.xcstrings"
        self.write_catalog(path, payload)
        validator.validate_xcstringstool(path)

    def test_malformed_plural_variation_is_rejected_by_compiler(self) -> None:
        payload = catalog(
            {
                "%lld files": {
                    "comment": "Malformed fixture.",
                    "localizations": {
                        "en": {
                            "variations": {
                                "plural": ["not-a-variation-object"]
                            }
                        }
                    },
                }
            }
        )
        path = self.root / "MalformedPlural.xcstrings"
        self.write_catalog(path, payload)
        self.assert_validation_fails(
            lambda: validator.validate_xcstringstool(path),
            "xcstringstool rejected",
        )

    def test_compiler_validation_does_not_modify_catalog(self) -> None:
        path = self.root / "ReadOnly.xcstrings"
        shutil.copy2(validator.LOCALIZABLE, path)
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        validator.validate_xcstringstool(path)
        after = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
