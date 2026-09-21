import importlib.util
from pathlib import Path
from unittest import mock


REPO = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO / "scripts" / "check_xcode_version.py"
spec = importlib.util.spec_from_file_location("check_xcode_version", MODULE_PATH)
assert spec is not None and spec.loader is not None
check_xcode_version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_xcode_version)


def test_expected_toolchain_is_two_line_contract():
    assert check_xcode_version.expected_xcode_version() == (
        "Xcode 26.3",
        "Build version 17C529",
    )


def test_main_rejects_toolchain_drift():
    with mock.patch.object(
        check_xcode_version,
        "actual_xcode_version",
        return_value=("Xcode 26.6", "Build version 17F113"),
    ):
        assert check_xcode_version.main() == 1


def test_main_accepts_expected_toolchain():
    expected = check_xcode_version.expected_xcode_version()
    with mock.patch.object(check_xcode_version, "actual_xcode_version", return_value=expected):
        assert check_xcode_version.main() == 0
