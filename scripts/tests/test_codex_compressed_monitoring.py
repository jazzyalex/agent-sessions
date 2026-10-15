# scripts/tests/test_codex_compressed_monitoring.py
"""Codex `local_thread_store_compression` keeps idle rollouts as `rollout-*.jsonl.zst`.

The monitor must read them, count each logical rollout once (plain file preferred,
as in Codex and the app), skip Codex's `.tmp` files, and skip an unreadable `.zst`
instead of aborting the run.
"""
import json
import os
from pathlib import Path

import pytest

import agent_watch

zstd = pytest.importorskip("compression.zstd")

GLOB = "**/rollout-*.jsonl*"
EXCLUDES = ["*.tmp"]


def _lines(session_id: str) -> bytes:
    rows = [
        {"type": "session_meta", "payload": {"id": session_id}},
        {"type": "response_item", "payload": {"type": "message"}},
    ]
    return "".join(json.dumps(r) + "\n" for r in rows).encode()


def _write(path: Path, data: bytes, mtime: float) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    os.utime(path, (mtime, mtime))
    return path


def _day(root: Path) -> Path:
    return root / "2026" / "10" / "01"


def test_compressed_only_rollout_is_sampled_and_decoded(tmp_path):
    zst = _write(_day(tmp_path) / "rollout-a.jsonl.zst", zstd.compress(_lines("a")), 1_000)
    found = agent_watch._newest_files([str(tmp_path)], GLOB, 5, exclude_globs=EXCLUDES)
    assert found == [zst]
    assert agent_watch._jsonl_contains_any_type(zst, {"session_meta"}, max_lines=10)


def test_plain_only_rollout_is_sampled(tmp_path):
    plain = _write(_day(tmp_path) / "rollout-a.jsonl", _lines("a"), 1_000)
    assert agent_watch._newest_files([str(tmp_path)], GLOB, 5, exclude_globs=EXCLUDES) == [plain]


def test_both_forms_count_once_and_plain_wins(tmp_path):
    day = _day(tmp_path)
    plain = _write(day / "rollout-a.jsonl", _lines("a"), 1_000)
    # The compressed copy is newer on disk; it must still not take a second slot.
    _write(day / "rollout-a.jsonl.zst", zstd.compress(_lines("a")), 2_000)
    other = _write(day / "rollout-b.jsonl", _lines("b"), 500)

    found = agent_watch._newest_files([str(tmp_path)], GLOB, 5, exclude_globs=EXCLUDES)
    assert found == [plain, other]
    with_types = agent_watch._newest_files_with_types(
        [str(tmp_path)], GLOB, ["session_meta"], 5, 10, exclude_globs=EXCLUDES
    )
    assert with_types == [plain, other]
    assert (
        agent_watch._newest_file_with_types([str(tmp_path)], GLOB, ["session_meta"], 10, exclude_globs=EXCLUDES)
        == plain
    )


def test_codex_temp_files_are_not_sessions(tmp_path):
    day = _day(tmp_path)
    _write(day / "rollout-a.jsonl.tmp", _lines("a"), 3_000)
    _write(day / "rollout-a.jsonl.zst.123.tmp", b"partial", 3_000)
    plain = _write(day / "rollout-b.jsonl", _lines("b"), 1_000)
    assert agent_watch._newest_files([str(tmp_path)], GLOB, 5, exclude_globs=EXCLUDES) == [plain]


def test_other_agents_compressed_names_are_left_alone(tmp_path):
    dsh = _write(tmp_path / "p" / "s" / "session.v2.jsonl.zstd", b"x", 1_000)
    assert agent_watch._is_session_candidate(dsh)


def test_truncated_or_corrupt_zst_is_skipped_not_raised(tmp_path):
    day = _day(tmp_path)
    full = zstd.compress(_lines("a") * 200)
    truncated = _write(day / "rollout-t.jsonl.zst", full[: len(full) // 2], 1_000)
    corrupt = _write(day / "rollout-c.jsonl.zst", b"\x28\xb5\x2f\xfd" + b"\x00" * 64, 1_000)
    # Neither raises; a reader that never reached a session_meta reports False.
    assert agent_watch._jsonl_contains_any_type(corrupt, {"session_meta"}, max_lines=10) is False
    assert agent_watch._jsonl_contains_any_type(truncated, {"never_present"}, max_lines=10_000) is False


def test_truncated_zst_with_early_session_meta_is_skipped_by_the_weekly_fingerprint(tmp_path):
    # The production shape: session_meta decodes before the cut, so the head-only
    # type check accepts the file as newest; the full fingerprint then hits the cut.
    day = _day(tmp_path)
    # Incompressible filler spreads the stream over many zstd blocks, so the cut
    # lands after the first block (with session_meta) has decoded.
    filler = "".join(
        json.dumps({"type": "response_item", "payload": {"text": os.urandom(96).hex()}}) + "\n" for _ in range(3000)
    ).encode()
    full = zstd.compress(_lines("t") + filler)
    truncated = _write(day / "rollout-t.jsonl.zst", full[: len(full) * 3 // 4], 2_000)
    good = _write(day / "rollout-g.jsonl", _lines("g"), 1_000)

    newest = agent_watch._newest_file_with_types([str(tmp_path)], GLOB, ["session_meta"], 400, exclude_globs=EXCLUDES)
    assert newest == truncated

    def fp(p):
        return agent_watch._schema_fingerprint_for_agent("codex", p, max_lines=2500)

    with pytest.raises(agent_watch._SESSION_READ_ERRORS):
        fp(truncated)
    sampled = agent_watch._readable_fingerprints([truncated, good], fp)
    assert [s.get("file") for s in sampled] == [str(good)]


def test_missing_zstd_module_surfaces_as_oserror(tmp_path, monkeypatch):
    zst = _write(_day(tmp_path) / "rollout-a.jsonl.zst", zstd.compress(_lines("a")), 1_000)
    import builtins

    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "compression" or name.startswith("compression."):
            raise ImportError("no compression.zstd")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    with pytest.raises(OSError):
        agent_watch._open_session_text(zst)
    assert agent_watch._jsonl_contains_any_type(zst, {"session_meta"}, max_lines=10) is False
