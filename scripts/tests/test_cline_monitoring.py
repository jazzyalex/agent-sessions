"""Cline manifest/transcript monitoring and discovery-contract coverage."""

import json
import os
from pathlib import Path

import agent_watch


def _cline_pair(tmp_path: Path, *, session_id: str = "sess-1", write_messages: bool = True) -> Path:
    session = tmp_path / ".cline" / "data" / "sessions" / session_id
    session.mkdir(parents=True)
    manifest = session / f"{session_id}.json"
    manifest.write_text(json.dumps({
        "version": 1,
        "session_id": session_id,
        "source": "cli",
        "metadata": {"sessionHistoryOrigin": {"version": "3.0.62"}},
        "messages_path": "/stale/export/path.json",
    }))
    if write_messages:
        (session / f"{session_id}.messages.json").write_text(json.dumps({
            "version": 1,
            "sessionId": session_id,
            "origin": {"source": "cli"},
            "messages": [
                {
                    "role": "assistant",
                    "modelInfo": {"id": "m"},
                    "content": [{"type": "text", "text": "hello"}],
                }
            ],
        }))
    return manifest


def test_cline_fingerprint_covers_manifest_and_adjacent_transcript(tmp_path):
    manifest = _cline_pair(tmp_path)
    result = agent_watch._cline_session_schema_fingerprint(manifest)

    assert result["manifest_error"] is None
    assert result["transcript_error"] is None
    assert "manifest" in result["type_keys"]
    assert "manifest.metadata.sessionHistoryOrigin" in result["type_keys"]
    assert "message.assistant" in result["type_keys"]
    assert "content.text" in result["type_keys"]
    assert result["transcript_file"].endswith("sess-1.messages.json")
    assert result["contract_errors"] == []


def test_cline_contract_expands_stem_and_requires_companion(tmp_path):
    manifest = _cline_pair(tmp_path)
    contract = {
        "description": "cline layout",
        "patterns": [r"/sessions/([^/]+)/\1\.json$"],
        "required_companion_files": [
            {"path": "{stem}.messages.json", "must_parse": "cline_messages_v1"}
        ],
    }

    present = agent_watch._check_discovery_path_contract(str(manifest), contract)
    assert present["ok"] is True
    companion = present["required_companion_files"][0]
    assert companion["rendered_path"] == "sess-1.messages.json"

    manifest.with_name("sess-1.messages.json").unlink()
    missing = agent_watch._check_discovery_path_contract(str(manifest), contract)
    assert missing["ok"] is False
    assert missing["required_companion_files"][0]["error"] == "missing"


def test_cline_contract_rejects_mismatched_identity_and_future_version(tmp_path):
    manifest = _cline_pair(tmp_path)
    messages = manifest.with_name("sess-1.messages.json")
    contract = {
        "patterns": [r"/sessions/([^/]+)/\1\.json$"],
        "required_companion_files": [
            {"path": "{stem}.messages.json", "must_parse": "cline_messages_v1"}
        ],
    }

    transcript = json.loads(messages.read_text())
    transcript["sessionId"] = "some-other-session"
    messages.write_text(json.dumps(transcript))
    mismatch = agent_watch._check_discovery_path_contract(str(manifest), contract)
    assert mismatch["ok"] is False
    assert mismatch["required_companion_files"][0]["error"] == "session_id_mismatch"

    transcript["sessionId"] = "sess-1"
    transcript["version"] = 2
    messages.write_text(json.dumps(transcript))
    future = agent_watch._check_discovery_path_contract(str(manifest), contract)
    assert future["ok"] is False
    assert future["required_companion_files"][0]["error"] == "unsupported_contract_version"


def test_cline_environment_root_is_authoritative_for_monitoring():
    configured = ["$CLINE_DATA_DIR/sessions", "~/.cline/data/sessions"]
    assert agent_watch._cline_effective_roots(
        configured, {"CLINE_DATA_DIR": "/Volumes/cline-isolated"}
    ) == ["/Volumes/cline-isolated/sessions"]
    assert agent_watch._cline_effective_roots(configured, {}) == ["~/.cline/data/sessions"]


def test_cline_recency_uses_the_manifest_messages_pair(tmp_path):
    older_manifest = _cline_pair(tmp_path, session_id="older-manifest")
    newer_manifest = _cline_pair(tmp_path, session_id="newer-manifest")
    older_messages = older_manifest.with_name("older-manifest.messages.json")
    newer_messages = newer_manifest.with_name("newer-manifest.messages.json")
    os.utime(older_manifest, (100, 100))
    os.utime(older_messages, (300, 300))
    os.utime(newer_manifest, (200, 200))
    os.utime(newer_messages, (200, 200))

    sessions_root = tmp_path / ".cline" / "data" / "sessions"
    newest = agent_watch._newest_cline_files(
        [str(sessions_root)], "*/*.json", 2, exclude_globs=["*.messages.json"]
    )
    assert newest == [older_manifest, newer_manifest]
    assert agent_watch._cline_pair_stat(older_manifest) == (300, older_manifest.stat().st_size + older_messages.stat().st_size)


def test_real_cline_config_is_monitored_against_fixture_baseline():
    repo = Path(__file__).resolve().parents[2]
    config = json.loads((repo / "docs/agent-support/agent-watch-config.json").read_text())
    cline = config["agents"]["cline"]

    assert cline["cadence"]["weekly"] is True
    assert cline["weekly"]["local_schema"]["kind"] == "cline_latest_session"
    companion = cline["weekly"]["discovery_path_contract"]["required_companion_files"][0]
    assert companion["path"] == "{stem}.messages.json"
    assert companion["must_parse"] == "cline_messages_v1"
    assert agent_watch.MATRIX_KEY_FOR_AGENT["cline"] == "cline"
    matrix_versions = agent_watch._read_verified_versions_from_matrix(
        repo / "docs/agent-support/agent-support-matrix.yml"
    )
    assert agent_watch._verified_versions_by_agent(matrix_versions)["cline"] == "3.0.62"

    manifests = [
        str(repo / "Resources/Fixtures/stage0/agents/cline/cli_tool/cline-cli-tool.json"),
        str(repo / "Resources/Fixtures/stage0/agents/cline/desktop_continued/cline-desktop-continued.json"),
    ]
    baseline = agent_watch._baseline_type_keys_for_agent("cline", manifests)
    assert "manifest" in baseline
    assert "message.user" in baseline
    assert "message.assistant" in baseline
