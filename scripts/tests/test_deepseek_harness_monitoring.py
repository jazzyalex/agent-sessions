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
