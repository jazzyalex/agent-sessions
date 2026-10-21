"""Antigravity weekly sampling covers both brain roots (CLI and desktop app)."""

import json
import os
from pathlib import Path

import agent_watch
import capture_latest_agent_sessions as capture

REPO = Path(__file__).resolve().parents[2]
CONFIG = REPO / "docs/agent-support/agent-watch-config.json"
TRANSCRIPT = ".system_generated/logs/transcript.jsonl"


def _weekly_cfg() -> dict:
    return json.loads(CONFIG.read_text(encoding="utf-8"))["agents"]["antigravity"]["weekly"]


def _transcript(root: Path, conversation: str, mtime: float) -> Path:
    path = root / conversation / TRANSCRIPT
    path.parent.mkdir(parents=True)
    path.write_text('{"step_index":0,"type":"USER_INPUT","source":"USER_EXPLICIT"}\n', encoding="utf-8")
    os.utime(path, (mtime, mtime))
    return path


def test_weekly_samples_the_desktop_brain_root_too():
    roots = _weekly_cfg()["local_schema"]["roots"]
    assert "~/.gemini/antigravity-cli/brain" in roots
    assert "~/.gemini/antigravity/brain" in roots


def test_discovery_contract_accepts_cli_and_desktop_transcripts_only():
    contract = _weekly_cfg()["discovery_path_contract"]
    home = "/Users/someone"
    for path in (
        f"{home}/.gemini/antigravity-cli/brain/af24-cli/{TRANSCRIPT}",
        f"{home}/.gemini/antigravity/brain/107f-desktop/{TRANSCRIPT}",
    ):
        assert agent_watch._check_discovery_path_contract(path, contract)["ok"], path
    for path in (
        f"{home}/.gemini/antigravity/brain/107f-desktop/task.md",
        f"{home}/.gemini/antigravity/brain/107f-desktop/.system_generated/logs/transcript_full.jsonl",
        f"{home}/.gemini/tmp/abc/chats/session.jsonl",
    ):
        assert not agent_watch._check_discovery_path_contract(path, contract)["ok"], path


def test_newest_sample_unions_both_roots_newest_first(tmp_path):
    cli_root = tmp_path / ".gemini/antigravity-cli/brain"
    desktop_root = tmp_path / ".gemini/antigravity/brain"
    old_cli = _transcript(cli_root, "cli-old", 1_000)
    desktop = _transcript(desktop_root, "desktop-new", 3_000)
    cli = _transcript(cli_root, "cli-mid", 2_000)
    # Legacy desktop artifacts and the full transcript beside it are not samples.
    (desktop_root / "md-only").mkdir()
    (desktop_root / "md-only" / "task.md").write_text("# Task\n", encoding="utf-8")
    (desktop.parent / "transcript_full.jsonl").write_text("{}\n", encoding="utf-8")

    glob = _weekly_cfg()["local_schema"]["glob"]
    sampled = agent_watch._newest_files([str(cli_root), str(desktop_root)], glob, 5)

    assert sampled == [desktop, cli, old_cli]


def test_capture_probe_copies_the_newest_transcript_across_both_roots(tmp_path, monkeypatch):
    home = tmp_path / "home"
    _transcript(home / ".gemini/antigravity-cli/brain", "cli-old", 1_000)
    _transcript(home / ".gemini/antigravity/brain", "desktop-new", 2_000)
    monkeypatch.setattr(capture.Path, "home", staticmethod(lambda: home))

    results = capture.capture_antigravity(tmp_path / "out")

    assert len(results) == 1
    assert results[0].source.parent.parent.parent.name == "desktop-new"
    assert results[0].destination.name == "desktop-new.transcript.jsonl"
