import json
from pathlib import Path

from scripts import agent_watch
from scripts.verify_dsh_fixture_manifest import PINNED_SOURCE_COMMIT, verify


REPO = Path(__file__).resolve().parents[2]


def test_dsh_fixture_manifest_and_monitoring_baseline_are_nonempty() -> None:
    assert verify() == 0

    config = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    dsh = config["agents"]["deepseek_harness"]
    assert dsh["verified_version_source"].endswith("agents.deepseek_harness.max_verified_version")
    assert dsh["weekly"]["local_schema"]["roots"] == [
        "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
    ]
    assert dsh["weekly"]["probes"][0]["argv"] == [
        "./scripts/verify_dsh_fixture_manifest.py"
    ]

    matrix_text = (REPO / "docs/agent-support/agent-support-matrix.yml").read_text()
    fixture_root = "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
    evidence = [
        f"{fixture_root}/v{version}_minimal_session.jsonl"
        for version in range(4)
    ] + [f"{fixture_root}/unknown_ignorable_event.jsonl"]
    assert all(path in matrix_text for path in evidence)
    baseline = agent_watch._baseline_type_keys_for_agent(
        "deepseek_harness", evidence
    )
    assert baseline, "DSH monitoring must never pass against an empty fixture baseline"
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
