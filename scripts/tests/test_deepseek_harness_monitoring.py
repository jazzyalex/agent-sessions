import ctypes
import json
import os
import random
import shutil
import sys
from pathlib import Path

import pytest

from scripts import agent_watch
from scripts.verify_dsh_fixture_manifest import PINNED_SOURCE_COMMIT, verify


REPO = Path(__file__).resolve().parents[2]


def test_dsh_fixture_manifest_and_monitoring_baseline_are_nonempty() -> None:
    assert verify() == 0

    config = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    dsh = config["agents"]["deepseek_harness"]
    assert dsh["verified_version_source"].endswith("agents.deepseek_harness.max_verified_version")
    local_schema = dsh["weekly"]["local_schema"]
    assert local_schema["kind"] == "deepseek_harness_sessions"
    assert local_schema["root_env"] == "DSH_HOME"
    assert local_schema["default_root"] == "~/.dsh/sessions"
    assert local_schema["sample_count"] == 5
    assert dsh["weekly"]["discovery_path_contract"]["patterns"]
    assert dsh["weekly"]["probes"][0]["argv"] == [
        "./scripts/verify_dsh_fixture_manifest.py"
    ]

    matrix_text = (REPO / "docs/agent-support/agent-support-matrix.yml").read_text()
    fixture_root = "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
    matrix_evidence = [
        f"{fixture_root}/v{version}_minimal_session.jsonl"
        for version in range(4)
    ] + [
        f"{fixture_root}/unknown_ignorable_event.jsonl",
        f"{fixture_root}/v3_agent_instructions_source.jsonl",
        *[
            f"{fixture_root}/v{version}_minimal_session.jsonl.zstd"
            for version in range(4)
        ],
        f"{fixture_root}/unknown_ignorable_event.jsonl.zstd",
    ]
    assert all(path in matrix_text for path in matrix_evidence)
    evidence = matrix_evidence + [
        f"{fixture_root}/v4_tool_session.jsonl",
        f"{fixture_root}/v4_tool_session.jsonl.zstd",
    ]
    baseline = agent_watch._baseline_type_keys_for_agent(
        "deepseek_harness", evidence
    )
    assert baseline, "DSH monitoring must never pass against an empty fixture baseline"
    assert "assistant/message.data" in baseline
    assert "user/message.data.source.changes" in baseline
    assert PINNED_SOURCE_COMMIT in (
        REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness/manifest.json"
    ).read_text()


def test_dsh_is_public_and_mapped_to_its_matrix_entry() -> None:
    public = json.loads((REPO / "docs/agent-support/public-agents.json").read_text())
    assert {agent["id"] for agent in public["agents"]} >= {"deepseek-harness"}
    assert agent_watch.MATRIX_KEY_FOR_AGENT["deepseek_harness"] == "deepseek_harness"


def test_dsh_upstream_source_includes_prereleases(monkeypatch) -> None:
    captured = {}

    def fake_get(url: str, timeout: int):
        captured["url"] = url
        return [
            {
                "tag_name": "dsh-v0.1.5",
                "published_at": "2026-09-10T00:00:00Z",
                "draft": False,
                "prerelease": False,
            },
            {
                "tag_name": "dsh-v0.1.6-alpha.2",
                "published_at": "2026-09-17T00:00:00Z",
                "draft": False,
                "prerelease": True,
            },
            {
                "tag_name": "dsh-v9.0.0-draft",
                "published_at": "2026-09-18T00:00:00Z",
                "draft": True,
            },
        ]

    monkeypatch.setattr(agent_watch, "_http_get_json", fake_get)
    result = agent_watch._fetch_upstream(
        {"kind": "github_latest_release_including_prerelease",
         "repo": "deepseek-ai/deepseek-harness"},
        timeout=5,
    )

    assert result["ok"] is True
    assert result["version"] == "0.1.6-alpha.2"
    assert result["tag_name"] == "dsh-v0.1.6-alpha.2"
    assert result["prerelease"] is True
    assert captured["url"].endswith("/releases?per_page=20")


def test_dsh_prerelease_advancement_triggers_upstream_drift() -> None:
    verified = agent_watch._extract_dsh_semver("0.1.6-alpha.2")
    upstream = agent_watch._extract_dsh_semver("dsh-v0.1.6-alpha.3")
    assert agent_watch._upstream_newer_than_verified("deepseek_harness", upstream, verified)
    assert not agent_watch._upstream_newer_than_verified(
        "deepseek_harness", "0.1.6-alpha.2", "0.1.6-alpha.3"
    )
    assert agent_watch._compare_dsh_semver("0.1.6", "0.1.6-rc.1") == 1
    assert agent_watch._compare_dsh_semver("0.1.6-alpha.10", "0.1.6-alpha.2") == 1
    assert agent_watch._compare_dsh_semver("0.1.6-alpha.3", verified) == 1


def _write_canonical_fixture(root: Path, filename: str, session_id: str | None = None) -> Path:
    fixture_root = REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
    source = fixture_root / filename
    compressed = filename.endswith(".zstd")
    if compressed:
        raw = source.read_bytes()
        first_frame, _ = agent_watch._dsh_decode_zstd_frame(raw, 0)
        header_rows = list(agent_watch._dsh_record_lines(first_frame))
        assert len(header_rows) == 1
        header = header_rows[0]
    else:
        records = source.read_text(encoding="utf-8").splitlines(keepends=True)
        header = json.loads(records[0])
        if session_id is not None:
            header["id"] = session_id
            records[0] = json.dumps(header, separators=(",", ":")) + "\n"
        raw = "".join(records).encode("utf-8")
    if compressed and session_id is not None:
        raise AssertionError("compressed fixture headers are immutable in this helper")
    if session_id is not None:
        header["id"] = session_id
    target = agent_watch._dsh_canonical_artifact_path(
        root, header, header["version"], compressed
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    if compressed:
        shutil.copyfile(source, target)
    else:
        target.write_bytes(raw)
    return target


def _zstd_compress_frame(payload: bytes) -> bytes:
    library = agent_watch._dsh_zstd_library()
    library.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
    library.ZSTD_compressBound.restype = ctypes.c_size_t
    library.ZSTD_compress.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_int,
    ]
    library.ZSTD_compress.restype = ctypes.c_size_t
    capacity = int(library.ZSTD_compressBound(len(payload)))
    compressed = ctypes.create_string_buffer(capacity)
    source = ctypes.create_string_buffer(payload, len(payload))
    compressed_size = library.ZSTD_compress(
        compressed, capacity, source, len(payload), 3
    )
    assert not library.ZSTD_isError(compressed_size)
    return bytes(compressed[:compressed_size])


def test_dsh_record_reader_sanitizes_oversized_integer_decode_error() -> None:
    payload = b'{"value":' + (b"9" * 5000) + b"}\n"

    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError) as error:
        list(agent_watch._dsh_record_lines(payload))

    assert error.value.code == "invalid_json_record"


def _write_zstd_fixture(
    root: Path, filename: str, *, session_id: str, created_at: int
) -> Path:
    fixture_root = REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
    source = fixture_root / filename
    frames = list(agent_watch._dsh_zstd_frames(source.read_bytes()))
    header_rows = list(agent_watch._dsh_record_lines(frames[0]))
    assert len(header_rows) == 1
    header = header_rows[0]
    header["id"] = session_id
    header["createdAt"] = created_at
    frames[0] = (json.dumps(header, separators=(",", ":")) + "\n").encode()
    target = agent_watch._dsh_canonical_artifact_path(
        root, header, header["version"], True
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"".join(_zstd_compress_frame(frame) for frame in frames))
    return target


def test_dsh_real_session_scan_selects_canonical_zstd_and_nested_schema(tmp_path, monkeypatch) -> None:
    monkeypatch.delenv("DSH_HOME", raising=False)
    root = tmp_path / "sessions"
    session = _write_canonical_fixture(root, "v3_minimal_session.jsonl.zstd")

    fingerprint, contract = agent_watch._dsh_weekly_scan(
        {"default_root": str(root)}, sample_count=5, max_lines=5000
    )

    assert contract["ok"] is True
    assert contract["candidate_sessions"] == 1
    assert contract["encoding"] == "zstd"
    assert fingerprint["file"] == str(session)
    assert fingerprint["generation"] == 3
    assert "assistant/message.data.message" in fingerprint["type_keys"]
    assert "SYNTHETIC" not in repr(fingerprint)


@pytest.mark.parametrize(
    "filename", ["v4_tool_session.jsonl", "v4_tool_session.jsonl.zstd"]
)
def test_dsh_v4_tool_session_proves_every_prebump_evidence_bucket(
    filename: str, tmp_path, monkeypatch
) -> None:
    source = tmp_path / "dsh-session-format-v3-to-v4.js"
    source.write_text(
        "\n".join(
            [
                "function assertReleasedV4Header(",
                "function assertV4RowAdmission(",
                "function assertReleasedV4Relationships(",
                "const SURFACE_TYPES = new Set([",
                'row[\"type\"] === \"developer/message\"',
                'row[\"type\"] !== \"tool/result\"',
            ]
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(agent_watch, "_DSH_V4_VALIDATION_SOURCE", source)
    fixture = (
        REPO
        / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
        / filename
    )

    fingerprint = agent_watch._deepseek_harness_schema_fingerprint(
        fixture, max_lines=5000
    )

    assert fingerprint.get("error") is None
    assert fingerprint["generation"] == 4
    assert fingerprint["unsupported_required_event_types"] == []
    assert fingerprint["evidence_buckets"] == {
        "message": True,
        "tool": True,
        "usage": True,
        "relationship": True,
        "integrity": True,
    }
    assert fingerprint["v4_validation_source"] == {
        "ok": True, "path": str(source), "missing_markers": []
    }
    assert "SYNTHETIC" not in repr(fingerprint)


def test_dsh_v4_prebump_gate_accepts_the_rich_synthetic_fixture(
    tmp_path, monkeypatch
) -> None:
    source = tmp_path / "dsh-session-format-v3-to-v4.js"
    source.write_text(
        "\n".join(
            [
                "function assertReleasedV4Header(",
                "function assertV4RowAdmission(",
                "function assertReleasedV4Relationships(",
                "const SURFACE_TYPES = new Set([",
                'row[\"type\"] === \"developer/message\"',
                'row[\"type\"] !== \"tool/result\"',
            ]
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(agent_watch, "_DSH_V4_VALIDATION_SOURCE", source)
    fixture = (
        REPO
        / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness/"
        "v4_tool_session.jsonl"
    )
    fingerprint = agent_watch._deepseek_harness_schema_fingerprint(
        fixture, max_lines=5000
    )
    baseline = agent_watch._baseline_type_keys_for_agent(
        "deepseek_harness", [str(fixture)]
    )

    diff, matches = agent_watch._prebump_schema_check(
        fingerprint=fingerprint,
        baseline_type_keys=baseline,
        required_evidence_buckets=[
            "message", "tool", "usage", "relationship", "integrity"
        ],
        agent_name="deepseek_harness",
    )

    assert matches is True
    assert diff["missing_required_evidence_buckets"] == []
    assert diff["unknown_only_is_empty"] is True


def test_dsh_v4_validation_source_follows_the_installed_dsh_executable(
    tmp_path, monkeypatch
) -> None:
    package_root = tmp_path / "node_modules/@deepseek-ai/dsh"
    source = package_root / agent_watch._DSH_V4_VALIDATION_SOURCE_RELATIVE
    source.parent.mkdir(parents=True)
    source.write_text("validator", encoding="utf-8")
    executable = package_root / "bin/dsh.js"
    executable.parent.mkdir()
    executable.write_text("#!/usr/bin/env node\n", encoding="utf-8")
    launcher = tmp_path / "bin/dsh"
    launcher.parent.mkdir()
    launcher.symlink_to(executable)
    monkeypatch.setattr(
        agent_watch.shutil, "which", lambda name: str(launcher) if name == "dsh" else None
    )
    monkeypatch.setattr(
        agent_watch,
        "_run_cmd",
        lambda *_args, **_kwargs: pytest.fail("npm fallback must not run"),
    )

    resolved, error = agent_watch._dsh_resolve_v4_validation_source()

    assert error is None
    assert resolved == source


@pytest.mark.parametrize(
    "npm_root",
    [
        "/opt/homebrew/lib/node_modules",
        "/usr/local/lib/node_modules",
        "/Users/test/.nvm/versions/node/v24.1.0/lib/node_modules",
    ],
)
def test_dsh_v4_validation_source_uses_the_active_npm_global_root(
    npm_root: str, monkeypatch
) -> None:
    monkeypatch.setattr(
        agent_watch.shutil,
        "which",
        lambda name: f"/active/bin/{name}" if name in {"dsh", "npm"} else None,
    )
    monkeypatch.setattr(agent_watch.Path, "is_file", lambda _path: False)
    calls = []

    def run(argv, timeout):
        calls.append((argv, timeout))
        return 0, npm_root, ""

    monkeypatch.setattr(agent_watch, "_run_cmd", run)

    resolved, error = agent_watch._dsh_resolve_v4_validation_source()

    assert error is None
    assert resolved == Path(npm_root) / (
        "@deepseek-ai/dsh/node_modules/@deepseek-ai/"
        "dsh-session-format-v3-to-v4/lib/index.js"
    )
    assert calls == [
        (["/active/bin/npm", "root", "--global"], 5)
    ]


def test_dsh_v4_validation_source_reports_bounded_resolution_failure(
    monkeypatch,
) -> None:
    monkeypatch.setattr(agent_watch.shutil, "which", lambda _name: None)
    monkeypatch.setattr(agent_watch, "_DSH_V4_VALIDATION_SOURCE", None)
    monkeypatch.setattr(agent_watch, "_DSH_V4_VALIDATION_SOURCE_RESOLUTION", None)

    contract = agent_watch._dsh_v4_validation_source_contract()

    assert contract == {
        "ok": False,
        "path": None,
        "error": "v4_validation_source_unresolved",
        "resolution_error": "npm_executable_unavailable",
    }


def test_dsh_nested_schema_fingerprint_surfaces_new_data_keys_without_values(tmp_path) -> None:
    fixture_root = REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
    source = fixture_root / "v3_minimal_session.jsonl"
    rows = [json.loads(line) for line in source.read_text(encoding="utf-8").splitlines()]
    assistant = next(row for row in rows if row.get("type") == "assistant/message")
    assistant["data"]["schemaAdded"] = {"nestedShapeAdded": "PRIVATE_VALUE_SENTINEL"}
    sample = tmp_path / "sample.jsonl"
    sample.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

    fingerprint = agent_watch._schema_fingerprint_for_agent(
        "deepseek_harness", sample, max_lines=5000
    )

    assert fingerprint.get("error") is None
    assert "schemaAdded" in fingerprint["type_keys"]["assistant/message.data"]
    assert "nestedShapeAdded" in fingerprint["type_keys"]["assistant/message.data.schemaAdded"]
    assert "PRIVATE_VALUE_SENTINEL" not in repr(fingerprint)


def test_dsh_scan_rejects_mixed_encodings_and_selects_highest_generation(tmp_path, monkeypatch) -> None:
    monkeypatch.delenv("DSH_HOME", raising=False)
    mixed_root = tmp_path / "mixed"
    _write_canonical_fixture(mixed_root, "v3_minimal_session.jsonl.zstd")
    _write_canonical_fixture(mixed_root, "v3_minimal_session.jsonl", session_id="plain-session")

    fingerprint, contract = agent_watch._dsh_weekly_scan(
        {"default_root": str(mixed_root)}, sample_count=5, max_lines=5000
    )

    assert fingerprint is None
    assert contract["ok"] is False
    assert contract["issue_counts"]["mixed_compression_encodings"] == 1
    assert contract["failure_is_actionable"] is True

    generations_root = tmp_path / "generations"
    v2 = _write_canonical_fixture(generations_root, "v2_minimal_session.jsonl", session_id="same-session")
    v3 = _write_canonical_fixture(generations_root, "v3_minimal_session.jsonl", session_id="same-session")
    assert v2.parent == v3.parent

    fingerprint, contract = agent_watch._dsh_weekly_scan(
        {"default_root": str(generations_root)}, sample_count=5, max_lines=5000
    )

    assert contract["ok"] is True
    assert contract["candidate_sessions"] == 1
    assert fingerprint["generation"] == 3
    assert fingerprint["file"].endswith("session.v3.jsonl")


def test_dsh_schema_fingerprint_rejects_sequence_gaps() -> None:
    fixture_root = REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"

    fingerprint = agent_watch._deepseek_harness_schema_fingerprint(
        fixture_root / "malformed_seq_gap.jsonl", max_lines=5000
    )

    assert fingerprint["error"] == "sequence_gap"


def test_dsh_catalog_is_read_from_the_app_and_classifies_unbaselined_shapes() -> None:
    catalog = agent_watch._dsh_app_event_catalog()
    assert len(catalog[3]) == 58
    assert len(catalog[4]) == 59
    assert "tool/call" in catalog[3]
    assert catalog[4] == catalog[3] | {"developer/message"}
    assert "feedback/message-put" in catalog[2]

    fingerprint = {
        "generation": 3,
        "type_counts": {"tool/call": 1, "future/required": 1, "future/ignorable": 1},
        "type_keys": {
            "tool/call": ["data", "seq", "time", "type"],
            "tool/call.data": ["arguments", "callId", "name", "step", "turn"],
            "future/required": ["data", "seq", "time", "type"],
            "future/ignorable": ["data", "ignorable", "seq", "time", "type"],
        },
        "catalog_known_event_types": ["tool/call"],
        "accepted_unknown_ignorable_types": ["future/ignorable"],
        "unsupported_required_event_types": ["future/required"],
    }
    diff = agent_watch._dsh_schema_diff(fingerprint=fingerprint, baseline_type_keys={})
    assert diff["known_but_unbaselined_types"] == ["tool/call"]
    assert diff["accepted_unknown_ignorable_types"] == ["future/ignorable"]
    assert diff["unsupported_required_event_types"] == ["future/required"]
    assert diff["unknown_types"] == ["future/required"]
    assert diff["unknown_keys"]["future/required"] == ["data", "seq", "time", "type"]

    baseline_with_same_shape = {
        "future/required": ["data", "seq", "time", "type"],
    }
    same_shape = agent_watch._dsh_schema_diff(
        fingerprint=fingerprint,
        baseline_type_keys=baseline_with_same_shape,
    )
    assert same_shape["unknown_types"] == ["future/required"]
    assert same_shape["unknown_only_is_empty"] is False

    fingerprint["type_keys"]["tool/call.data"].append("newField")
    changed = agent_watch._dsh_schema_diff(fingerprint=fingerprint, baseline_type_keys={})
    assert changed["unknown_keys"]["tool/call.data"] == ["newField"]
    assert "tool/call.data" in changed["unknown_types"]
    fingerprint["type_keys"]["tool/call.data.futureShape"] = ["childKey"]
    nested = agent_watch._dsh_schema_diff(fingerprint=fingerprint, baseline_type_keys={})
    assert "tool/call.data.futureShape" in nested["unknown_types"]


def test_dsh_valid_surface_op_replacement_shape_is_not_drift() -> None:
    fingerprint = {
        "generation": 3,
        "type_counts": {"tool/result": 1},
        "type_keys": {
            "tool/result": ["data", "seq", "surfaceOp", "time", "type"],
            "tool/result.surfaceOp": ["endSeq", "op", "startSeq"],
        },
        "catalog_known_event_types": ["tool/result"],
        "accepted_unknown_ignorable_types": [],
        "unsupported_required_event_types": [],
    }
    diff = agent_watch._dsh_schema_diff(fingerprint=fingerprint, baseline_type_keys={})
    assert diff["unknown_types"] == []
    assert diff["unknown_keys"] == {}
    assert diff["supported_unbaselined_shapes"]["tool/result.surfaceOp"] == [
        "endSeq", "op", "startSeq",
    ]


def test_dsh_validator_known_agent_instruction_source_shape_is_not_drift() -> None:
    fingerprint = {
        "generation": 3,
        "type_counts": {"user/message": 1},
        "type_keys": {
            "user/message": ["data", "seq", "surfaceOp", "time", "type"],
            "user/message.data": ["content", "id", "role", "source"],
            "user/message.data.source": [
                "baseline", "baselineIdentity", "changes", "form", "kind",
            ],
            "user/message.data.source.changes": ["action", "digest", "path", "scope"],
        },
        "catalog_known_event_types": ["user/message"],
        "accepted_unknown_ignorable_types": [],
        "unsupported_required_event_types": [],
    }

    diff = agent_watch._dsh_schema_diff(fingerprint=fingerprint, baseline_type_keys={})

    assert diff["unknown_types"] == []
    assert diff["unknown_keys"] == {}
    assert diff["supported_unbaselined_shapes"]["user/message.data.source"] == [
        "baseline", "baselineIdentity", "changes", "form", "kind",
    ]
    assert diff["supported_unbaselined_shapes"]["user/message.data.source.changes"] == [
        "action", "digest", "path", "scope",
    ]


def test_dsh_unknown_ignorable_payload_and_tool_result_meta_keys_stay_opaque(tmp_path) -> None:
    fixture_root = REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
    rows = [
        json.loads(line)
        for line in (fixture_root / "unknown_ignorable_event.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    unknown = next(row for row in rows if row.get("ignorable") is True)
    unknown["type"] = "x-future/unknown-ignorable"
    unknown["data"] = {"PRIVATE_KEY_SENTINEL": {"nested": "PRIVATE_VALUE_SENTINEL"}}
    sample = tmp_path / "sample.jsonl"
    sample.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

    fingerprint = agent_watch._deepseek_harness_schema_fingerprint(sample, max_lines=5000)
    assert fingerprint.get("error") is None
    assert fingerprint["accepted_unknown_ignorable_types"] == ["x-future/unknown-ignorable"]
    assert "x-future/unknown-ignorable" in fingerprint["type_keys"]
    assert "x-future/unknown-ignorable.data" not in fingerprint["type_keys"]
    assert "PRIVATE_KEY_SENTINEL" not in repr(fingerprint)
    assert "PRIVATE_VALUE_SENTINEL" not in repr(fingerprint)

    required = dict(unknown)
    required["type"] = "x-future/unknown-required"
    required.pop("ignorable", None)
    required["data"] = {"PRIVATE_REQUIRED_KEY": {"nested": "PRIVATE_REQUIRED_VALUE"}}
    required_rows = [dict(row) for row in rows]
    unknown_index = next(index for index, row in enumerate(required_rows) if row.get("type") == unknown["type"])
    required_rows[unknown_index] = required
    required_path = tmp_path / "required.jsonl"
    required_path.write_text(
        "\n".join(json.dumps(row) for row in required_rows) + "\n",
        encoding="utf-8",
    )
    required_fingerprint = agent_watch._deepseek_harness_schema_fingerprint(
        required_path, max_lines=5000
    )
    assert required_fingerprint.get("error") is None
    assert required_fingerprint["unsupported_required_event_types"] == [
        "x-future/unknown-required",
    ]
    assert required_fingerprint["type_keys"]["x-future/unknown-required"] == sorted(
        required.keys()
    )
    assert "x-future/unknown-required.data" not in required_fingerprint["type_keys"]
    assert "PRIVATE_REQUIRED_KEY" not in repr(required_fingerprint)
    assert "PRIVATE_REQUIRED_VALUE" not in repr(required_fingerprint)

    buckets: dict[str, set[str]] = {}
    agent_watch._dsh_nested_bucket_walk(
        "tool/result",
        {"type": "tool/result", "data": {"turn": 1, "meta": {"PRIVATE_KEY_SENTINEL": "private"}}},
        buckets,
        0,
        4,
    )
    assert "meta" in buckets["tool/result.data"]
    assert "tool/result.data.meta" not in buckets
    assert "PRIVATE_KEY_SENTINEL" not in repr(buckets)


def test_dsh_generation_filename_matches_swift_int_range() -> None:
    max_filename = f"session.v{sys.maxsize}.jsonl"
    overflow_filename = f"session.v{sys.maxsize + 1}.jsonl"
    assert agent_watch._dsh_parse_generation_filename(max_filename) == (sys.maxsize, False)
    assert agent_watch._dsh_parse_generation_filename(overflow_filename) == (None, False)


def test_dsh_stable_read_retries_once_after_a_changed_file(tmp_path, monkeypatch) -> None:
    path = tmp_path / "session.jsonl"
    path.write_bytes(b"first")
    original_read = os.read
    calls = 0

    def change_during_first_read(descriptor: int, size: int) -> bytes:
        nonlocal calls
        data = original_read(descriptor, size)
        if calls == 0:
            path.write_bytes(data + b"-")
        calls += 1
        return data

    monkeypatch.setattr(os, "read", change_during_first_read)
    raw, metadata = agent_watch._dsh_read_stable_bytes(path)
    assert raw == b"first-"
    assert metadata.st_size == len(raw)
    assert calls == 5


def test_dsh_stable_read_caps_bytes_when_file_grows_after_initial_stat(
    tmp_path, monkeypatch
) -> None:
    path = tmp_path / "session.jsonl"
    path.write_bytes(b"start")
    monkeypatch.setattr(agent_watch, "_DSH_MAX_COMPRESSED_BYTES", 16)
    original_read = os.read
    requested_sizes: list[int] = []
    grew = False

    def grow_during_read(descriptor: int, size: int) -> bytes:
        nonlocal grew
        requested_sizes.append(size)
        if not grew:
            grew = True
            append_descriptor = os.open(path, os.O_WRONLY | os.O_APPEND)
            try:
                os.write(append_descriptor, b"x" * 100)
            finally:
                os.close(append_descriptor)
        return original_read(descriptor, size)

    monkeypatch.setattr(os, "read", grow_during_read)
    with pytest.raises(
        agent_watch._DeepSeekHarnessMonitorError, match="compressed_size_limit"
    ):
        agent_watch._dsh_read_stable_bytes(path)

    assert requested_sizes == [17]


def test_dsh_zstd_expansion_limit_is_checked_during_streaming_decode() -> None:
    library = agent_watch._dsh_zstd_library()
    library.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
    library.ZSTD_compressBound.restype = ctypes.c_size_t
    library.ZSTD_compress.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_int,
    ]
    library.ZSTD_compress.restype = ctypes.c_size_t

    decoded = b"\0" * (128 * 1024) + random.Random(41).randbytes(1024 * 1024)
    capacity = int(library.ZSTD_compressBound(len(decoded)))
    compressed = ctypes.create_string_buffer(capacity)
    source = ctypes.create_string_buffer(decoded, len(decoded))
    compressed_size = library.ZSTD_compress(
        compressed, capacity, source, len(decoded), 3
    )
    assert not library.ZSTD_isError(compressed_size)
    frame = bytes(compressed[:compressed_size])

    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError) as error:
        agent_watch._dsh_decode_zstd_frame(frame, 0)
    assert error.value.code == "decoded_expansion_limit"


def test_dsh_directory_discovery_stops_at_the_global_entry_budget(tmp_path, monkeypatch) -> None:
    monkeypatch.delenv("DSH_HOME", raising=False)
    root = tmp_path / "bounded-sessions"
    for index in range(3):
        _write_canonical_fixture(root, "v3_minimal_session.jsonl", session_id=f"bounded-{index}")
    monkeypatch.setattr(agent_watch, "_DSH_MAX_DISCOVERY_ENTRIES", 3)
    monkeypatch.setattr(
        Path,
        "iterdir",
        lambda _path: pytest.fail("DSH discovery must stream directory entries"),
    )

    fingerprint, contract = agent_watch._dsh_weekly_scan(
        {"default_root": str(root)}, sample_count=5, max_lines=5000
    )

    assert fingerprint is not None
    assert contract["candidate_sessions"] == 1
    assert contract["issue_counts"]["session_discovery_entry_limit"] == 1
    assert contract["ok"] is False


def test_dsh_artifact_scan_stops_at_the_session_budget(tmp_path, monkeypatch) -> None:
    monkeypatch.delenv("DSH_HOME", raising=False)
    root = tmp_path / "bounded-artifacts"
    for index in range(3):
        _write_canonical_fixture(root, "v3_minimal_session.jsonl", session_id=f"artifact-{index}")
    monkeypatch.setattr(agent_watch, "_DSH_MAX_SESSIONS_TO_INSPECT", 1)

    fingerprint, contract = agent_watch._dsh_weekly_scan(
        {"default_root": str(root)}, sample_count=5, max_lines=5000
    )

    assert fingerprint is not None
    assert contract["candidate_sessions"] == 1
    assert contract["issue_counts"]["session_scan_limit"] == 1
    assert contract["ok"] is False


def test_dsh_header_discovery_reads_only_headers_before_sample_selection(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.delenv("DSH_HOME", raising=False)
    root = tmp_path / "large-unsampled-body"
    selected = _write_canonical_fixture(
        root, "v3_minimal_session.jsonl", session_id="a-selected"
    )
    unsampled = _write_canonical_fixture(
        root, "v3_minimal_session.jsonl", session_id="z-unsampled"
    )

    for path, created_at in ((selected, 2_000_000_000_000), (unsampled, 1_900_000_000_000)):
        records = path.read_bytes().splitlines(keepends=True)
        header = json.loads(records[0])
        header["createdAt"] = created_at
        path.write_bytes(
            (json.dumps(header, separators=(",", ":")) + "\n").encode()
            + b"".join(records[1:])
        )
    with unsampled.open("ab") as handle:
        handle.write(b"x" * (2 * 1024 * 1024))
    monkeypatch.setattr(agent_watch, "_DSH_MAX_COMPRESSED_BYTES", 64 * 1024)

    original_read = agent_watch._dsh_read_stable_bytes

    def reject_unsampled_full_read(path: Path):
        if path == unsampled:
            pytest.fail("unsampled DSH body must not be fully read")
        return original_read(path)

    monkeypatch.setattr(agent_watch, "_dsh_read_stable_bytes", reject_unsampled_full_read)
    fingerprint, contract = agent_watch._dsh_weekly_scan(
        {"default_root": str(root)}, sample_count=1, max_lines=5000
    )

    assert contract["ok"] is True
    assert contract["candidate_sessions"] == 2
    assert contract["sampled_sessions"] == 1
    assert fingerprint["file"] == str(selected)
    assert fingerprint["sampled_files"] == [str(selected)]
    assert contract["header_scan_bytes"] <= 2 * agent_watch._DSH_HEADER_READ_CHUNK_BYTES


def test_dsh_zstd_header_scan_stops_after_the_first_frame(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.delenv("DSH_HOME", raising=False)
    root = tmp_path / "large-unsampled-zstd"
    selected = _write_zstd_fixture(
        root,
        "v3_minimal_session.jsonl.zstd",
        session_id="a-selected-zstd",
        created_at=2_000_000_000_000,
    )
    unsampled = _write_zstd_fixture(
        root,
        "v3_minimal_session.jsonl.zstd",
        session_id="z-unsampled-zstd",
        created_at=1_900_000_000_000,
    )
    with unsampled.open("ab") as handle:
        handle.write(_zstd_compress_frame(random.Random(52).randbytes(128 * 1024)))
    monkeypatch.setattr(agent_watch, "_DSH_MAX_COMPRESSED_BYTES", 64 * 1024)

    original_read = agent_watch._dsh_read_stable_bytes

    def reject_unsampled_full_read(path: Path):
        if path == unsampled:
            pytest.fail("unsampled DSH zstd frames must not be fully read")
        return original_read(path)

    monkeypatch.setattr(agent_watch, "_dsh_read_stable_bytes", reject_unsampled_full_read)
    fingerprint, contract = agent_watch._dsh_weekly_scan(
        {"default_root": str(root)}, sample_count=1, max_lines=5000
    )

    assert contract["ok"] is True
    assert contract["candidate_sessions"] == 2
    assert contract["sampled_sessions"] == 1
    assert fingerprint["file"] == str(selected)
    assert contract["header_scan_bytes"] <= 2 * agent_watch._DSH_HEADER_READ_CHUNK_BYTES


@pytest.mark.parametrize("compressed", [False, True])
def test_dsh_fingerprint_keeps_early_drift_past_max_lines(
    tmp_path, compressed: bool
) -> None:
    fixture_root = REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
    fixture_rows = [
        json.loads(line)
        for line in (fixture_root / "v3_minimal_session.jsonl").read_text().splitlines()
    ]
    header = fixture_rows[0]
    user_event = next(row for row in fixture_rows if row.get("type") == "user/message")
    user_event = json.loads(json.dumps(user_event))
    user_event["seq"] = 0
    user_event["time"] = 0
    user_event["surfaceOp"] = "append"
    user_event.pop("sourceEventSeqs", None)
    user_event["data"]["source"]["monitorAddedKey"] = "PRIVATE_VALUE_SENTINEL"
    unknown_required = {
        "type": "future/required",
        "seq": 1,
        "time": 1,
        "data": {"PRIVATE_REQUIRED_KEY": "PRIVATE_REQUIRED_VALUE"},
    }
    tail = [
        {
            "type": "session/end-seed",
            "seq": sequence,
            "time": sequence,
            "data": {},
        }
        for sequence in range(2, 102)
    ]
    header_line = (json.dumps(header, separators=(",", ":")) + "\n").encode()
    event_bytes = b"".join(
        (json.dumps(row, separators=(",", ":")) + "\n").encode()
        for row in [user_event, unknown_required, *tail]
    )
    path = tmp_path / ("session.v3.jsonl.zstd" if compressed else "session.v3.jsonl")
    if compressed:
        path.write_bytes(
            _zstd_compress_frame(header_line) + _zstd_compress_frame(event_bytes)
        )
    else:
        path.write_bytes(header_line + event_bytes)

    fingerprint, _ = agent_watch._dsh_parse_artifact(path, max_lines=2)

    assert fingerprint["parsed_lines"] == 103
    assert fingerprint["type_counts"]["session/end-seed"] == 100
    assert "monitorAddedKey" in fingerprint["type_keys"]["user/message.data.source"]
    assert fingerprint["unsupported_required_event_types"] == ["future/required"]
    assert "PRIVATE_VALUE_SENTINEL" not in repr(fingerprint)
    assert "PRIVATE_REQUIRED_KEY" not in repr(fingerprint)
    assert "PRIVATE_REQUIRED_VALUE" not in repr(fingerprint)


def test_dsh_v3_surface_metadata_matches_app_admission_rules() -> None:
    fixture_root = REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
    rows = [
        json.loads(line)
        for line in (fixture_root / "v3_minimal_session.jsonl").read_text().splitlines()
    ]
    user_data = json.loads(
        json.dumps(next(row["data"] for row in rows if row.get("type") == "user/message"))
    )
    valid = {
        "type": "user/message",
        "seq": 2,
        "time": 2,
        "data": user_data,
        "surfaceOp": "append",
    }
    assert agent_watch._dsh_validate_row(valid, 3, 2) == 1

    valid_tool_result = {
        "type": "tool/result",
        "seq": 2,
        "time": 2,
        "data": {
            "turn": 1,
            "step": 1,
            "message": {
                "id": "tool-result-message",
                "role": "user",
                "content": [{"type": "tool-result", "toolCallId": "call-1"}],
                "source": {"kind": "tool", "callId": "call-1"},
            },
        },
        "surfaceOp": "append",
    }
    assert agent_watch._dsh_validate_row(valid_tool_result, 3, 2) == 1

    wrong_tool_result_role = json.loads(json.dumps(valid_tool_result))
    wrong_tool_result_role["data"]["message"]["role"] = "tool"
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_surface_payload"):
        agent_watch._dsh_validate_row(wrong_tool_result_role, 3, 2)

    missing_surface = dict(valid)
    missing_surface.pop("surfaceOp")
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_event_envelope"):
        agent_watch._dsh_validate_row(missing_surface, 3, 2)

    legacy_replace = dict(valid, surfaceOp={"op": "replace", "start": 0, "end": 1})
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_event_envelope"):
        agent_watch._dsh_validate_row(legacy_replace, 3, 2)

    current_sequence_reference = dict(
        valid, surfaceOp={"op": "replace", "startSeq": 0, "endSeq": 2}
    )
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_event_envelope"):
        agent_watch._dsh_validate_row(current_sequence_reference, 3, 2)

    empty_sources = dict(valid, sourceEventSeqs=[])
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_event_reference"):
        agent_watch._dsh_validate_row(empty_sources, 3, 2)

    duplicate_sources = dict(valid, sourceEventSeqs=[0, 0])
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_event_reference"):
        agent_watch._dsh_validate_row(duplicate_sources, 3, 2)

    malformed_payload = dict(
        valid,
        data={**user_data, "content": "PRIVATE_VALUE_SENTINEL"},
    )
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_surface_payload"):
        agent_watch._dsh_validate_row(malformed_payload, 3, 2)

    system_data = json.loads(
        json.dumps(next(row["data"] for row in rows if row.get("type") == "system/message"))
    )
    valid_system = {
        "type": "system/message",
        "seq": 2,
        "time": 2,
        "data": system_data,
        "surfaceOp": "append",
    }
    assert agent_watch._dsh_validate_row(valid_system, 3, 2) == 1

    system_extra_data = json.loads(json.dumps(valid_system))
    system_extra_data["data"]["extra"] = True
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_surface_payload"):
        agent_watch._dsh_validate_row(system_extra_data, 3, 2)

    system_extra_message_key = json.loads(json.dumps(valid_system))
    system_extra_message_key["data"]["message"]["extra"] = True
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_surface_payload"):
        agent_watch._dsh_validate_row(system_extra_message_key, 3, 2)

    system_invalid_source = json.loads(json.dumps(valid_system))
    system_invalid_source["data"]["message"]["source"]["unexpected"] = True
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_surface_payload"):
        agent_watch._dsh_validate_row(system_invalid_source, 3, 2)

    system_invalid_content = json.loads(json.dumps(valid_system))
    system_invalid_content["data"]["message"]["content"] = [
        {"type": "text", "body": "not the released text-block shape"}
    ]
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_surface_payload"):
        agent_watch._dsh_validate_row(system_invalid_content, 3, 2)

    valid_tool_error = json.loads(json.dumps(valid_tool_result))
    valid_tool_error["data"]["error"] = {"app-defined": "error metadata"}
    valid_tool_error["data"]["message"]["content"] = [
        {"type": "tool-result", "toolCallId": "call-1", "isError": True}
    ]
    assert agent_watch._dsh_validate_row(valid_tool_error, 3, 2) == 1

    tool_error_without_marker = json.loads(json.dumps(valid_tool_error))
    tool_error_without_marker["data"]["message"]["content"][0]["isError"] = False
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_surface_payload"):
        agent_watch._dsh_validate_row(tool_error_without_marker, 3, 2)

    tool_error_with_null_marker = json.loads(json.dumps(valid_tool_error))
    tool_error_with_null_marker["data"]["message"]["content"][0]["isError"] = None
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_surface_payload"):
        agent_watch._dsh_validate_row(tool_error_with_null_marker, 3, 2)

    log_with_surface_fields = {
        "type": "tool/call",
        "seq": 2,
        "time": 2,
        "data": {},
        "surfaceOp": "append",
    }
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_event_envelope"):
        agent_watch._dsh_validate_row(log_with_surface_fields, 3, 2)

    opaque_ignorable = {
        "type": "future/ignorable",
        "seq": 2,
        "time": 2,
        "data": {"PRIVATE_KEY_SENTINEL": "PRIVATE_VALUE_SENTINEL"},
        "ignorable": True,
        "sourceEventSeqs": [],
        "surfaceOp": {"op": "replace", "start": 0, "end": 1},
    }
    assert agent_watch._dsh_validate_row(opaque_ignorable, 3, 2) == 1

    semantically_invalid_opaque = json.loads(json.dumps(opaque_ignorable))
    semantically_invalid_opaque["sourceEventSeqs"] = [2]
    semantically_invalid_opaque["surfaceOp"] = {
        "op": "replace",
        "startSeq": 2,
        "endSeq": 2,
    }
    assert agent_watch._dsh_validate_row(semantically_invalid_opaque, 3, 2) == 1

    malformed_opaque_envelope = json.loads(json.dumps(opaque_ignorable))
    malformed_opaque_envelope["sourceEventSeqs"] = "future opaque value"
    with pytest.raises(agent_watch._DeepSeekHarnessMonitorError, match="invalid_event_reference"):
        agent_watch._dsh_validate_row(malformed_opaque_envelope, 3, 2)

    legacy_v2 = {
        "type": "user/message",
        "seq": 2,
        "time": 2,
        "data": user_data,
        "surfaceOp": {"op": "replace", "start": 0, "end": 1},
    }
    assert agent_watch._dsh_validate_row(legacy_v2, 2, 2) == 1


@pytest.mark.parametrize("generation", [0, 1, 2])
def test_dsh_legacy_request_context_requires_positive_integer_window(generation: int) -> None:
    valid = {
        "type": "request/context",
        "seq": 2,
        "time": 2,
        "data": {"provider": "synthetic", "model": "model", "contextWindow": 8192},
    }
    assert agent_watch._dsh_validate_row(valid, generation, 2) == 1

    for invalid_window in (0, -1, 1.5, True, "8192"):
        malformed = json.loads(json.dumps(valid))
        malformed["data"]["contextWindow"] = invalid_window
        with pytest.raises(
            agent_watch._DeepSeekHarnessMonitorError,
            match="invalid_legacy_payload",
        ) as error:
            agent_watch._dsh_validate_row(malformed, generation, 2)
        assert "synthetic" not in str(error.value)
        assert "8192" not in str(error.value)


@pytest.mark.parametrize(
    ("event_type", "valid_data", "field", "invalid_value"),
    [
        ("approval/policy", {"policy": "ask"}, "policy", "sometimes"),
        ("plan/mode", {"active": True}, "active", 1),
        ("sandbox/mode", {"mode": "read-only"}, "mode", "private-mode-sentinel"),
    ],
)
def test_dsh_legacy_shared_scalars_and_enums_fail_closed(
    event_type: str,
    valid_data: dict,
    field: str,
    invalid_value,
) -> None:
    valid = {"type": event_type, "seq": 2, "time": 2, "data": valid_data}
    assert agent_watch._dsh_validate_row(valid, 2, 2) == 1

    malformed = json.loads(json.dumps(valid))
    malformed["data"][field] = invalid_value
    with pytest.raises(
        agent_watch._DeepSeekHarnessMonitorError,
        match="invalid_legacy_payload",
    ) as error:
        agent_watch._dsh_validate_row(malformed, 2, 2)
    assert str(invalid_value) not in str(error.value)


def test_dsh_valid_unported_legacy_payload_families_remain_accepted() -> None:
    rows = [
        {
            "type": "feedback/record",
            "seq": 2,
            "time": 2,
            "data": {"text": "private-feedback-sentinel"},
        },
        {
            "type": "turn/end",
            "seq": 2,
            "time": 2,
            "data": {"turn": 1, "reason": {"kind": "aborted", "reason": {"kind": "user"}}},
        },
        {
            "type": "request/header",
            "seq": 2,
            "time": 2,
            "data": {
                "header": {
                    "config": {
                        "provider": "synthetic-provider",
                        "model": "synthetic-model",
                        "stop": ["private-stop-sentinel"],
                    },
                    "adapterDefaults": {"maxTokens": True},
                },
                "reason": "initial",
            },
        },
        {
            "type": "user/message",
            "seq": 2,
            "time": 2,
            "data": {
                "id": "synthetic-message",
                "role": "user",
                "content": [{
                    "type": "image",
                    "attachment": {
                        "attachmentId": "synthetic-attachment",
                        "mediaType": "image/png",
                        "bytes": 4,
                        "width": 1,
                        "height": 1,
                    },
                }],
                "source": {"kind": "plugin", "plugin": "synthetic-plugin"},
            },
            "surfaceOp": "append",
        },
    ]

    for row in rows:
        assert agent_watch._dsh_validate_row(row, 2, 2) == 1


def test_dsh_unported_legacy_shapes_fingerprint_types_without_values(tmp_path) -> None:
    rows = [
        {
            "type": "session",
            "version": 2,
            "id": "synthetic-session",
            "createdAt": 1_800_000_000_000,
            "isSeeded": False,
            "delegationDepth": 0,
        },
        {
            "type": "feedback/record",
            "seq": 0,
            "time": 0,
            "data": {"text": "private-feedback-sentinel"},
        },
        {
            "type": "turn/end",
            "seq": 1,
            "time": 1,
            "data": {"turn": 1, "reason": {"kind": "aborted", "reason": {"kind": "user"}}},
        },
    ]
    path = tmp_path / "session.v2.jsonl"
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    fingerprint, _ = agent_watch._dsh_parse_artifact(path, max_lines=100)

    assert fingerprint["type_keys"]["feedback/record.data"] == ["text"]
    assert fingerprint["type_keys"]["turn/end.data.reason"] == ["kind", "reason"]
    assert "private-feedback-sentinel" not in repr(fingerprint)


def test_dsh_freshness_uses_source_created_at_and_ignores_artifact_mtime() -> None:
    now = 1_800_000_000.0
    binary_mtime = now - 200
    fresh = agent_watch._dsh_source_sample_freshness(
        {
            "source_created_at_epoch": now - 100,
            "artifact_mtime_epoch": now - 100_000,
            "artifact_mtime_utc": "old-file-time",
        },
        cli_binary_path="/usr/local/bin/dsh",
        cli_binary_mtime=binary_mtime,
        freshness_window_seconds=14 * 86400,
        now_epoch=now,
    )
    assert fresh["fresh_for_compatibility"] is True
    assert fresh["sample_older_than_cli"] is False
    assert fresh["artifact_mtime_utc"] == "old-file-time"
    assert fresh["source_timestamp_authenticated"] is False

    copied_old = agent_watch._dsh_source_sample_freshness(
        {
            "source_created_at_epoch": now - 300,
            "artifact_mtime_epoch": now,
            "artifact_mtime_utc": "new-file-time",
        },
        cli_binary_path="/usr/local/bin/dsh",
        cli_binary_mtime=binary_mtime,
        freshness_window_seconds=14 * 86400,
        now_epoch=now,
    )
    assert copied_old["is_stale"] is True
    assert copied_old["stale_reason"] == "sample_older_than_cli"
    assert copied_old["fresh_for_compatibility"] is False


def test_dsh_historical_rich_union_does_not_hide_thin_fresh_coverage() -> None:
    thin_diff = {
        "coverage_ratio": 0.1,
        "observed_event_count": 2,
        "unknown_only_is_empty": True,
    }
    rich_history_diff = {
        "coverage_ratio": 1.0,
        "observed_event_count": 500,
        "unknown_only_is_empty": True,
    }
    assessment = agent_watch._build_compatibility_assessment(
        verified="0.1.6-alpha.2",
        installed="0.1.6-alpha.2",
        upstream="0.1.7-rc.2",
        upstream_sources_configured=True,
        upstream_errors=[],
        installed_newer_than_verified=False,
        upstream_newer_than_verified=True,
        monitoring_failed=False,
        schema_matches_baseline=True,
        schema_diff=thin_diff,
        sample_freshness={"is_stale": False, "stale_reason": None},
        fresh_evidence_source=None,
        probe_failed=False,
        real_session_driver_configured=False,
        weekly_schema_diff=rich_history_diff,
        fresh_schema_diff=thin_diff,
        fresh_schema_required=True,
    )

    assert assessment["verdict"] == "blocked_thin_sample"
    assert assessment["supports_installed"] is False
