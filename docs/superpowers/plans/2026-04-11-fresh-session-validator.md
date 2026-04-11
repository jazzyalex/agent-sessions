# Fresh-Session Validator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship hybrid Option-C fresh-session validation: augment the weekly scanner with sample-freshness staleness detection for all 7 agents and add an opt-in `--mode prebump` path with per-agent headless drivers for codex, claude, gemini, droid, and copilot.

**Architecture:** Extend `scripts/agent_watch.py` in place — staleness is a new helper + evidence block that plugs into the existing weekly loop, and prebump is a new `--mode prebump` branch that reuses the existing fingerprint/diff helpers. Per-agent prebump drivers live in a new `scripts/agent_watch_prebump_drivers.py` module behind a small `PrebumpDriver` protocol, with sandbox/auth/hygiene logic shared across drivers. All new behavior is covered by pytest tests under `scripts/tests/` using `tmp_path` and subprocess stubs so nothing hits the real agent CLIs.

**Tech Stack:** Python 3, pytest, existing agent_watch.py structure, shutil.which, tempfile sandboxing

---

## File Structure

**Create:**
- `scripts/agent_watch_prebump_drivers.py` — `PrebumpDriver` protocol, `DriverResult` dataclass, shared sandbox/auth/hygiene helpers, and the 5 v1 driver classes (`CodexExecDriver`, `ClaudePrintDriver`, `GeminiPromptDriver`, `DroidExecDriver`, `CopilotPromptDriver`) plus the `DRIVERS` registry.
- `scripts/tests/__init__.py` — empty marker so pytest discovers the package.
- `scripts/tests/conftest.py` — shared fixtures (`fake_home`, `frozen_now`, `fake_binary`, `stub_subprocess`).
- `scripts/tests/test_freshness.py` — staleness-detection unit tests (hot/cold windows, mtime comparison, `--force-fresh`, `cli_binary_unresolved`, `mode_context=skip_update`, severity override, stdout one-liner).
- `scripts/tests/test_prebump_framework.py` — framework tests (mode dispatch, sandbox creation/teardown, env-var-first auth, credential-copy hygiene gates, schema-diff reuse, prebump report shape, exit codes 0/2/3/4).
- `scripts/tests/test_prebump_driver_codex.py` — codex driver integration test.
- `scripts/tests/test_prebump_driver_claude.py` — claude driver integration test.
- `scripts/tests/test_prebump_driver_gemini.py` — gemini driver integration test.
- `scripts/tests/test_prebump_driver_droid.py` — droid driver integration test.
- `scripts/tests/test_prebump_driver_copilot.py` — copilot driver integration test + hermeticity leak assertion.
- `docs/superpowers/plans/2026-04-11-fresh-session-validator.md` — this file.

**Modify:**
- `scripts/agent_watch.py` — add `_resolve_cli_binary_mtime`, `_compute_sample_freshness`, threading `sample_freshness` into the weekly evidence block, updated severity override + one-liner, new `--mode prebump` branch, `--force-fresh`, `--allow-real-home`, `--keep-sandbox`, `--timeout-seconds`, `--agent` repeatable, and the `run_prebump_validator` recommendation.
- `docs/agent-support/agent-watch-config.json` — add `agents.<name>.weekly.freshness_window_days` (14 hot / 30 cold) and `agents.<name>.prebump` blocks for codex/claude/gemini/droid/copilot.
- `skills/agent-session-format-check/SKILL.md` — new §Prebump workflow subsection.
- `docs/agent-support/monitoring.md` — add staleness-field documentation, `run_prebump_validator` recommendation, prebump exit-code contract, and pre-commit snippet.
- `CHANGELOG.md` — add "Unreleased" entry for the fresh-session validator.

**Read-only (do not modify):**
- `scripts/capture_latest_agent_sessions.py` — driver path helpers are reused by reference only.
- `docs/agent-support/agent-support-matrix.yml`.

---

## Phase 1 — Staleness detection (all 7 agents)

### Task 1.1 — Pytest scaffold under scripts/tests

**Files**
- Create: `scripts/tests/__init__.py`, `scripts/tests/conftest.py`
- Test: `scripts/tests/test_freshness.py` (sanity test only in this task)

- [ ] **Step 1: Write the failing test.** Create `scripts/tests/test_freshness.py` with a sanity import test that pulls a symbol Phase 1 will add. This is genuinely red against the current main branch — `_resolve_cli_binary_mtime` does not exist in `scripts/agent_watch.py` yet (Task 1.2 adds it), so the import line itself fails.

  ```python
  # scripts/tests/test_freshness.py
  import sys
  from pathlib import Path

  REPO = Path(__file__).resolve().parents[2]
  sys.path.insert(0, str(REPO / "scripts"))

  import agent_watch
  from agent_watch import _resolve_cli_binary_mtime  # added in Task 1.2


  def test_freshness_module_under_test_is_importable():
      # Sanity: agent_watch is on sys.path and the freshness helper that
      # Phase 1 builds out is now reachable from this test module.
      assert callable(_resolve_cli_binary_mtime)
      assert hasattr(agent_watch, "main")
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_freshness.py -v
  ```

  Expected: collection error `ImportError: cannot import name '_resolve_cli_binary_mtime' from 'agent_watch'`. This is genuinely red — the symbol does not exist on main and is added in Task 1.2.

- [ ] **Step 3: Write the minimal scaffold.** Create the package and conftest, and add a tiny stub `_resolve_cli_binary_mtime = None` placeholder is **not** what we want — Task 1.2 will add the real implementation. For Task 1.1, only create the package files; the test stays red until Task 1.2 provides the helper.

  ```python
  # scripts/tests/__init__.py
  ```

  ```python
  # scripts/tests/conftest.py
  import sys
  from pathlib import Path

  REPO_ROOT = Path(__file__).resolve().parents[2]
  SCRIPTS = REPO_ROOT / "scripts"
  if str(SCRIPTS) not in sys.path:
      sys.path.insert(0, str(SCRIPTS))
  ```

- [ ] **Step 4: Re-run the test; it stays red until Task 1.2.**

  ```
  pytest scripts/tests/test_freshness.py -v
  ```

  Expected: still `ImportError` on `_resolve_cli_binary_mtime`. Task 1.2 will turn this green by adding the helper. Task 1.1 ships only the package scaffold.

- [ ] **Step 5: Commit.**

  ```
  git add scripts/tests/__init__.py scripts/tests/conftest.py scripts/tests/test_freshness.py
  git commit -m "$(cat <<'EOF'
  test(monitoring): scaffold pytest tree for agent_watch

  Adds scripts/tests/ with a conftest that puts scripts/ on sys.path so
  pytest scripts/tests/ runs cleanly from repo root. Seeds a red sanity
  test that imports the upcoming _resolve_cli_binary_mtime helper; Task
  1.2 turns it green.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: foundation for freshness + prebump unit tests
  EOF
  )"
  ```

---

### Task 1.2 — `_resolve_cli_binary_mtime` helper

**Files**
- Modify: `scripts/agent_watch.py`
- Test: `scripts/tests/test_freshness.py`

- [ ] **Step 1: Write the failing test.** Append to `scripts/tests/test_freshness.py`:

  ```python
  import os
  from unittest import mock

  import agent_watch


  def test_resolve_cli_binary_mtime_returns_path_and_mtime(tmp_path):
      fake_bin = tmp_path / "codex"
      fake_bin.write_text("#!/bin/sh\nexit 0\n")
      fake_bin.chmod(0o755)
      os.utime(fake_bin, (1_700_000_000, 1_700_000_000))

      with mock.patch("agent_watch.shutil.which", return_value=str(fake_bin)):
          path, mtime = agent_watch._resolve_cli_binary_mtime(["codex", "--version"])

      assert path == str(fake_bin)
      assert mtime == 1_700_000_000.0


  def test_resolve_cli_binary_mtime_handles_missing_binary():
      with mock.patch("agent_watch.shutil.which", return_value=None):
          path, mtime = agent_watch._resolve_cli_binary_mtime(["nope", "--version"])
      assert path is None
      assert mtime is None


  def test_resolve_cli_binary_mtime_handles_empty_cmd():
      path, mtime = agent_watch._resolve_cli_binary_mtime(None)
      assert path is None
      assert mtime is None
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_freshness.py::test_resolve_cli_binary_mtime_returns_path_and_mtime -v
  ```

  Expected: `AttributeError: module 'agent_watch' has no attribute '_resolve_cli_binary_mtime'`.

- [ ] **Step 3: Write the minimal implementation.** In `scripts/agent_watch.py`, add `import shutil` to the top-level imports (alongside `subprocess`), and add this helper directly above `_pick_severity`:

  ```python
  def _resolve_cli_binary_mtime(installed_version_cmd: list[str] | None) -> tuple[str | None, float | None]:
      """Resolve the CLI binary on PATH and return (abs_path, mtime_epoch).

      Both elements are None if the command is empty, unresolvable, or the
      resolved path cannot be stat'd. Used by sample_freshness to decide if
      the newest local sample predates the installed binary.
      """
      if not isinstance(installed_version_cmd, list) or not installed_version_cmd:
          return None, None
      binary_name = installed_version_cmd[0]
      if not isinstance(binary_name, str) or not binary_name:
          return None, None
      resolved = shutil.which(binary_name)
      if not resolved:
          return None, None
      try:
          st = os.stat(resolved)
      except OSError:
          return resolved, None
      return resolved, float(st.st_mtime)
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_freshness.py -v
  ```

  Expected: all 4 tests in this file pass.

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch.py scripts/tests/test_freshness.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add _resolve_cli_binary_mtime helper

  Resolves an agent's installed binary via shutil.which and returns its
  on-disk mtime so weekly staleness detection can compare sample mtime
  against the binary that wrote it. Handles missing binary, missing
  command, and unreadable stat cleanly.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: primary signal for sample_older_than_cli
  EOF
  )"
  ```

---

### Task 1.3 — `_compute_sample_freshness` (hot window, binary compare, normal mode)

**Files**
- Modify: `scripts/agent_watch.py`
- Test: `scripts/tests/test_freshness.py`

- [ ] **Step 1: Write the failing test.**

  ```python
  def test_sample_freshness_fresh_when_sample_newer_than_cli():
      result = agent_watch._compute_sample_freshness(
          sample_mtime=2_000.0,
          cli_binary_path="/usr/local/bin/codex",
          cli_binary_mtime=1_000.0,
          freshness_window_seconds=14 * 86400,
          now_epoch=2_500.0,
          mode_context="normal",
          force_fresh=False,
      )
      assert result["is_stale"] is False
      assert result["stale_reason"] is None
      assert result["mode_context"] == "normal"
      assert result["sample_older_than_cli"] is False
      assert result["sample_older_than_window"] is False


  def test_sample_freshness_stale_when_sample_older_than_cli():
      result = agent_watch._compute_sample_freshness(
          sample_mtime=1_000.0,
          cli_binary_path="/usr/local/bin/codex",
          cli_binary_mtime=2_000.0,
          freshness_window_seconds=14 * 86400,
          now_epoch=2_500.0,
          mode_context="normal",
          force_fresh=False,
      )
      assert result["is_stale"] is True
      assert result["stale_reason"] == "sample_older_than_cli"
      assert result["sample_older_than_cli"] is True


  def test_sample_freshness_window_fallback_when_binary_unresolved():
      result = agent_watch._compute_sample_freshness(
          sample_mtime=0.0,
          cli_binary_path=None,
          cli_binary_mtime=None,
          freshness_window_seconds=14 * 86400,
          now_epoch=100 * 86400,
          mode_context="normal",
          force_fresh=False,
      )
      assert result["is_stale"] is True
      assert result["stale_reason"] == "cli_binary_unresolved"
      assert result["sample_older_than_cli"] is None
      assert result["sample_older_than_window"] is True
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_freshness.py::test_sample_freshness_fresh_when_sample_newer_than_cli -v
  ```

  Expected: `AttributeError: module 'agent_watch' has no attribute '_compute_sample_freshness'`.

- [ ] **Step 3: Write the minimal implementation.** In `scripts/agent_watch.py`, add below `_resolve_cli_binary_mtime`:

  ```python
  def _epoch_to_utc_iso(epoch: float | None) -> str | None:
      if epoch is None:
          return None
      return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat().replace("+00:00", "Z")


  def _compute_sample_freshness(
      *,
      sample_mtime: float | None,
      cli_binary_path: str | None,
      cli_binary_mtime: float | None,
      freshness_window_seconds: int,
      now_epoch: float,
      mode_context: str,
      force_fresh: bool,
  ) -> dict[str, Any]:
      """Build the sample_freshness evidence block per spec §3.1/§3.2."""
      block: dict[str, Any] = {
          "sample_mtime_utc": _epoch_to_utc_iso(sample_mtime),
          "cli_binary_mtime_utc": _epoch_to_utc_iso(cli_binary_mtime),
          "cli_binary_path": cli_binary_path,
          "freshness_window_seconds": int(freshness_window_seconds),
          "sample_older_than_cli": None,
          "sample_older_than_window": None,
          "is_stale": False,
          "stale_reason": None,
          "mode_context": mode_context,
      }

      if force_fresh:
          block["is_stale"] = False
          block["stale_reason"] = "forced_fresh"
          return block

      if sample_mtime is None:
          # No sample on disk — staleness is not meaningful; leave flags None.
          return block

      if cli_binary_mtime is not None:
          older_cli = sample_mtime < cli_binary_mtime
          block["sample_older_than_cli"] = bool(older_cli)
      else:
          block["sample_older_than_cli"] = None

      older_window = (now_epoch - sample_mtime) > freshness_window_seconds
      block["sample_older_than_window"] = bool(older_window)

      if block["sample_older_than_cli"] is True:
          block["is_stale"] = True
          block["stale_reason"] = "sample_older_than_cli"
      elif older_window:
          block["is_stale"] = True
          if cli_binary_path is None:
              block["stale_reason"] = "cli_binary_unresolved"
          else:
              block["stale_reason"] = "sample_older_than_window"
      else:
          if cli_binary_path is None:
              # Binary unresolved but window still fresh — record the cause so
              # downstream readers know signal 1 was unavailable.
              block["stale_reason"] = "cli_binary_unresolved"
              block["is_stale"] = False

      return block
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_freshness.py -v
  ```

  Expected: all freshness tests pass.

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch.py scripts/tests/test_freshness.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): compute sample_freshness evidence block

  Adds _compute_sample_freshness + _epoch_to_utc_iso helpers that produce
  the spec §3.1 evidence block: sample_older_than_cli as the primary
  signal, sample_older_than_window as a backstop, and stale_reason /
  mode_context split so the same underlying failure reports one cause
  regardless of run mode. Covers fresh, mtime-stale, and binary-unresolved
  cases.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: core staleness logic reused by weekly + prebump
  EOF
  )"
  ```

---

### Task 1.4 — `forced_fresh` override

**Files**
- Modify: `scripts/agent_watch.py` (no functional change; Task 1.3 already covers `force_fresh`)
- Test: `scripts/tests/test_freshness.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  def test_sample_freshness_forced_fresh_suppresses_stale():
      result = agent_watch._compute_sample_freshness(
          sample_mtime=1_000.0,
          cli_binary_path="/usr/local/bin/codex",
          cli_binary_mtime=2_000.0,  # would normally be stale
          freshness_window_seconds=14 * 86400,
          now_epoch=3_000.0,
          mode_context="normal",
          force_fresh=True,
      )
      assert result["is_stale"] is False
      assert result["stale_reason"] == "forced_fresh"
      # flags left untouched so the operator can still see what would have fired
      assert result["sample_older_than_cli"] is None
      assert result["sample_older_than_window"] is None
  ```

- [ ] **Step 2: Run the test to verify it fails or passes.**

  ```
  pytest scripts/tests/test_freshness.py::test_sample_freshness_forced_fresh_suppresses_stale -v
  ```

  Expected: passes immediately because Task 1.3 implemented `force_fresh` short-circuit. If it fails, the short-circuit in `_compute_sample_freshness` is wrong and should return the block with `stale_reason="forced_fresh"` **before** computing the flags — fix there and rerun.

- [ ] **Step 3: Write the minimal implementation.** No code change if Step 2 already passes. If not, confirm the `if force_fresh:` branch in `_compute_sample_freshness` returns early.

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_freshness.py -v
  ```

- [ ] **Step 5: Commit.** If Step 3 made no change, commit only the new test:

  ```
  git add scripts/tests/test_freshness.py
  git commit -m "$(cat <<'EOF'
  test(monitoring): lock forced_fresh override behavior

  Adds a regression test that pins sample_freshness forced_fresh
  semantics: stale_reason is forced_fresh, is_stale is False, and the
  underlying signal flags stay null so the override is visible without
  contradicting the reason field.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: prevents silent regression of the §3.2 escape hatch
  EOF
  )"
  ```

---

### Task 1.5 — Per-agent freshness windows in config

**Files**
- Modify: `docs/agent-support/agent-watch-config.json`
- Test: `scripts/tests/test_freshness.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  import json as _json


  def test_config_freshness_windows_per_agent():
      cfg = _json.loads(
          (REPO / "docs" / "agent-support" / "agent-watch-config.json").read_text()
      )
      hot = {"codex", "claude", "copilot"}
      cold = {"gemini", "droid", "opencode", "openclaw"}
      for name in hot:
          w = cfg["agents"][name]["weekly"].get("freshness_window_days")
          assert w == 14, f"{name}: want 14, got {w}"
      for name in cold:
          w = cfg["agents"][name]["weekly"].get("freshness_window_days")
          assert w == 30, f"{name}: want 30, got {w}"
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_freshness.py::test_config_freshness_windows_per_agent -v
  ```

  Expected: `KeyError: 'freshness_window_days'` or `assert None == 14`.

- [ ] **Step 3: Write the minimal implementation.** In `docs/agent-support/agent-watch-config.json`, add a `"freshness_window_days"` field to each `agents.<name>.weekly` block. Add right after the `"local_schema"` object, before `"discovery_path_contract"`:
  - codex: `"freshness_window_days": 14,`
  - claude: `"freshness_window_days": 14,`
  - copilot: `"freshness_window_days": 14,`
  - gemini: `"freshness_window_days": 30,`
  - droid: `"freshness_window_days": 30,`
  - opencode: `"freshness_window_days": 30,`
  - openclaw: `"freshness_window_days": 30,`

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_freshness.py -v
  python -c "import json; json.load(open('docs/agent-support/agent-watch-config.json'))"
  ```

- [ ] **Step 5: Commit.**

  ```
  git add docs/agent-support/agent-watch-config.json scripts/tests/test_freshness.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add per-agent freshness_window_days to watch config

  Hot agents (codex/claude/copilot) ship 14 days; cold agents
  (gemini/droid/opencode/openclaw) ship 30 days. The window acts as a
  backstop to the sample_older_than_cli signal for agents the user does
  not exercise every week.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §3.2 resolved decision #1
  EOF
  )"
  ```

---

### Task 1.6 — Thread sample_freshness into weekly evidence

**Files**
- Modify: `scripts/agent_watch.py`
- Test: `scripts/tests/test_freshness.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  import json as _json


  def _write_jsonl(path, lines):
      path.parent.mkdir(parents=True, exist_ok=True)
      path.write_text("\n".join(_json.dumps(x) for x in lines) + "\n")


  def test_weekly_run_emits_sample_freshness_block(tmp_path, monkeypatch):
      # Build a tiny fake codex session tree under a fake HOME.
      home = tmp_path / "home"
      sess = home / ".codex" / "sessions" / "2026" / "04" / "06"
      stale_file = sess / "rollout-stale.jsonl"
      _write_jsonl(stale_file, [{"type": "session_meta", "id": "x"}])
      os.utime(stale_file, (1_700_000_000, 1_700_000_000))

      fake_bin = tmp_path / "codex"
      fake_bin.write_text("#!/bin/sh\nexit 0\n")
      fake_bin.chmod(0o755)
      os.utime(fake_bin, (1_800_000_000, 1_800_000_000))  # newer than sample

      monkeypatch.setenv("HOME", str(home))
      monkeypatch.setenv("CODEX_HOME", str(home / ".codex"))
      monkeypatch.setattr(agent_watch.shutil, "which", lambda name: str(fake_bin) if name == "codex" else None)

      freshness = agent_watch._compute_sample_freshness(
          sample_mtime=stale_file.stat().st_mtime,
          cli_binary_path=str(fake_bin),
          cli_binary_mtime=fake_bin.stat().st_mtime,
          freshness_window_seconds=14 * 86400,
          now_epoch=fake_bin.stat().st_mtime + 10,
          mode_context="normal",
          force_fresh=False,
      )
      assert freshness["is_stale"] is True
      assert freshness["stale_reason"] == "sample_older_than_cli"
      # The weekly loop is exercised end-to-end in Task 1.8; here we just
      # pin that the block is shaped correctly.
      assert set(freshness.keys()) == {
          "sample_mtime_utc", "cli_binary_mtime_utc", "cli_binary_path",
          "freshness_window_seconds", "sample_older_than_cli",
          "sample_older_than_window", "is_stale", "stale_reason", "mode_context",
      }
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_freshness.py::test_weekly_run_emits_sample_freshness_block -v
  ```

  Expected: passes shape assertion only if Task 1.3 is complete. If not, fix Task 1.3.

- [ ] **Step 3: Write the minimal implementation.** In `scripts/agent_watch.py`, inside `main()` where `evidence` is built (around the current `"evidence": {...}` dict for each agent — see the `results[agent_name] = {...}` literal), compute and include `sample_freshness`. Add, immediately before the `results[agent_name] = {` line:

  ```python
          sample_freshness: dict[str, Any] | None = None
          if args.mode == "weekly":
              window_days_cfg = int(((agent_cfg.get("weekly") or {}).get("freshness_window_days") or 14))
              window_seconds = window_days_cfg * 86400
              sample_mtime_epoch: float | None = None
              if isinstance(weekly_details, dict):
                  local_schema_obj = weekly_details.get("local_schema")
                  if isinstance(local_schema_obj, dict):
                      fpath = local_schema_obj.get("file")
                      if isinstance(fpath, str):
                          try:
                              st = os.stat(fpath)
                              sample_mtime_epoch = float(st.st_mtime)
                              local_schema_obj["mtime_epoch"] = sample_mtime_epoch
                              local_schema_obj["mtime_utc"] = _epoch_to_utc_iso(sample_mtime_epoch)
                          except OSError:
                              pass
              cli_path, cli_mtime = _resolve_cli_binary_mtime(installed_cmd if isinstance(installed_cmd, list) else None)
              mode_context = "skip_update" if args.skip_update else "normal"
              sample_freshness = _compute_sample_freshness(
                  sample_mtime=sample_mtime_epoch,
                  cli_binary_path=cli_path,
                  cli_binary_mtime=cli_mtime,
                  freshness_window_seconds=window_seconds,
                  now_epoch=datetime.now(timezone.utc).timestamp(),
                  mode_context=mode_context,
                  force_fresh=bool(getattr(args, "force_fresh", False)),
              )
  ```

  Then update the `"evidence": { ... }` literal to include two new fields:

  ```python
              "evidence": {
                  "schema_matches_baseline": schema_matches_baseline,
                  "schema_diff": schema_diff,
                  "sample_freshness": sample_freshness,
                  "fresh_evidence_available": False,
              },
  ```

  Also add `parser.add_argument("--force-fresh", action="store_true", help="Suppress staleness for this run; records stale_reason=forced_fresh")` to the argparse block in `main()`.

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_freshness.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch.py scripts/tests/test_freshness.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): thread sample_freshness into weekly evidence

  Weekly runs now populate evidence.sample_freshness using
  _compute_sample_freshness against the newest local sample and the
  installed CLI binary mtime. Adds --force-fresh flag, writes
  mtime_epoch/mtime_utc into local_schema, and seeds
  fresh_evidence_available=False for the prebump path to flip later.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §3.1 evidence block
  EOF
  )"
  ```

---

### Task 1.7 — Severity override: stale sample blocks auto-downgrade

**Files**
- Modify: `scripts/agent_watch.py`
- Test: `scripts/tests/test_freshness.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  def test_stale_sample_blocks_bump_downgrade():
      # Simulate the override block from main() in isolation.
      severity, recommendation = agent_watch._apply_stale_override(
          severity="low",
          recommendation="bump_verified_version",
          installed_newer_than_verified=True,
          schema_matches_baseline=True,
          sample_freshness={"is_stale": True, "stale_reason": "sample_older_than_cli"},
      )
      assert severity == "medium"
      assert recommendation == "run_prebump_validator"


  def test_fresh_sample_keeps_bump_downgrade():
      severity, recommendation = agent_watch._apply_stale_override(
          severity="low",
          recommendation="bump_verified_version",
          installed_newer_than_verified=True,
          schema_matches_baseline=True,
          sample_freshness={"is_stale": False, "stale_reason": None},
      )
      assert severity == "low"
      assert recommendation == "bump_verified_version"
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_freshness.py::test_stale_sample_blocks_bump_downgrade -v
  ```

  Expected: `AttributeError: no attribute '_apply_stale_override'`.

- [ ] **Step 3: Write the minimal implementation.** Add this helper above `main()` in `scripts/agent_watch.py`:

  ```python
  def _apply_stale_override(
      *,
      severity: str,
      recommendation: str,
      installed_newer_than_verified: bool,
      schema_matches_baseline: bool | None,
      sample_freshness: dict[str, Any] | None,
  ) -> tuple[str, str]:
      """Spec §3.3: block auto-downgrade when the weekly sample is stale."""
      if not installed_newer_than_verified:
          return severity, recommendation
      if schema_matches_baseline is not True:
          return severity, recommendation
      if not isinstance(sample_freshness, dict):
          return severity, recommendation
      if sample_freshness.get("is_stale") is not True:
          return severity, recommendation
      return "medium", "run_prebump_validator"
  ```

  In `main()`, find the existing post-pick override:

  ```python
          if (
              args.mode == "weekly"
              and severity in ("medium", "low")
              and installed_newer_than_verified
              and schema_matches_baseline is True
              and not probe_failed
          ):
              severity = "low"
              recommendation = "bump_verified_version"
  ```

  Immediately after that block, add:

  ```python
          if args.mode == "weekly":
              severity, recommendation = _apply_stale_override(
                  severity=severity,
                  recommendation=recommendation,
                  installed_newer_than_verified=installed_newer_than_verified,
                  schema_matches_baseline=schema_matches_baseline,
                  sample_freshness=sample_freshness,
              )
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_freshness.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch.py scripts/tests/test_freshness.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): block bump_verified_version when sample is stale

  When installed > verified and schema_matches_baseline is true but
  sample_freshness.is_stale is true, severity is raised back to medium
  and recommendation flips to run_prebump_validator. Fresh samples
  preserve the existing auto-downgrade behavior.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §3.3 — codex 0.120.0 trap
  EOF
  )"
  ```

---

### Task 1.8 — Stdout one-liner with `stale=` token

**Files**
- Modify: `scripts/agent_watch.py`
- Test: `scripts/tests/test_freshness.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  def test_summary_line_formats_stale_token():
      line = agent_watch._format_summary_line(
          agent_name="codex",
          severity="medium",
          verified="0.119.0",
          installed="0.120.0",
          upstream="0.120.0",
          recommendation="run_prebump_validator",
          sample_freshness={"is_stale": True, "stale_reason": "sample_older_than_cli"},
      )
      assert "stale=true(sample_older_than_cli)" in line
      assert "rec=run_prebump_validator" in line


  def test_summary_line_forced_fresh_reads_false_with_reason():
      line = agent_watch._format_summary_line(
          agent_name="codex",
          severity="low",
          verified="0.119.0",
          installed="0.120.0",
          upstream="0.120.0",
          recommendation="bump_verified_version",
          sample_freshness={"is_stale": False, "stale_reason": "forced_fresh"},
      )
      assert "stale=false(forced_fresh)" in line


  def test_summary_line_no_reason_omits_parens():
      line = agent_watch._format_summary_line(
          agent_name="codex",
          severity="low",
          verified="0.119.0",
          installed="0.119.0",
          upstream="0.119.0",
          recommendation="monitor",
          sample_freshness={"is_stale": False, "stale_reason": None},
      )
      assert "stale=false" in line
      assert "stale=false(" not in line
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_freshness.py::test_summary_line_formats_stale_token -v
  ```

  Expected: `AttributeError: no attribute '_format_summary_line'`.

- [ ] **Step 3: Write the minimal implementation.** Add helper in `scripts/agent_watch.py`:

  ```python
  def _format_summary_line(
      *,
      agent_name: str,
      severity: str,
      verified: str | None,
      installed: str | None,
      upstream: str | None,
      recommendation: str,
      sample_freshness: dict[str, Any] | None,
  ) -> str:
      base = (
          f"{agent_name}: severity={severity} "
          f"verified={verified or 'unknown'} "
          f"installed={installed or 'unknown'} "
          f"upstream={upstream or 'unknown'} "
          f"rec={recommendation}"
      )
      if not isinstance(sample_freshness, dict):
          return base
      is_stale = sample_freshness.get("is_stale")
      reason = sample_freshness.get("stale_reason")
      token = "stale=true" if is_stale else "stale=false"
      if isinstance(reason, str) and reason:
          token = f"{token}({reason})"
      return f"{base} {token}"
  ```

  In `main()`, replace the existing `summary_lines.append(...)` block with:

  ```python
          if severity != "none":
              summary_lines.append(
                  _format_summary_line(
                      agent_name=agent_name,
                      severity=severity,
                      verified=verified,
                      installed=installed,
                      upstream=upstream,
                      recommendation=recommendation,
                      sample_freshness=sample_freshness,
                  )
              )
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_freshness.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch.py scripts/tests/test_freshness.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add stale= token to weekly summary line

  Per-agent stdout summary now prints stale=true|false plus the
  stale_reason in parentheses when set, making both real staleness and
  --force-fresh overrides visible at a glance without reading
  report.json.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §3.4
  EOF
  )"
  ```

---

## Phase 2 — Prebump framework (shared)

### Task 2.1 — `--mode prebump` argparse + dispatch stub

**Files**
- Modify: `scripts/agent_watch.py`
- Test: `scripts/tests/test_prebump_framework.py`

- [ ] **Step 1: Write the failing test.**

  ```python
  # scripts/tests/test_prebump_framework.py
  import json
  import sys
  from pathlib import Path

  REPO = Path(__file__).resolve().parents[2]
  sys.path.insert(0, str(REPO / "scripts"))

  import agent_watch


  def test_prebump_mode_argparse_accepts_new_flags(tmp_path, monkeypatch, capsys):
      cfg = {
          "report_root": str(tmp_path / "out"),
          "agents": {},
      }
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)  # agent_watch reads matrix yml via relative path
      rc = agent_watch.main([
          "--mode", "prebump",
          "--config", str(cfg_path),
          "--keep-sandbox",
          "--timeout-seconds", "30",
          "--allow-real-home",
      ])
      # No agents configured for prebump and no --agent restriction → exit 0.
      assert rc == 0


  def test_prebump_mode_unknown_agent_exits_4(tmp_path, monkeypatch, capsys):
      cfg = {
          "report_root": str(tmp_path / "out"),
          "agents": {},  # nothing has a prebump block
      }
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      rc = agent_watch.main([
          "--mode", "prebump",
          "--config", str(cfg_path),
          "--agent", "codex",  # not in configured_prebump_agents
      ])
      assert rc == 4
      err = capsys.readouterr().err
      assert "codex" in err
      assert "prebump" in err.lower()
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_framework.py::test_prebump_mode_argparse_accepts_new_flags -v
  ```

  Expected: `error: argument --mode: invalid choice: 'prebump'`.

- [ ] **Step 3: Write the minimal implementation.** In `scripts/agent_watch.py` `main()`:

  - Add a module-level constant near the top of `scripts/agent_watch.py` (above `main()`), used by both the prebump dispatch and the CLI default fallback:
    ```python
    DEFAULT_TIMEOUT_SECONDS = 120
    ```
  - Change `parser.add_argument("--mode", choices=["daily", "weekly"], required=True)` to `choices=["daily", "weekly", "prebump"]`.
  - Add these arguments:
    ```python
    parser.add_argument("--agent", action="append", default=[], help="Repeatable. Restricts prebump to the listed agents.")
    parser.add_argument("--keep-sandbox", action="store_true", help="Keep prebump sandbox directories for debugging.")
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=None,
        help=(
            "Per-driver timeout for prebump runs (seconds). Precedence: "
            "CLI flag overrides per-agent config; falls back to "
            "agents.<name>.prebump.timeout_seconds, then DEFAULT_TIMEOUT_SECONDS."
        ),
    )
    parser.add_argument("--allow-real-home", action="store_true", help="Allow copilot (and other home_override agents) to fall back to real HOME after an explicit sandbox-leak diagnostic.")
    ```
  - After `args = parser.parse_args(argv)`, add:
    ```python
    if args.mode == "prebump":
        return _run_prebump(args, cfg, report_dir=report_dir, verified_map=verified_map, evidence=evidence)
    ```
  - Add a stub function above `main()`:
    ```python
    def _run_prebump(args, cfg: dict[str, Any], *, report_dir: Path, verified_map: dict[str, str | None], evidence: dict[str, list[str]]) -> int:
        """Prebump entrypoint; implemented across Phase 2 tasks.

        Exit-code contract (spec §4.2):
          0 — every requested agent produced a fresh session matching baseline
          2 — at least one fresh session schema mismatched baseline
          3 — at least one driver failed (CLI error, timeout, no headless,
              or discovery-contract violation at runtime)
          4 — config / invariant error: unknown agent, missing or invalid
              discover_session contract, credential hygiene failure, or
              sandbox breach
        """
        agents_cfg = cfg.get("agents") or {}
        configured_prebump_agents = {
            name for name, acfg in agents_cfg.items()
            if isinstance(acfg, dict) and isinstance(acfg.get("prebump"), dict)
        }
        requested = list(args.agent or [])
        if requested:
            unknown = [a for a in requested if a not in configured_prebump_agents]
            if unknown:
                import sys as _sys
                _sys.stderr.write(
                    "agent_watch --mode prebump: rejected agent(s) "
                    f"{unknown}: not in configured prebump set "
                    f"{sorted(configured_prebump_agents)}\n"
                )
                return 4
            selected = set(requested)
        else:
            selected = set(configured_prebump_agents)
        prebump_agents = {
            name: agents_cfg[name] for name in selected
        }
        if not prebump_agents:
            return 0
        return 0  # fleshed out in Task 2.7
    ```

  Note: the `cfg_path` / matrix / evidence loading happens above this dispatch — move the prebump dispatch line to after `evidence` is built, before the weekly loop starts.

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_framework.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch.py scripts/tests/test_prebump_framework.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add --mode prebump argparse skeleton

  Wires --mode prebump through argparse with --agent (repeatable),
  --keep-sandbox, --timeout-seconds, and --allow-real-home. Dispatches
  --mode prebump to the prebump entry point. When no --agent is
  requested, selects every agent that declares a prebump block and
  exits 0 if the set is empty. When --agent is requested, validates
  each name against the configured prebump agents; see Task 2.7 for
  the unknown-agent and config-gate behavior.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §4.2 CLI surface
  EOF
  )"
  ```

---

### Task 2.2 — PrebumpDriver protocol + DriverResult

**Files**
- Create: `scripts/agent_watch_prebump_drivers.py`
- Test: `scripts/tests/test_prebump_framework.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  def test_driver_protocol_and_result_dataclass():
      from agent_watch_prebump_drivers import PrebumpDriver, DriverResult, DRIVERS
      assert hasattr(PrebumpDriver, "run")
      res = DriverResult(
          ok=True,
          session_path=Path("/tmp/x"),
          stdout_file=Path("/tmp/o"),
          stderr_file=Path("/tmp/e"),
          exit_code=0,
          error=None,
      )
      assert res.ok is True
      assert DRIVERS == {}  # filled in later tasks
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_framework.py::test_driver_protocol_and_result_dataclass -v
  ```

  Expected: `ModuleNotFoundError: No module named 'agent_watch_prebump_drivers'`.

- [ ] **Step 3: Write the minimal implementation.** Create `scripts/agent_watch_prebump_drivers.py`:

  ```python
  """Per-agent prebump drivers for scripts/agent_watch.py --mode prebump.

  Each driver knows how to:
    1. build a sandbox directory the agent will treat as HOME,
    2. forward or copy credentials per the hybrid auth policy (§4.4),
    3. run the agent's headless command once,
    4. point back at the session file the agent wrote under the sandbox.

  Drivers do not fingerprint or diff — that is done by agent_watch.py
  reusing the weekly helpers.
  """
  from __future__ import annotations

  from dataclasses import dataclass
  from pathlib import Path
  from typing import Protocol, runtime_checkable


  @dataclass
  class DriverResult:
      ok: bool
      session_path: Path | None
      stdout_file: Path
      stderr_file: Path
      exit_code: int
      error: str | None


  @runtime_checkable
  class PrebumpDriver(Protocol):
      name: str

      def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult: ...


  DRIVERS: dict[str, PrebumpDriver] = {}
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_framework.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_framework.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): seed PrebumpDriver protocol and registry

  Adds scripts/agent_watch_prebump_drivers.py with the DriverResult
  dataclass, the PrebumpDriver Protocol, and an empty DRIVERS registry
  that per-agent driver tasks will fill.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §4.3
  EOF
  )"
  ```

---

### Task 2.3 — Sandbox construction + teardown helper

**Files**
- Modify: `scripts/agent_watch_prebump_drivers.py`
- Test: `scripts/tests/test_prebump_framework.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  def test_sandbox_creates_temp_home_and_teardown(tmp_path):
      from agent_watch_prebump_drivers import make_sandbox, teardown_sandbox
      sb = make_sandbox(parent=tmp_path, label="codex")
      assert sb.exists()
      assert sb.is_dir()
      assert "codex" in sb.name
      teardown_sandbox(sb, keep=False)
      assert not sb.exists()


  def test_sandbox_keep_preserves_dir(tmp_path):
      from agent_watch_prebump_drivers import make_sandbox, teardown_sandbox
      sb = make_sandbox(parent=tmp_path, label="claude")
      (sb / "marker.txt").write_text("x")
      teardown_sandbox(sb, keep=True)
      assert sb.exists()
      assert (sb / "marker.txt").read_text() == "x"
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_framework.py::test_sandbox_creates_temp_home_and_teardown -v
  ```

  Expected: `ImportError: cannot import name 'make_sandbox'`.

- [ ] **Step 3: Write the minimal implementation.** Append to `scripts/agent_watch_prebump_drivers.py`:

  ```python
  import shutil
  import tempfile


  def make_sandbox(*, parent: Path, label: str) -> Path:
      """Create a fresh temp directory inside *parent* to use as $HOME."""
      parent.mkdir(parents=True, exist_ok=True)
      sb = Path(tempfile.mkdtemp(prefix=f"agent-watch-prebump-{label}-", dir=str(parent)))
      return sb


  def teardown_sandbox(sandbox: Path, *, keep: bool) -> None:
      if keep:
          return
      shutil.rmtree(sandbox, ignore_errors=True)
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_framework.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_framework.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add prebump sandbox helpers

  make_sandbox creates a labelled temp directory under a caller-chosen
  parent (so reports can live alongside the slug dir) and
  teardown_sandbox honors --keep-sandbox. This is the substrate every
  home_override driver uses for HOME isolation.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §4.4 home_override substrate
  EOF
  )"
  ```

---

### Task 2.4 — Credential-copy hygiene gates (size / mode / age)

**Files**
- Modify: `scripts/agent_watch_prebump_drivers.py`
- Test: `scripts/tests/test_prebump_framework.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  import os
  import stat
  import time


  def _make_cred(tmp_path, name, content="secret", mode=0o600, age_days=0):
      p = tmp_path / name
      p.write_text(content)
      os.chmod(p, mode)
      if age_days:
          ts = time.time() - age_days * 86400
          os.utime(p, (ts, ts))
      return p


  def test_credential_hygiene_accepts_small_mode0600_recent(tmp_path):
      from agent_watch_prebump_drivers import check_credential_hygiene, HygieneError
      p = _make_cred(tmp_path, "auth.json", mode=0o600)
      warnings = check_credential_hygiene(p)
      assert warnings == []


  def test_credential_hygiene_rejects_oversize(tmp_path):
      from agent_watch_prebump_drivers import check_credential_hygiene, HygieneError
      p = tmp_path / "huge.json"
      p.write_text("x" * (65 * 1024))
      os.chmod(p, 0o600)
      try:
          check_credential_hygiene(p)
      except HygieneError as e:
          assert "64" in str(e) or "size" in str(e).lower()
      else:
          raise AssertionError("expected HygieneError for oversize file")


  def test_credential_hygiene_rejects_world_readable(tmp_path):
      from agent_watch_prebump_drivers import check_credential_hygiene, HygieneError
      p = _make_cred(tmp_path, "auth.json", mode=0o644)
      try:
          check_credential_hygiene(p)
      except HygieneError as e:
          assert "0600" in str(e)
      else:
          raise AssertionError("expected HygieneError for 0644")


  def test_credential_hygiene_warns_on_old_mtime(tmp_path):
      from agent_watch_prebump_drivers import check_credential_hygiene
      p = _make_cred(tmp_path, "auth.json", mode=0o600, age_days=120)
      warnings = check_credential_hygiene(p)
      assert any("90" in w or "old" in w.lower() for w in warnings)
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_framework.py::test_credential_hygiene_accepts_small_mode0600_recent -v
  ```

  Expected: `ImportError: cannot import name 'check_credential_hygiene'`.

- [ ] **Step 3: Write the minimal implementation.** Append to `scripts/agent_watch_prebump_drivers.py`:

  ```python
  import os
  import stat
  import time


  MAX_CREDENTIAL_BYTES = 64 * 1024
  MAX_CREDENTIAL_AGE_SECONDS = 90 * 86400


  class HygieneError(Exception):
      """Raised when a credential file fails a hard hygiene gate."""


  def check_credential_hygiene(path: Path) -> list[str]:
      """Run the three §4.4 gates on *path*.

      Returns a list of non-fatal warnings. Raises HygieneError on any
      hard failure (oversize, world/group readable).
      """
      try:
          st = os.stat(path)
      except OSError as exc:
          raise HygieneError(f"cannot stat credential {path}: {exc}") from exc
      if st.st_size > MAX_CREDENTIAL_BYTES:
          raise HygieneError(
              f"credential {path} is {st.st_size} bytes (> 64 KiB limit); "
              f"refusing to copy a likely log/history file into sandbox"
          )
      mode_bits = stat.S_IMODE(st.st_mode)
      if mode_bits & 0o077:
          raise HygieneError(
              f"credential {path} has mode {oct(mode_bits)}; require 0600 "
              f"or stricter — run: chmod 600 {path}"
          )
      warnings: list[str] = []
      age = time.time() - st.st_mtime
      if age > MAX_CREDENTIAL_AGE_SECONDS:
          warnings.append(
              f"WARNING: credential {path} is older than 90 days; "
              f"it may have expired — run re-auth if the driver reports auth errors"
          )
      return warnings
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_framework.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_framework.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add credential-copy hygiene gates

  check_credential_hygiene enforces the §4.4 trio: max 64 KiB per file
  and mode 0600-or-stricter are hard failures (HygieneError → exit 4),
  and mtime > 90 days is a non-fatal warning the driver surfaces on
  stderr. Stops a misconfigured credential list from smuggling a log
  into the sandbox.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §4.4 resolved decision #4
  EOF
  )"
  ```

---

### Task 2.5 — Env-var-first auth helper

**Files**
- Modify: `scripts/agent_watch_prebump_drivers.py`
- Test: `scripts/tests/test_prebump_framework.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  def test_prepare_auth_uses_env_var_when_set(tmp_path, monkeypatch):
      from agent_watch_prebump_drivers import prepare_auth
      monkeypatch.setenv("OPENAI_API_KEY", "sk-test-xyz")
      sb = tmp_path / "sb"
      sb.mkdir()
      pb_cfg = {
          "env_vars": ["OPENAI_API_KEY"],
          "credential_files": [str(tmp_path / "auth.json")],  # must NOT be read
      }
      env, warnings = prepare_auth(prebump_cfg=pb_cfg, sandbox=sb, real_home=tmp_path)
      assert env["OPENAI_API_KEY"] == "sk-test-xyz"
      assert env["HOME"] == str(sb)
      assert warnings == []


  def test_prepare_auth_copies_credential_when_env_missing(tmp_path, monkeypatch):
      from agent_watch_prebump_drivers import prepare_auth
      monkeypatch.delenv("OPENAI_API_KEY", raising=False)
      real_home = tmp_path / "realhome"
      real_home.mkdir()
      cred = real_home / ".codex" / "auth.json"
      cred.parent.mkdir()
      cred.write_text('{"token":"abc"}')
      os.chmod(cred, 0o600)

      sb = tmp_path / "sb"
      sb.mkdir()
      pb_cfg = {
          "env_vars": ["OPENAI_API_KEY"],
          "credential_files": [str(cred)],
      }
      env, warnings = prepare_auth(prebump_cfg=pb_cfg, sandbox=sb, real_home=real_home)
      copied = sb / ".codex" / "auth.json"
      assert copied.exists()
      assert copied.read_text() == '{"token":"abc"}'
      assert "OPENAI_API_KEY" not in env
      assert env["HOME"] == str(sb)


  def test_prepare_auth_raises_on_hygiene_failure(tmp_path, monkeypatch):
      from agent_watch_prebump_drivers import prepare_auth, HygieneError
      monkeypatch.delenv("OPENAI_API_KEY", raising=False)
      real_home = tmp_path / "realhome"
      (real_home / ".codex").mkdir(parents=True)
      cred = real_home / ".codex" / "auth.json"
      cred.write_text("x" * 16)
      os.chmod(cred, 0o644)  # world-readable → hard fail
      sb = tmp_path / "sb"
      sb.mkdir()
      pb_cfg = {"env_vars": ["OPENAI_API_KEY"], "credential_files": [str(cred)]}
      try:
          prepare_auth(prebump_cfg=pb_cfg, sandbox=sb, real_home=real_home)
      except HygieneError:
          pass
      else:
          raise AssertionError("expected HygieneError")
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_framework.py::test_prepare_auth_uses_env_var_when_set -v
  ```

  Expected: `ImportError: cannot import name 'prepare_auth'`.

- [ ] **Step 3: Write the minimal implementation.** Append:

  ```python
  def prepare_auth(
      *,
      prebump_cfg: dict,
      sandbox: Path,
      real_home: Path,
  ) -> tuple[dict[str, str], list[str]]:
      """Spec §4.4 env-var-first auth — the **single** auth path for all drivers.

      Drivers MUST NOT build their own env from os.environ.copy(); they
      receive the env dict produced here via _run_prebump.

      Behavior:
      1. Start from os.environ.copy() and pin HOME=str(sandbox).
      2. If any env var listed under prebump_cfg["env_vars"] is set in
         os.environ, forward it into the env dict and skip credential
         copies entirely. (Env-var-first.)
      3. Otherwise, for each path in prebump_cfg["credential_files"]:
         expand ~ against real_home, run check_credential_hygiene
         (raises HygieneError on hard failure → caller maps to exit 4),
         and copy the file into the sandbox under its path relative to
         real_home, clamping to mode 0600.

      Returns (env, warnings). Raises HygieneError on hard failure.
      """
      env = os.environ.copy()
      env["HOME"] = str(sandbox)
      warnings: list[str] = []

      env_vars = list(prebump_cfg.get("env_vars") or [])
      for var in env_vars:
          val = os.environ.get(var)
          if val:
              env[var] = val
              return env, warnings

      cred_specs = list(prebump_cfg.get("credential_files") or [])
      for spec in cred_specs:
          # Expand ~ against real_home so the call site does not have to.
          if isinstance(spec, str) and spec.startswith("~/"):
              cred = real_home / spec[2:]
          else:
              cred = Path(spec)
          if not cred.exists():
              continue
          warnings.extend(check_credential_hygiene(cred))  # raises HygieneError
          try:
              rel = cred.relative_to(real_home)
          except ValueError:
              rel = Path(cred.name)
          dst = sandbox / rel
          dst.parent.mkdir(parents=True, exist_ok=True)
          shutil.copy2(cred, dst)
          os.chmod(dst, 0o600)
      return env, warnings
  ```

  **Important:** This is the only place that reads `prebump_cfg.env_vars`
  and `prebump_cfg.credential_files`. Driver `run()` methods receive the
  resulting `env` dict from `_run_prebump` and must not call
  `os.environ.copy()` themselves.

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_framework.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_framework.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): env-var-first auth as the single driver auth path

  prepare_auth is now the sole place that reads prebump.env_vars and
  prebump.credential_files. It builds the env dict drivers receive
  (HOME pinned to sandbox, plus forwarded env-var if present, otherwise
  hygiene-gated credential copies into the sandbox). Hygiene failures
  raise HygieneError; _run_prebump catches it and exits 4. Drivers no
  longer call os.environ.copy() — they take env via run(sandbox, env,
  prompt, timeout) and pass it directly into subprocess.run.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §4.4 hybrid auth
  EOF
  )"
  ```

---

### Task 2.6 — Prebump report shape + exit-code contract

**Files**
- Modify: `scripts/agent_watch.py`
- Test: `scripts/tests/test_prebump_framework.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  def test_build_prebump_report_shape(tmp_path):
      from agent_watch import _build_prebump_report_entry
      entry = _build_prebump_report_entry(
          agent_name="codex",
          driver_name="codex_exec",
          ok=True,
          session_path=tmp_path / "session.jsonl",
          stdout_file=tmp_path / "stdout.txt",
          stderr_file=tmp_path / "stderr.txt",
          error=None,
          schema_diff={"is_empty": True, "unknown_types": [], "missing_types": [], "unknown_keys": {}, "missing_keys": {}, "unknown_only_is_empty": True},
          fresh_session_matches_baseline=True,
          sample_freshness={"is_stale": False, "stale_reason": "forced_fresh", "mode_context": "normal", "sample_mtime_utc": None, "cli_binary_mtime_utc": None, "cli_binary_path": None, "freshness_window_seconds": 1209600, "sample_older_than_cli": None, "sample_older_than_window": None},
      )
      assert entry["driver"] == "codex_exec"
      assert entry["ok"] is True
      ev = entry["evidence"]
      assert ev["fresh_session_matches_baseline"] is True
      # Spec §3.1: fresh_evidence_available is true ONLY when prebump
      # produced fresh evidence AND it matched baseline.
      assert ev["fresh_evidence_available"] is True
      assert ev["schema_matches_baseline"] is True
      assert ev["sample_freshness"]["stale_reason"] == "forced_fresh"


  def test_exit_code_for_prebump_results():
      from agent_watch import _exit_code_for_prebump
      assert _exit_code_for_prebump([{"ok": True, "evidence": {"fresh_session_matches_baseline": True}}]) == 0
      assert _exit_code_for_prebump([{"ok": True, "evidence": {"fresh_session_matches_baseline": False}}]) == 2
      assert _exit_code_for_prebump([{"ok": False, "error": "cli_failed"}]) == 3
      assert _exit_code_for_prebump([{"ok": False, "error": "hygiene_failed", "fatal": "config"}]) == 4
      # worst wins: any 4 beats 3 beats 2 beats 0
      assert _exit_code_for_prebump([
          {"ok": True, "evidence": {"fresh_session_matches_baseline": True}},
          {"ok": False, "error": "cli_failed"},
          {"ok": False, "error": "hygiene_failed", "fatal": "config"},
      ]) == 4
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_framework.py::test_build_prebump_report_shape -v
  ```

  Expected: `ImportError: cannot import name '_build_prebump_report_entry'`.

- [ ] **Step 3: Write the minimal implementation.** In `scripts/agent_watch.py` above `main()`:

  ```python
  def _build_prebump_report_entry(
      *,
      agent_name: str,
      driver_name: str,
      ok: bool,
      session_path: Path | None,
      stdout_file: Path | None,
      stderr_file: Path | None,
      error: str | None,
      schema_diff: dict[str, Any] | None,
      fresh_session_matches_baseline: bool | None,
      sample_freshness: dict[str, Any] | None,
  ) -> dict[str, Any]:
      return {
          "agent": agent_name,
          "driver": driver_name,
          "ok": ok,
          "session_path": str(session_path) if session_path else None,
          "stdout_file": str(stdout_file) if stdout_file else None,
          "stderr_file": str(stderr_file) if stderr_file else None,
          "error": error,
          "evidence": {
              "schema_matches_baseline": fresh_session_matches_baseline,
              "fresh_session_matches_baseline": fresh_session_matches_baseline,
              # Spec §3.1: true ONLY when prebump produced fresh evidence
              # AND it matched baseline.
              "fresh_evidence_available": fresh_session_matches_baseline is True,
              "schema_diff": schema_diff,
              "sample_freshness": sample_freshness,
          },
      }


  def _exit_code_for_prebump(entries: list[dict[str, Any]]) -> int:
      worst = 0
      for e in entries:
          if e.get("fatal") == "config":
              worst = max(worst, 4)
              continue
          if not e.get("ok"):
              worst = max(worst, 3)
              continue
          ev = e.get("evidence") or {}
          if ev.get("fresh_session_matches_baseline") is False:
              worst = max(worst, 2)
      return worst
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_framework.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch.py scripts/tests/test_prebump_framework.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): prebump report entry shape + exit-code mapping

  Adds _build_prebump_report_entry so every driver result serializes
  the same way (agent, driver, stdout/stderr files, schema_diff,
  fresh_session_matches_baseline, sample_freshness), and
  _exit_code_for_prebump that maps the aggregated entries to the §4.2
  exit-code contract (0/2/3/4 with worst-wins precedence).

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §4.2 exit codes and §4.5 evidence shape
  EOF
  )"
  ```

---

### Task 2.7 — Prebump dispatch: prepare_auth, sandbox, driver, discovery validation, fingerprint, report

This task is intentionally larger than the others in Phase 2: it folds in the discovery-contract validator (`_validate_session_discovery`), wires `prepare_auth` as the single auth path, and pins the CLI-flag-over-config timeout precedence.



**Files**
- Modify: `scripts/agent_watch.py`
- Test: `scripts/tests/test_prebump_framework.py`

- [ ] **Step 1: Write the failing test.** Append:

  ```python
  def _make_codex_cfg(tmp_path, *, timeout_cfg=10, required_types=("session_meta",)):
      return {
          "report_root": str(tmp_path / "out"),
          "agents": {
              "codex": {
                  "installed_version_cmd": ["codex", "--version"],
                  "prebump": {
                      "driver": "fake",
                      "sandbox": {"mode": "home_override", "subdir": "codex_sandbox"},
                      "prompt": "hi",
                      "timeout_seconds": timeout_cfg,
                      "env_vars": [],
                      "credential_files": [],
                      "discover_session": {
                          "kind": "jsonl_newest",
                          "roots": [".codex/sessions"],
                          "globs": ["**/*.jsonl"],
                          "required_types": list(required_types),
                      },
                  },
              }
          },
      }


  class _FakeGoodDriver:
      name = "fake"

      def __init__(self):
          self.last_env = None
          self.last_timeout = None

      def run(self, sandbox, env, prompt, timeout):
          import agent_watch_prebump_drivers as drv_mod
          self.last_env = dict(env)
          self.last_timeout = timeout
          # Write a session under the configured discovery root so
          # _validate_session_discovery passes.
          sp_dir = sandbox / ".codex" / "sessions"
          sp_dir.mkdir(parents=True, exist_ok=True)
          sp = sp_dir / "rollout-fake.jsonl"
          sp.write_text('{"type":"session_meta","id":"x"}\n')
          return drv_mod.DriverResult(
              ok=True,
              session_path=sp,
              stdout_file=sandbox / "out.txt",
              stderr_file=sandbox / "err.txt",
              exit_code=0,
              error=None,
          )


  def test_run_prebump_uses_registered_driver_and_writes_report(tmp_path, monkeypatch):
      import agent_watch
      import agent_watch_prebump_drivers as drv_mod

      fake = _FakeGoodDriver()
      monkeypatch.setitem(drv_mod.DRIVERS, "fake", fake)

      cfg = _make_codex_cfg(tmp_path)
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      rc = agent_watch.main([
          "--mode", "prebump",
          "--config", str(cfg_path),
          "--agent", "codex",
          "--keep-sandbox",
      ])
      assert rc in (0, 2)  # driver ran cleanly; baseline diff may vary
      reports = list((tmp_path / "out").glob("*-prebump/report.json"))
      assert len(reports) == 1
      report = json.loads(reports[0].read_text())
      assert report["mode"] == "prebump"
      codex_entry = report["results"]["codex"]
      assert codex_entry["driver"] == "fake"
      assert codex_entry["ok"] is True
      # F2: env was constructed by prepare_auth and passed in.
      assert "HOME" in fake.last_env
      assert fake.last_env["HOME"] != os.environ.get("HOME", "")


  def test_run_prebump_timeout_cli_overrides_config(tmp_path, monkeypatch):
      import agent_watch
      import agent_watch_prebump_drivers as drv_mod

      fake = _FakeGoodDriver()
      monkeypatch.setitem(drv_mod.DRIVERS, "fake", fake)

      cfg = _make_codex_cfg(tmp_path, timeout_cfg=180)
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      agent_watch.main([
          "--mode", "prebump",
          "--config", str(cfg_path),
          "--agent", "codex",
          "--timeout-seconds", "30",
          "--keep-sandbox",
      ])
      # CLI flag (30) wins over per-agent config (180).
      assert fake.last_timeout == 30


  def test_run_prebump_timeout_falls_back_to_config_when_cli_absent(tmp_path, monkeypatch):
      import agent_watch
      import agent_watch_prebump_drivers as drv_mod

      fake = _FakeGoodDriver()
      monkeypatch.setitem(drv_mod.DRIVERS, "fake", fake)
      cfg = _make_codex_cfg(tmp_path, timeout_cfg=77)
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      agent_watch.main([
          "--mode", "prebump",
          "--config", str(cfg_path),
          "--agent", "codex",
          "--keep-sandbox",
      ])
      assert fake.last_timeout == 77


  def test_run_prebump_discovery_violation_maps_to_exit_3(tmp_path, monkeypatch):
      """F4: a driver that returns a session outside the declared roots
      or missing required_types is a driver-failed result (exit 3)."""
      import agent_watch
      import agent_watch_prebump_drivers as drv_mod

      class _BadRootDriver:
          name = "fake"

          def run(self, sandbox, env, prompt, timeout):
              # Write outside .codex/sessions → root violation
              bad = sandbox / "elsewhere" / "rollout.jsonl"
              bad.parent.mkdir(parents=True, exist_ok=True)
              bad.write_text('{"type":"session_meta"}\n')
              return drv_mod.DriverResult(
                  ok=True, session_path=bad,
                  stdout_file=sandbox / "o", stderr_file=sandbox / "e",
                  exit_code=0, error=None,
              )

      monkeypatch.setitem(drv_mod.DRIVERS, "fake", _BadRootDriver())
      cfg = _make_codex_cfg(tmp_path)
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      rc = agent_watch.main([
          "--mode", "prebump", "--config", str(cfg_path),
          "--agent", "codex", "--keep-sandbox",
      ])
      assert rc == 3


  def test_run_prebump_discovery_nested_glob_pattern_matches(tmp_path, monkeypatch):
      """B: the **/ rewrite must match a file two directories below root."""
      import agent_watch
      import agent_watch_prebump_drivers as drv_mod

      class _NestedDriver:
          name = "fake"

          def run(self, sandbox, env, prompt, timeout):
              # Two levels below .codex/sessions: .codex/sessions/2026/04/11/
              deep = sandbox / ".codex" / "sessions" / "2026" / "04" / "11"
              deep.mkdir(parents=True, exist_ok=True)
              sp = deep / "rollout-nested.jsonl"
              sp.write_text('{"type":"session_meta","id":"x"}\n')
              return drv_mod.DriverResult(
                  ok=True, session_path=sp,
                  stdout_file=sandbox / "o", stderr_file=sandbox / "e",
                  exit_code=0, error=None,
              )

      monkeypatch.setitem(drv_mod.DRIVERS, "fake", _NestedDriver())
      cfg = _make_codex_cfg(tmp_path)
      # Pattern with ** must match a nested file under the root.
      cfg["agents"]["codex"]["prebump"]["discover_session"]["globs"] = ["**/rollout-*.jsonl"]
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      rc = agent_watch.main([
          "--mode", "prebump", "--config", str(cfg_path),
          "--agent", "codex", "--keep-sandbox",
      ])
      # No discovery violation (rc != 3); gate passed; baseline diff may vary.
      assert rc in (0, 2)


  def test_run_prebump_config_gate_missing_discover_session(tmp_path, monkeypatch):
      """A: selected agent with no prebump.discover_session exits 4."""
      import agent_watch
      import agent_watch_prebump_drivers as drv_mod

      monkeypatch.setitem(drv_mod.DRIVERS, "fake", _FakeGoodDriver())
      cfg = _make_codex_cfg(tmp_path)
      cfg["agents"]["codex"]["prebump"].pop("discover_session", None)
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      rc = agent_watch.main([
          "--mode", "prebump", "--config", str(cfg_path),
          "--agent", "codex", "--keep-sandbox",
      ])
      assert rc == 4


  def test_run_prebump_config_gate_empty_roots(tmp_path, monkeypatch, capsys):
      """A: roots: [] exits 4 with a stderr message naming the agent."""
      import agent_watch
      import agent_watch_prebump_drivers as drv_mod

      monkeypatch.setitem(drv_mod.DRIVERS, "fake", _FakeGoodDriver())
      cfg = _make_codex_cfg(tmp_path)
      cfg["agents"]["codex"]["prebump"]["discover_session"]["roots"] = []
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      rc = agent_watch.main([
          "--mode", "prebump", "--config", str(cfg_path),
          "--agent", "codex", "--keep-sandbox",
      ])
      assert rc == 4
      err = capsys.readouterr().err
      assert "codex" in err
      assert "roots" in err


  def test_run_prebump_config_gate_allows_empty_required_types(tmp_path, monkeypatch):
      """A: valid contract with required_types: [] passes the gate
      (Copilot case — must not regress)."""
      import agent_watch
      import agent_watch_prebump_drivers as drv_mod

      monkeypatch.setitem(drv_mod.DRIVERS, "fake", _FakeGoodDriver())
      cfg = _make_codex_cfg(tmp_path, required_types=())
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      rc = agent_watch.main([
          "--mode", "prebump", "--config", str(cfg_path),
          "--agent", "codex", "--keep-sandbox",
      ])
      # Gate passes; driver runs; result depends on baseline diff.
      assert rc in (0, 2)


  def test_run_prebump_discovery_missing_required_type_maps_to_exit_3(tmp_path, monkeypatch):
      import agent_watch
      import agent_watch_prebump_drivers as drv_mod

      class _NoTypesDriver:
          name = "fake"

          def run(self, sandbox, env, prompt, timeout):
              sp_dir = sandbox / ".codex" / "sessions"
              sp_dir.mkdir(parents=True, exist_ok=True)
              sp = sp_dir / "rollout.jsonl"
              # Has 'token_count' but no 'session_meta' → required_types fail
              sp.write_text('{"type":"token_count","total":1}\n')
              return drv_mod.DriverResult(
                  ok=True, session_path=sp,
                  stdout_file=sandbox / "o", stderr_file=sandbox / "e",
                  exit_code=0, error=None,
              )

      monkeypatch.setitem(drv_mod.DRIVERS, "fake", _NoTypesDriver())
      cfg = _make_codex_cfg(tmp_path)
      cfg_path = tmp_path / "cfg.json"
      cfg_path.write_text(json.dumps(cfg))
      monkeypatch.chdir(REPO)
      rc = agent_watch.main([
          "--mode", "prebump", "--config", str(cfg_path),
          "--agent", "codex", "--keep-sandbox",
      ])
      assert rc == 3
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_framework.py::test_run_prebump_uses_registered_driver_and_writes_report -v
  ```

  Expected: fails because `_run_prebump` stub just returns 0 and writes nothing.

- [ ] **Step 3: Write the minimal implementation.** Add the discovery-validator helper above `_run_prebump` and rewrite `_run_prebump` so prepare_auth is the single auth path, the driver receives an explicit `env`, the discovery contract is validated, and CLI `--timeout-seconds` wins over per-agent config.

  ```python
  class _DiscoveryViolation(Exception):
      """Raised when a driver result violates discover_session contract."""


  def _session_path_matches_glob(session_path: Path, root: Path, pattern: str) -> bool:
      """Return True if session_path is among the files yielded by root.glob(pattern).

      Delegates glob walking to pathlib itself (root.glob) so ** spans
      nested directories regardless of the host interpreter's pattern
      semantics. Resolves both sides so symlinked sandbox HOMEs compare
      equal.

      Performance: root.glob(pattern) walks the directory tree on every
      call. That is fine for per-agent prebump runs (one session per run,
      tiny sandbox HOME) but must not be used in hot loops — keep it
      scoped to post-run validation.
      """
      try:
          session_resolved = session_path.resolve()
      except (OSError, RuntimeError):
          return False
      for candidate in root.glob(pattern):
          try:
              if candidate.resolve() == session_resolved:
                  return True
          except (OSError, RuntimeError):
              continue
      return False


  def _validate_session_discovery(session_path: Path, contract: dict, sandbox: Path) -> None:
      """F4: validate session_path against the agent's discover_session contract.

      Checks (each failure raises _DiscoveryViolation):
        1. session_path is under one of contract['roots'], where each root
           is interpreted relative to *sandbox* (sandbox-HOME substitution).
        2. session_path is yielded by root.glob(pattern) for one of the
           declared (root, glob) pairs — see _session_path_matches_glob.
        3. The file parses as JSONL and contains at least one line per
           type in contract['required_types'] (matched on the per-line
           'type' field).

      Discovery violations are mapped to exit 3 (driver-failed) by the
      caller — the driver produced the wrong artifact.

      Note on key tolerance: this runtime validator accepts BOTH modern
      ("roots"/"globs") and legacy ("roots_relative_to_sandbox"/"glob")
      config keys so older on-disk configs keep validating cleanly. The
      config gate in _run_prebump deliberately only accepts the modern
      form — the asymmetry is intentional; do not "fix" it.
      """
      if not isinstance(contract, dict):
          return  # no contract declared → skip (see residual risk note)
      try:
          session_path = session_path.resolve()
      except OSError as exc:
          raise _DiscoveryViolation(f"cannot resolve session_path: {exc}") from exc

      roots = contract.get("roots") or contract.get("roots_relative_to_sandbox") or []
      # Resolve the declared roots to absolute sandbox-relative paths once.
      resolved_roots: list[Path] = []
      for root_spec in roots:
          resolved_roots.append((sandbox / str(root_spec).lstrip("/")).resolve())
      if resolved_roots:
          ok = False
          for root in resolved_roots:
              try:
                  session_path.relative_to(root)
                  ok = True
                  break
              except ValueError:
                  continue
          if not ok:
              raise _DiscoveryViolation(
                  f"session {session_path} is not under any declared root in {roots}"
              )

      globs = contract.get("globs")
      if not globs:
          single = contract.get("glob")
          globs = [single] if single else []
      if globs and resolved_roots:
          # Iterate every (root, glob) pair; succeed on the first match.
          matched = False
          for root in resolved_roots:
              for pattern in globs:
                  if _session_path_matches_glob(session_path, root, pattern):
                      matched = True
                      break
              if matched:
                  break
          if not matched:
              raise _DiscoveryViolation(
                  f"session {session_path} does not match any (root, glob) pair "
                  f"in roots={roots} globs={globs}"
              )

      required_types = list(contract.get("required_types") or [])
      if required_types:
          seen: set[str] = set()
          try:
              with session_path.open("r", encoding="utf-8") as fh:
                  for line in fh:
                      line = line.strip()
                      if not line:
                          continue
                      try:
                          obj = json.loads(line)
                      except json.JSONDecodeError as exc:
                          raise _DiscoveryViolation(
                              f"session {session_path} is not valid JSONL: {exc}"
                          ) from exc
                      t = obj.get("type") if isinstance(obj, dict) else None
                      if isinstance(t, str):
                          seen.add(t)
          except OSError as exc:
              raise _DiscoveryViolation(f"cannot read session: {exc}") from exc
          missing = [t for t in required_types if t not in seen]
          if missing:
              raise _DiscoveryViolation(
                  f"session {session_path} missing required types {missing}; saw {sorted(seen)}"
              )


  def _run_prebump(
      args,
      cfg: dict[str, Any],
      *,
      report_dir: Path,
      verified_map: dict[str, str | None],
      evidence: dict[str, list[str]],
  ) -> int:
      import agent_watch_prebump_drivers as drv_mod

      prebump_dir = report_dir.parent / (report_dir.name + "-prebump")
      prebump_dir.mkdir(parents=True, exist_ok=True)

      agents_cfg = cfg.get("agents") or {}
      configured_prebump_agents = {
          name for name, acfg in agents_cfg.items()
          if isinstance(acfg, dict) and isinstance(acfg.get("prebump"), dict)
      }
      requested = list(args.agent or [])
      if requested:
          unknown = [a for a in requested if a not in configured_prebump_agents]
          if unknown:
              import sys as _sys
              _sys.stderr.write(
                  "agent_watch --mode prebump: rejected agent(s) "
                  f"{unknown}: not in configured prebump set "
                  f"{sorted(configured_prebump_agents)}\n"
              )
              return 4
          selected = set(requested)
      else:
          selected = set(configured_prebump_agents)

      prebump_agents = {name: agents_cfg[name] for name in selected}
      if not prebump_agents:
          return 0

      # F1/A: discovery-contract config gate. Every selected agent must
      # declare a well-formed prebump.discover_session contract using the
      # modern roots/globs keys. Collect ALL failures across the selected
      # set before bailing so the user can fix everything in one pass.
      gate_failures: list[dict[str, Any]] = []
      for _name, _acfg in prebump_agents.items():
          _pb = _acfg.get("prebump") or {}
          _ds = _pb.get("discover_session")
          if not isinstance(_ds, dict):
              gate_failures.append({
                  "agent": _name,
                  "driver": _pb.get("driver"),
                  "ok": False,
                  "error": f"config_gate:{_name}: prebump.discover_session missing or not a dict",
                  "fatal": "config",
                  "evidence": {},
              })
              continue
          _roots = _ds.get("roots")
          _globs = _ds.get("globs")
          _req = _ds.get("required_types", [])
          _reasons: list[str] = []
          if not isinstance(_roots, list) or len(_roots) < 1:
              _reasons.append("roots must be a non-empty list")
          if not isinstance(_globs, list) or len(_globs) < 1:
              _reasons.append("globs must be a non-empty list")
          # required_types is OPTIONAL: missing key or empty list is fine
          # (Copilot declares required_types: [] by design).
          if "required_types" in _ds and not isinstance(_req, list):
              _reasons.append("required_types must be a list when present")
          if _reasons:
              import sys as _sys
              _msg = f"config_gate:{_name}: " + "; ".join(_reasons)
              _sys.stderr.write(
                  f"agent_watch --mode prebump: {_msg}\n"
              )
              gate_failures.append({
                  "agent": _name,
                  "driver": _pb.get("driver"),
                  "ok": False,
                  "error": _msg,
                  "fatal": "config",
                  "evidence": {},
              })
      if gate_failures:
          # Do not run any driver; let the user fix all config errors at
          # once. Write a report entry per failing agent and exit 4.
          report = {
              "timestamp_utc": datetime.now(timezone.utc).isoformat(),
              "mode": "prebump",
              "report_dir": _safe_relpath(prebump_dir),
              "results": {e["agent"]: e for e in gate_failures},
          }
          (prebump_dir / "report.json").write_text(
              json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
          )
          return 4

      entries: list[dict[str, Any]] = []
      now_epoch = datetime.now(timezone.utc).timestamp()
      real_home = Path(os.environ.get("HOME", str(Path.home())))

      for agent_name, agent_cfg in prebump_agents.items():
          pb = agent_cfg["prebump"]
          driver_name = pb.get("driver")
          driver = drv_mod.DRIVERS.get(driver_name) if isinstance(driver_name, str) else None
          agent_out = prebump_dir / agent_name
          agent_out.mkdir(parents=True, exist_ok=True)

          if driver is None:
              entries.append({
                  "agent": agent_name,
                  "driver": driver_name,
                  "ok": False,
                  "error": f"unknown_driver:{driver_name}",
                  "fatal": "config",
                  "evidence": {},
              })
              continue

          try:
              sandbox = drv_mod.make_sandbox(parent=agent_out, label=agent_name)
          except Exception as exc:
              entries.append({
                  "agent": agent_name,
                  "driver": driver_name,
                  "ok": False,
                  "error": f"sandbox_create_failed:{exc}",
                  "fatal": "config",
                  "evidence": {},
              })
              continue

          # F2: prepare_auth is the only auth path. Drivers receive env.
          try:
              env, auth_warnings = drv_mod.prepare_auth(
                  prebump_cfg=pb, sandbox=sandbox, real_home=real_home,
              )
          except drv_mod.HygieneError as exc:
              entries.append({
                  "agent": agent_name,
                  "driver": driver_name,
                  "ok": False,
                  "error": f"hygiene_failed:{exc}",
                  "fatal": "config",
                  "evidence": {},
              })
              drv_mod.teardown_sandbox(sandbox, keep=args.keep_sandbox)
              continue

          prompt = str(pb.get("prompt") or "")
          # F6: CLI flag wins by default; fall back to per-agent config; then global default.
          if args.timeout_seconds is not None:
              timeout = int(args.timeout_seconds)
          else:
              timeout = int(pb.get("timeout_seconds") or DEFAULT_TIMEOUT_SECONDS)

          try:
              result = driver.run(sandbox, env, prompt, timeout)
          except drv_mod.HygieneError as exc:
              entries.append({
                  "agent": agent_name,
                  "driver": driver_name,
                  "ok": False,
                  "error": f"hygiene_failed:{exc}",
                  "fatal": "config",
                  "evidence": {},
              })
              drv_mod.teardown_sandbox(sandbox, keep=args.keep_sandbox)
              continue
          except Exception as exc:
              entries.append({
                  "agent": agent_name,
                  "driver": driver_name,
                  "ok": False,
                  "error": f"driver_exception:{exc}",
                  "evidence": {},
              })
              drv_mod.teardown_sandbox(sandbox, keep=args.keep_sandbox)
              continue

          # F4: validate the session against the discover_session contract.
          if result.ok and result.session_path and result.session_path.exists():
              try:
                  _validate_session_discovery(
                      result.session_path,
                      pb.get("discover_session") or {},
                      sandbox,
                  )
              except _DiscoveryViolation as exc:
                  entries.append({
                      "agent": agent_name,
                      "driver": driver_name,
                      "ok": False,
                      "error": f"discovery_violation:{exc}",
                      "evidence": {},
                  })
                  drv_mod.teardown_sandbox(sandbox, keep=(args.keep_sandbox or True))
                  continue

          schema_diff: dict[str, Any] | None = None
          fresh_matches: bool | None = None
          if result.ok and result.session_path and result.session_path.exists():
              matrix_key = {
                  "codex": "codex_cli", "claude": "claude_code", "copilot": "copilot_cli",
                  "droid": "droid", "gemini": "gemini_cli", "opencode": "opencode",
                  "openclaw": "openclaw",
              }.get(agent_name)
              baseline_paths = evidence.get(matrix_key or "", []) if matrix_key else []
              baseline_type_keys = _baseline_type_keys_for_agent(agent_name, baseline_paths)
              if agent_name == "gemini":
                  fp = _gemini_session_json_schema_fingerprint(result.session_path, max_messages=5000)
              elif agent_name == "opencode":
                  fp = _opencode_storage_session_tree_schema_fingerprint(
                      result.session_path, max_messages=250, max_parts=2500
                  )
              else:
                  fp = _jsonl_schema_fingerprint(result.session_path, max_lines=5000)
              if baseline_type_keys:
                  schema_diff = _schema_diff(
                      observed_type_keys=fp.get("type_keys") or {},
                      baseline_type_keys=baseline_type_keys,
                  )
                  fresh_matches = bool(schema_diff.get("unknown_only_is_empty"))
              else:
                  fresh_matches = True  # no baseline → nothing diffs

          cli_path, cli_mtime = _resolve_cli_binary_mtime(
              agent_cfg.get("installed_version_cmd") if isinstance(agent_cfg.get("installed_version_cmd"), list) else None
          )
          sample_mtime = None
          if result.session_path and result.session_path.exists():
              try:
                  sample_mtime = float(result.session_path.stat().st_mtime)
              except OSError:
                  sample_mtime = None
          window_days = int(((agent_cfg.get("weekly") or {}).get("freshness_window_days") or 14))
          sf = _compute_sample_freshness(
              sample_mtime=sample_mtime,
              cli_binary_path=cli_path,
              cli_binary_mtime=cli_mtime,
              freshness_window_seconds=window_days * 86400,
              now_epoch=now_epoch,
              mode_context="normal",
              force_fresh=bool(getattr(args, "force_fresh", False)),
          )

          entry = _build_prebump_report_entry(
              agent_name=agent_name,
              driver_name=driver_name,
              ok=bool(result.ok),
              session_path=result.session_path,
              stdout_file=result.stdout_file,
              stderr_file=result.stderr_file,
              error=result.error,
              schema_diff=schema_diff,
              fresh_session_matches_baseline=fresh_matches,
              sample_freshness=sf,
          )
          entries.append(entry)
          drv_mod.teardown_sandbox(sandbox, keep=(args.keep_sandbox or not result.ok))

      report = {
          "timestamp_utc": datetime.now(timezone.utc).isoformat(),
          "mode": "prebump",
          "report_dir": _safe_relpath(prebump_dir),
          "results": {e["agent"]: e for e in entries},
      }
      (prebump_dir / "report.json").write_text(
          json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
      )

      rc = _exit_code_for_prebump(entries)
      print(f"Agent watch (prebump) report: {prebump_dir / 'report.json'}")
      for e in entries:
          ev = e.get("evidence") or {}
          fsmb = ev.get("fresh_session_matches_baseline")
          print(f"{e['agent']}: driver={e.get('driver')} ok={e.get('ok')} fresh_matches_baseline={fsmb} error={e.get('error')}")
      return rc
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_framework.py -v
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch.py scripts/tests/test_prebump_framework.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): implement prebump dispatch and report writer

  _run_prebump now walks the prebump-enabled agents, rejects unknown
  --agent values with exit 4, builds a sandbox per agent, calls
  prepare_auth to construct the driver env (with hygiene gates), passes
  the env explicitly into driver.run(sandbox, env, prompt, timeout),
  validates the resulting session against the discover_session contract
  (root / glob / required_types) with violations mapped to exit 3,
  fingerprints with the same helpers weekly uses, and writes
  <slug>-prebump/report.json. CLI --timeout-seconds wins over per-agent
  config; falls back to config, then DEFAULT_TIMEOUT_SECONDS. Exit code
  follows _exit_code_for_prebump with worst-wins precedence.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §4.5 integration
  EOF
  )"
  ```

---

## Phase 3 — Per-agent prebump drivers

### Task 3.1 — Codex driver (`codex_exec`)

**Files**
- Modify: `scripts/agent_watch_prebump_drivers.py`, `docs/agent-support/agent-watch-config.json`
- Test: `scripts/tests/test_prebump_driver_codex.py`

- [ ] **Step 1: Write the failing test.**

  ```python
  # scripts/tests/test_prebump_driver_codex.py
  import json
  import os
  import sys
  from pathlib import Path
  from unittest import mock

  REPO = Path(__file__).resolve().parents[2]
  sys.path.insert(0, str(REPO / "scripts"))

  import agent_watch_prebump_drivers as drv_mod


  def test_codex_driver_runs_and_returns_session(tmp_path, monkeypatch):
      sb = tmp_path / "sb"
      sb.mkdir()

      def fake_run(argv, *, env=None, **kwargs):
          # F3: read the env that was actually passed into subprocess.run,
          # NOT os.environ — drivers pass env explicitly.
          assert env is not None, "driver must pass env=... to subprocess.run"
          assert env.get("HOME") == str(sb)
          codex_home = Path(env["CODEX_HOME"])
          assert str(codex_home).startswith(str(sb))
          sess_dir = codex_home / "sessions" / "2026" / "04" / "11"
          sess_dir.mkdir(parents=True, exist_ok=True)
          out = sess_dir / "rollout-fake.jsonl"
          out.write_text('{"type":"session_meta","id":"x"}\n{"type":"token_count","total":1}\n')

          import subprocess as _sp
          return _sp.CompletedProcess(argv, 0, stdout="ok", stderr="")

      env = {"HOME": str(sb), "CODEX_HOME": str(sb / ".codex"), "OPENAI_API_KEY": "sk-test"}
      with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
          driver = drv_mod.DRIVERS["codex_exec"]
          res = driver.run(sb, env, "List files.", timeout=30)

      assert res.ok is True
      assert res.session_path is not None
      assert res.session_path.exists()
      assert res.session_path.name.startswith("rollout-")


  def test_codex_config_has_prebump_block():
      cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
      pb = cfg["agents"]["codex"]["prebump"]
      assert pb["driver"] == "codex_exec"
      assert pb["sandbox"]["mode"] == "home_override"
      assert isinstance(pb["prompt"], str) and pb["prompt"].strip()
      assert pb["discover_session"]["globs"][0].endswith(".jsonl")
      assert pb["discover_session"]["roots"] == [".codex/sessions"]
      assert "session_meta" in pb["discover_session"]["required_types"]
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_driver_codex.py -v
  ```

  Expected: `KeyError: 'codex_exec'` (no driver registered) and `KeyError: 'prebump'` (no config block).

- [ ] **Step 3: Write the minimal implementation.** Append to `scripts/agent_watch_prebump_drivers.py`:

  ```python
  import subprocess


  class CodexExecDriver:
      name = "codex_exec"

      def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
          codex_home = sandbox / ".codex"
          codex_home.mkdir(parents=True, exist_ok=True)
          # F2: env is built by prepare_auth in _run_prebump. The driver
          # only adds CLI-specific HOME-relative pins; it never calls
          # os.environ.copy().
          env = dict(env)
          env["CODEX_HOME"] = str(codex_home)
          stdout_file = sandbox / "codex.stdout.txt"
          stderr_file = sandbox / "codex.stderr.txt"
          try:
              proc = subprocess.run(
                  ["codex", "exec", "--sandbox", "read-only", prompt],
                  env=env,
                  stdout=subprocess.PIPE,
                  stderr=subprocess.PIPE,
                  text=True,
                  check=False,
                  timeout=timeout,
              )
              stdout_file.write_text(proc.stdout or "")
              stderr_file.write_text(proc.stderr or "")
              rc = proc.returncode
          except subprocess.TimeoutExpired as exc:
              stdout_file.write_text("")
              stderr_file.write_text(f"timeout after {timeout}s: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 124, f"timeout:{timeout}")
          except FileNotFoundError as exc:
              stderr_file.write_text(f"codex not found: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 127, "codex_not_found")

          # Discover the newest rollout file under the sandboxed CODEX_HOME.
          sessions_root = codex_home / "sessions"
          newest: Path | None = None
          newest_m = -1.0
          if sessions_root.exists():
              for p in sessions_root.rglob("rollout-*.jsonl"):
                  try:
                      m = p.stat().st_mtime
                  except OSError:
                      continue
                  if m > newest_m:
                      newest = p
                      newest_m = m

          if rc != 0 or newest is None:
              return DriverResult(False, newest, stdout_file, stderr_file, rc, f"codex_exec_failed rc={rc}")
          return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


  DRIVERS["codex_exec"] = CodexExecDriver()
  ```

  In `docs/agent-support/agent-watch-config.json`, add to `agents.codex`:

  ```json
      "prebump": {
        "driver": "codex_exec",
        "sandbox": {"mode": "home_override", "subdir": "codex_sandbox"},
        "prompt": "List files in the current directory.",
        "timeout_seconds": 180,
        "env_vars": ["OPENAI_API_KEY"],
        "credential_files": ["~/.codex/auth.json"],
        "discover_session": {
          "kind": "jsonl_newest",
          "roots": [".codex/sessions"],
          "globs": ["**/rollout-*.jsonl"],
          "required_types": ["session_meta"]
        }
      }
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_driver_codex.py -v
  python -c "import json; json.load(open('docs/agent-support/agent-watch-config.json'))"
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_driver_codex.py docs/agent-support/agent-watch-config.json
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add codex_exec prebump driver

  Runs codex exec --sandbox read-only inside a HOME-overridden temp
  directory with CODEX_HOME pinned to the sandbox, then picks up the
  newest rollout-*.jsonl the binary wrote under the sandbox. Config
  gains agents.codex.prebump pointing at this driver.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §5 codex row — v1
  EOF
  )"
  ```

---

### Task 3.2 — Claude driver (`claude_print`)

**Files**
- Modify: `scripts/agent_watch_prebump_drivers.py`, `docs/agent-support/agent-watch-config.json`
- Test: `scripts/tests/test_prebump_driver_claude.py`

- [ ] **Step 1: Write the failing test.**

  ```python
  # scripts/tests/test_prebump_driver_claude.py
  import json
  import os
  import sys
  from pathlib import Path
  from unittest import mock

  REPO = Path(__file__).resolve().parents[2]
  sys.path.insert(0, str(REPO / "scripts"))

  import agent_watch_prebump_drivers as drv_mod


  def test_claude_driver_runs_and_returns_session(tmp_path, monkeypatch):
      sb = tmp_path / "sb"
      sb.mkdir()

      def fake_run(argv, *, env=None, **kwargs):
          # F3: read env explicitly, not os.environ.
          assert env is not None
          assert env.get("HOME") == str(sb)
          home = Path(env["HOME"])
          proj = home / ".claude" / "projects" / "repo-hash"
          proj.mkdir(parents=True, exist_ok=True)
          sid = argv[argv.index("--session-id") + 1]
          out = proj / f"{sid}.jsonl"
          out.write_text('{"type":"user","content":"hi"}\n{"type":"assistant","content":"hello"}\n')

          import subprocess as _sp
          return _sp.CompletedProcess(argv, 0, stdout="{}", stderr="")

      env = {"HOME": str(sb), "ANTHROPIC_API_KEY": "sk-ant-test"}
      with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
          driver = drv_mod.DRIVERS["claude_print"]
          res = driver.run(sb, env, "Say hi, then use the Bash tool to run pwd.", timeout=30)

      assert res.ok is True
      assert res.session_path is not None
      assert res.session_path.suffix == ".jsonl"


  def test_claude_config_has_prebump_block():
      cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
      pb = cfg["agents"]["claude"]["prebump"]
      assert pb["driver"] == "claude_print"
      assert pb["sandbox"]["mode"] == "home_override"
      assert "ANTHROPIC_API_KEY" in pb["env_vars"]
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_driver_claude.py -v
  ```

  Expected: `KeyError: 'claude_print'`.

- [ ] **Step 3: Write the minimal implementation.** Append to `scripts/agent_watch_prebump_drivers.py`:

  ```python
  import uuid as _uuid


  class ClaudePrintDriver:
      name = "claude_print"

      def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
          claude_home = sandbox / ".claude"
          claude_home.mkdir(parents=True, exist_ok=True)
          # F2: env comes from prepare_auth; do not call os.environ.copy().
          env = dict(env)
          session_id = str(_uuid.uuid4())
          stdout_file = sandbox / "claude.stdout.txt"
          stderr_file = sandbox / "claude.stderr.txt"
          try:
              proc = subprocess.run(
                  [
                      "claude", "-p",
                      "--output-format", "stream-json",
                      "--session-id", session_id,
                      prompt,
                  ],
                  env=env,
                  stdout=subprocess.PIPE,
                  stderr=subprocess.PIPE,
                  text=True,
                  check=False,
                  timeout=timeout,
              )
              stdout_file.write_text(proc.stdout or "")
              stderr_file.write_text(proc.stderr or "")
              rc = proc.returncode
          except subprocess.TimeoutExpired as exc:
              stdout_file.write_text("")
              stderr_file.write_text(f"timeout after {timeout}s: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 124, f"timeout:{timeout}")
          except FileNotFoundError as exc:
              stderr_file.write_text(f"claude not found: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 127, "claude_not_found")

          projects_root = claude_home / "projects"
          newest: Path | None = None
          newest_m = -1.0
          if projects_root.exists():
              for p in projects_root.rglob(f"{session_id}.jsonl"):
                  try:
                      m = p.stat().st_mtime
                  except OSError:
                      continue
                  if m > newest_m:
                      newest = p
                      newest_m = m
              if newest is None:
                  for p in projects_root.rglob("*.jsonl"):
                      try:
                          m = p.stat().st_mtime
                      except OSError:
                          continue
                      if m > newest_m:
                          newest = p
                          newest_m = m

          if rc != 0 or newest is None:
              return DriverResult(False, newest, stdout_file, stderr_file, rc, f"claude_print_failed rc={rc}")
          return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


  DRIVERS["claude_print"] = ClaudePrintDriver()
  ```

  In config, add to `agents.claude`:

  ```json
      "prebump": {
        "driver": "claude_print",
        "sandbox": {"mode": "home_override", "subdir": "claude_sandbox"},
        "prompt": "Say hi, then use the Bash tool to run pwd.",
        "timeout_seconds": 180,
        "env_vars": ["ANTHROPIC_API_KEY"],
        "credential_files": ["~/.claude/.credentials.json"],
        "discover_session": {
          "kind": "jsonl_newest",
          "roots": [".claude/projects"],
          "globs": ["**/*.jsonl"],
          "required_types": ["user", "assistant"]
        }
      }
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_driver_claude.py -v
  python -c "import json; json.load(open('docs/agent-support/agent-watch-config.json'))"
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_driver_claude.py docs/agent-support/agent-watch-config.json
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add claude_print prebump driver

  Runs claude -p --output-format stream-json --session-id <uuid> inside
  a HOME-overridden sandbox. The explicit session id gives the driver a
  deterministic path to pick up the session file under
  ~/.claude/projects without racing other files.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §5 claude row — v1
  EOF
  )"
  ```

---

### Task 3.3 — Gemini driver (`gemini_prompt`)

**Files**
- Modify: `scripts/agent_watch_prebump_drivers.py`, `docs/agent-support/agent-watch-config.json`
- Test: `scripts/tests/test_prebump_driver_gemini.py`

- [ ] **Step 1: Write the failing test.**

  ```python
  # scripts/tests/test_prebump_driver_gemini.py
  import json
  import os
  import sys
  from pathlib import Path
  from unittest import mock

  REPO = Path(__file__).resolve().parents[2]
  sys.path.insert(0, str(REPO / "scripts"))

  import agent_watch_prebump_drivers as drv_mod


  def test_gemini_driver_runs_and_returns_session(tmp_path, monkeypatch):
      sb = tmp_path / "sb"
      sb.mkdir()

      def fake_run(argv, *, env=None, **kwargs):
          assert env is not None
          assert env.get("HOME") == str(sb)
          home = Path(env["HOME"])
          proj = home / ".gemini" / "tmp" / "abc123" / "chats"
          proj.mkdir(parents=True, exist_ok=True)
          out = proj / "session-demo.json"
          out.write_text(json.dumps({"messages": [{"type": "user", "text": "hi"}, {"type": "gemini", "text": "hello"}]}))

          import subprocess as _sp
          return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

      env = {"HOME": str(sb), "GEMINI_API_KEY": "g-test"}
      with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
          driver = drv_mod.DRIVERS["gemini_prompt"]
          res = driver.run(sb, env, "Say hello and list files.", timeout=30)

      assert res.ok is True
      assert res.session_path is not None
      assert res.session_path.name.startswith("session-")


  def test_gemini_config_has_prebump_block():
      cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
      pb = cfg["agents"]["gemini"]["prebump"]
      assert pb["driver"] == "gemini_prompt"
      assert "GEMINI_API_KEY" in pb["env_vars"]
      assert pb["discover_session"]["globs"][0].endswith(".json")
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_driver_gemini.py -v
  ```

  Expected: `KeyError: 'gemini_prompt'`.

- [ ] **Step 3: Write the minimal implementation.** Append to `scripts/agent_watch_prebump_drivers.py`:

  ```python
  class GeminiPromptDriver:
      name = "gemini_prompt"

      def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
          gemini_home = sandbox / ".gemini"
          gemini_home.mkdir(parents=True, exist_ok=True)
          # F2: env comes from prepare_auth.
          env = dict(env)
          stdout_file = sandbox / "gemini.stdout.txt"
          stderr_file = sandbox / "gemini.stderr.txt"
          try:
              proc = subprocess.run(
                  ["gemini", "-p", prompt, "--output-format", "json", "--yolo"],
                  env=env,
                  stdout=subprocess.PIPE,
                  stderr=subprocess.PIPE,
                  text=True,
                  check=False,
                  timeout=timeout,
              )
              stdout_file.write_text(proc.stdout or "")
              stderr_file.write_text(proc.stderr or "")
              rc = proc.returncode
          except subprocess.TimeoutExpired as exc:
              stdout_file.write_text("")
              stderr_file.write_text(f"timeout after {timeout}s: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 124, f"timeout:{timeout}")
          except FileNotFoundError as exc:
              stderr_file.write_text(f"gemini not found: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 127, "gemini_not_found")

          tmp_root = gemini_home / "tmp"
          newest: Path | None = None
          newest_m = -1.0
          if tmp_root.exists():
              for p in tmp_root.rglob("session-*.json"):
                  try:
                      m = p.stat().st_mtime
                  except OSError:
                      continue
                  if m > newest_m:
                      newest = p
                      newest_m = m

          if rc != 0 or newest is None:
              return DriverResult(False, newest, stdout_file, stderr_file, rc, f"gemini_prompt_failed rc={rc}")
          return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


  DRIVERS["gemini_prompt"] = GeminiPromptDriver()
  ```

  In config, add to `agents.gemini`:

  ```json
      "prebump": {
        "driver": "gemini_prompt",
        "sandbox": {"mode": "home_override", "subdir": "gemini_sandbox"},
        "prompt": "Say hello and list files.",
        "timeout_seconds": 180,
        "env_vars": ["GEMINI_API_KEY"],
        "credential_files": ["~/.gemini/oauth_creds.json"],
        "discover_session": {
          "kind": "gemini_session_json_newest",
          "roots": [".gemini/tmp"],
          "globs": ["**/session-*.json"],
          "required_types": []
        }
      }
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_driver_gemini.py -v
  python -c "import json; json.load(open('docs/agent-support/agent-watch-config.json'))"
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_driver_gemini.py docs/agent-support/agent-watch-config.json
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add gemini_prompt prebump driver

  Runs gemini -p --output-format json --yolo in a HOME-overridden
  sandbox so the CLI writes its chats tree under the sandboxed
  ~/.gemini/tmp. The newest session-*.json discovered there is returned
  as the driver result.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §5 gemini row — v1
  EOF
  )"
  ```

---

### Task 3.4 — Droid driver (`droid_exec`)

**Files**
- Modify: `scripts/agent_watch_prebump_drivers.py`, `docs/agent-support/agent-watch-config.json`
- Test: `scripts/tests/test_prebump_driver_droid.py`

- [ ] **Step 1: Write the failing test.**

  ```python
  # scripts/tests/test_prebump_driver_droid.py
  import json
  import os
  import sys
  from pathlib import Path
  from unittest import mock

  REPO = Path(__file__).resolve().parents[2]
  sys.path.insert(0, str(REPO / "scripts"))

  import agent_watch_prebump_drivers as drv_mod


  def test_droid_driver_runs_and_returns_session(tmp_path, monkeypatch):
      sb = tmp_path / "sb"
      sb.mkdir()

      def fake_run(argv, *, env=None, **kwargs):
          # F3: read env, not os.environ.
          assert env is not None
          assert env.get("HOME") == str(sb)
          home = Path(env["HOME"])
          sess = home / ".factory" / "sessions" / "01"
          sess.mkdir(parents=True, exist_ok=True)
          out = sess / "session-demo.jsonl"
          out.write_text('{"type":"message","role":"user","content":"hi"}\n{"type":"message","role":"assistant","content":"hello"}\n')

          import subprocess as _sp
          return _sp.CompletedProcess(argv, 0, stdout="ok", stderr="")

      env = {"HOME": str(sb)}
      with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
          driver = drv_mod.DRIVERS["droid_exec"]
          res = driver.run(sb, env, "Briefly describe this directory.", timeout=30)

      assert res.ok is True
      assert res.session_path is not None
      assert res.session_path.suffix == ".jsonl"


  def test_droid_config_has_prebump_block():
      cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
      pb = cfg["agents"]["droid"]["prebump"]
      assert pb["driver"] == "droid_exec"
      assert pb["sandbox"]["mode"] == "home_override"
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_driver_droid.py -v
  ```

  Expected: `KeyError: 'droid_exec'`.

- [ ] **Step 3: Write the minimal implementation.** Append to `scripts/agent_watch_prebump_drivers.py`:

  ```python
  class DroidExecDriver:
      name = "droid_exec"

      def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
          factory_home = sandbox / ".factory"
          factory_home.mkdir(parents=True, exist_ok=True)
          # F2: env comes from prepare_auth.
          env = dict(env)
          stdout_file = sandbox / "droid.stdout.txt"
          stderr_file = sandbox / "droid.stderr.txt"
          try:
              proc = subprocess.run(
                  ["droid", "exec", "--auto", "low", "--cwd", str(sandbox), prompt],
                  env=env,
                  stdout=subprocess.PIPE,
                  stderr=subprocess.PIPE,
                  text=True,
                  check=False,
                  timeout=timeout,
              )
              stdout_file.write_text(proc.stdout or "")
              stderr_file.write_text(proc.stderr or "")
              rc = proc.returncode
          except subprocess.TimeoutExpired as exc:
              stdout_file.write_text("")
              stderr_file.write_text(f"timeout after {timeout}s: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 124, f"timeout:{timeout}")
          except FileNotFoundError as exc:
              stderr_file.write_text(f"droid not found: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 127, "droid_not_found")

          sessions_root = factory_home / "sessions"
          newest: Path | None = None
          newest_m = -1.0
          if sessions_root.exists():
              for p in sessions_root.rglob("*.jsonl"):
                  try:
                      m = p.stat().st_mtime
                  except OSError:
                      continue
                  if m > newest_m:
                      newest = p
                      newest_m = m

          if rc != 0 or newest is None:
              return DriverResult(False, newest, stdout_file, stderr_file, rc, f"droid_exec_failed rc={rc}")
          return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


  DRIVERS["droid_exec"] = DroidExecDriver()
  ```

  In config, add to `agents.droid`:

  ```json
      "prebump": {
        "driver": "droid_exec",
        "sandbox": {"mode": "home_override", "subdir": "droid_sandbox"},
        "prompt": "Briefly describe this directory.",
        "timeout_seconds": 180,
        "env_vars": ["FACTORY_API_KEY"],
        "credential_files": ["~/.factory/auth.json"],
        "discover_session": {
          "kind": "jsonl_newest",
          "roots": [".factory/sessions"],
          "globs": ["**/*.jsonl"],
          "required_types": ["message"]
        }
      }
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_driver_droid.py -v
  python -c "import json; json.load(open('docs/agent-support/agent-watch-config.json'))"
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_driver_droid.py docs/agent-support/agent-watch-config.json
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add droid_exec prebump driver

  Runs droid exec --auto low --cwd <sandbox> inside a HOME-overridden
  temp dir. Picks up the newest session *.jsonl the CLI writes under
  ~/.factory/sessions in the sandbox.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §5 droid row — v1
  EOF
  )"
  ```

---

### Task 3.5 — Copilot driver (`copilot_prompt`) with hermeticity gate

**Files**
- Modify: `scripts/agent_watch_prebump_drivers.py`, `docs/agent-support/agent-watch-config.json`
- Test: `scripts/tests/test_prebump_driver_copilot.py`

- [ ] **Step 1: Write the failing test.**

  ```python
  # scripts/tests/test_prebump_driver_copilot.py
  import json
  import os
  import sys
  import time
  from pathlib import Path
  from unittest import mock

  REPO = Path(__file__).resolve().parents[2]
  sys.path.insert(0, str(REPO / "scripts"))

  import agent_watch_prebump_drivers as drv_mod


  def test_copilot_driver_succeeds_without_leak(tmp_path, monkeypatch):
      real_home = tmp_path / "realhome"
      (real_home / ".copilot").mkdir(parents=True)
      # Pre-populate something in real ~/.copilot so the hermeticity scan
      # has a baseline that must remain untouched.
      (real_home / ".copilot" / "baseline.txt").write_text("keep")
      old = time.time() - 3600
      os.utime(real_home / ".copilot" / "baseline.txt", (old, old))
      monkeypatch.setenv("HOME", str(real_home))
      sb = tmp_path / "sb"
      sb.mkdir()

      def fake_run(argv, *, env=None, **kwargs):
          # F3: read env explicitly, not os.environ.
          assert env is not None
          sandbox_home = Path(env["HOME"])
          assert sandbox_home == sb
          sess = sandbox_home / ".copilot" / "session-state" / "uuid-1"
          sess.mkdir(parents=True, exist_ok=True)
          (sess / "events.jsonl").write_text('{"type":"session.start"}\n{"type":"session.shutdown"}\n')

          import subprocess as _sp
          return _sp.CompletedProcess(argv, 0, stdout="", stderr="")

      env = {"HOME": str(sb)}
      with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
          driver = drv_mod.DRIVERS["copilot_prompt"]
          res = driver.run(sb, env, "Run ls.", timeout=30)

      assert res.ok is True
      assert res.session_path is not None
      assert res.session_path.name == "events.jsonl"


  def test_copilot_driver_fails_on_real_home_leak(tmp_path, monkeypatch):
      real_home = tmp_path / "realhome"
      (real_home / ".copilot").mkdir(parents=True)
      monkeypatch.setenv("HOME", str(real_home))
      sb = tmp_path / "sb"
      sb.mkdir()

      def fake_run(argv, *, env=None, **kwargs):
          # F3: read env explicitly. Simulate a leak: the CLI writes into
          # real ~/.copilot while running, and also writes a legit file
          # under the sandbox HOME.
          assert env is not None
          leaked = real_home / ".copilot" / "leaked.txt"
          leaked.write_text("oops")
          sb_home = Path(env["HOME"])
          sess = sb_home / ".copilot" / "session-state" / "uuid-2"
          sess.mkdir(parents=True, exist_ok=True)
          (sess / "events.jsonl").write_text('{"type":"session.start"}\n')

          import subprocess as _sp
          return _sp.CompletedProcess(argv, 0, stdout="", stderr="")

      env = {"HOME": str(sb)}
      with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
          driver = drv_mod.DRIVERS["copilot_prompt"]
          res = driver.run(sb, env, "Run ls.", timeout=30)

      assert res.ok is False
      assert res.error is not None
      assert "sandbox_breach" in res.error


  def test_copilot_config_has_prebump_block():
      cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
      pb = cfg["agents"]["copilot"]["prebump"]
      assert pb["driver"] == "copilot_prompt"
      assert pb["sandbox"]["mode"] == "home_override"
  ```

- [ ] **Step 2: Run the test to verify it fails.**

  ```
  pytest scripts/tests/test_prebump_driver_copilot.py -v
  ```

  Expected: `KeyError: 'copilot_prompt'`.

- [ ] **Step 3: Write the minimal implementation.** Append to `scripts/agent_watch_prebump_drivers.py`:

  ```python
  class CopilotPromptDriver:
      name = "copilot_prompt"

      def _snapshot_real_home_copilot(self, real_home: Path) -> dict[str, float]:
          root = real_home / ".copilot"
          snap: dict[str, float] = {}
          if not root.exists():
              return snap
          for p in root.rglob("*"):
              try:
                  snap[str(p)] = p.stat().st_mtime
              except OSError:
                  continue
          return snap

      def _find_leaks(self, real_home: Path, before: dict[str, float]) -> list[str]:
          root = real_home / ".copilot"
          leaks: list[str] = []
          if not root.exists():
              return leaks
          for p in root.rglob("*"):
              try:
                  m = p.stat().st_mtime
              except OSError:
                  continue
              prev = before.get(str(p))
              if prev is None or m > prev:
                  leaks.append(str(p))
          return leaks

      def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
          copilot_home = sandbox / ".copilot"
          copilot_home.mkdir(parents=True, exist_ok=True)
          # F2: env comes from prepare_auth.
          env = dict(env)
          env["COPILOT_ALLOW_ALL"] = "1"
          real_home = Path(os.environ.get("HOME", str(Path.home())))
          pre = self._snapshot_real_home_copilot(real_home)

          stdout_file = sandbox / "copilot.stdout.txt"
          stderr_file = sandbox / "copilot.stderr.txt"
          try:
              proc = subprocess.run(
                  ["copilot", "-p", prompt, "--allow-all-tools", "--config-dir", str(copilot_home)],
                  env=env,
                  stdout=subprocess.PIPE,
                  stderr=subprocess.PIPE,
                  text=True,
                  check=False,
                  timeout=timeout,
              )
              stdout_file.write_text(proc.stdout or "")
              stderr_file.write_text(proc.stderr or "")
              rc = proc.returncode
          except subprocess.TimeoutExpired as exc:
              stdout_file.write_text("")
              stderr_file.write_text(f"timeout after {timeout}s: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 124, f"timeout:{timeout}")
          except FileNotFoundError as exc:
              stderr_file.write_text(f"copilot not found: {exc}")
              return DriverResult(False, None, stdout_file, stderr_file, 127, "copilot_not_found")

          leaks = self._find_leaks(real_home, pre)
          if leaks:
              msg = "sandbox_breach: real ~/.copilot was modified during the run: " + ", ".join(leaks[:5])
              stderr_file.write_text((stderr_file.read_text() if stderr_file.exists() else "") + "\n" + msg)
              return DriverResult(False, None, stdout_file, stderr_file, rc, msg)

          sessions_root = copilot_home / "session-state"
          newest: Path | None = None
          newest_m = -1.0
          if sessions_root.exists():
              for p in sessions_root.rglob("events.jsonl"):
                  try:
                      m = p.stat().st_mtime
                  except OSError:
                      continue
                  if m > newest_m:
                      newest = p
                      newest_m = m
              if newest is None:
                  for p in sessions_root.rglob("*.jsonl"):
                      try:
                          m = p.stat().st_mtime
                      except OSError:
                          continue
                      if m > newest_m:
                          newest = p
                          newest_m = m

          if rc != 0 or newest is None:
              return DriverResult(False, newest, stdout_file, stderr_file, rc, f"copilot_prompt_failed rc={rc}")
          return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


  DRIVERS["copilot_prompt"] = CopilotPromptDriver()
  ```

  Note: the `_run_prebump` dispatch in `scripts/agent_watch.py` should map a `sandbox_breach` error to `fatal="config"` (exit 4) when `--allow-real-home` is not passed. Add to `_run_prebump`, right after the `result = driver.run(...)` call:

  ```python
          if (
              not result.ok
              and isinstance(result.error, str)
              and result.error.startswith("sandbox_breach")
              and not args.allow_real_home
          ):
              entries.append({
                  "agent": agent_name,
                  "driver": driver_name,
                  "ok": False,
                  "error": result.error,
                  "fatal": "config",
                  "stdout_file": str(result.stdout_file),
                  "stderr_file": str(result.stderr_file),
                  "evidence": {},
              })
              drv_mod.teardown_sandbox(sandbox, keep=True)
              continue
  ```

  In config, add to `agents.copilot`:

  ```json
      "prebump": {
        "driver": "copilot_prompt",
        "sandbox": {"mode": "home_override", "subdir": "copilot_sandbox"},
        "prompt": "Run ls.",
        "timeout_seconds": 180,
        "env_vars": ["GITHUB_TOKEN"],
        "credential_files": ["~/.copilot/hosts.json"],
        "discover_session": {
          "kind": "jsonl_newest",
          "roots": [".copilot/session-state"],
          "globs": ["**/events.jsonl"],
          "required_types": []
        }
      }
  ```

- [ ] **Step 4: Run the test to verify it passes.**

  ```
  pytest scripts/tests/test_prebump_driver_copilot.py -v
  python -c "import json; json.load(open('docs/agent-support/agent-watch-config.json'))"
  ```

- [ ] **Step 5: Commit.**

  ```
  git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_driver_copilot.py docs/agent-support/agent-watch-config.json scripts/agent_watch.py
  git commit -m "$(cat <<'EOF'
  feat(monitoring): add copilot_prompt prebump driver with leak gate

  Runs copilot -p --allow-all-tools --config-dir <sandbox/.copilot>
  inside a HOME-overridden sandbox. Before and after the run it
  snapshots real ~/.copilot mtimes; any new or modified file is a
  sandbox breach that hard-fails the driver with error=sandbox_breach
  and is mapped to exit code 4 in _run_prebump unless --allow-real-home
  was explicitly passed.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §5 copilot row + resolved decision #5
  EOF
  )"
  ```

---

## Phase 4 — Documentation + rollout

### Task 4.1 — SKILL.md prebump workflow subsection

**Files**
- Modify: `skills/agent-session-format-check/SKILL.md`

- [ ] **Step 1: Locate insertion point.** Read `skills/agent-session-format-check/SKILL.md` to confirm the existing section order; insert the new subsection at the end of §1 (after the "3-step quick start" block) under the heading `## 1a  Prebump Validation (opt-in, before a matrix bump)`.

- [ ] **Step 2: Write the literal content.** Insert:

  ```markdown
  ---

  ## 1a  Prebump Validation (opt-in, before a matrix bump)

  Weekly scanning samples the newest on-disk session, which can predate a CLI
  upgrade and give a false "safe to bump" call (the codex 0.120.0 trap and the
  copilot `session.shutdown` trap). When weekly reports
  `recommendation == run_prebump_validator` — or before you stage any
  `max_verified_version` bump — run the prebump path to exercise the currently
  installed CLI once inside a sandbox and diff its output against the fixture
  baseline:

  ```
  ./scripts/agent_watch.py --mode prebump --agent codex --agent claude
  ```

  Exit-code contract:
  - `0` — every requested agent produced a fresh session and the schema
    matches baseline. Safe to bump.
  - `2` — at least one fresh session's schema does **not** match baseline.
    Do **not** bump; investigate the schema diff in
    `scripts/probe_scan_output/agent_watch/<slug>-prebump/report.json`.
  - `3` — at least one driver failed (timeout, auth, CLI not found, or
    discovery contract violation — wrong session root, wrong glob, or
    missing required event types).
  - `4` — config/invariant error: unknown `--agent` (or one with no
    prebump block), missing/invalid `discover_session` contract,
    credential hygiene failure (oversize / mode), or sandbox breach
    (copilot hermeticity gate). Re-run with
    `--allow-real-home` only if you understand your real config dir will
    be mutated for that one invocation.

  Flags:
  - `--agent <name>` (repeatable) — restrict to specific agents. An
    unknown agent or one without a `prebump` config block exits 4.
  - `--keep-sandbox` — preserve the temp `$HOME` for debugging.
  - `--timeout-seconds N` — per-driver timeout. CLI flag overrides
    per-agent config; falls back to config, then global default (120s).
  - `--force-fresh` — suppress staleness evaluation for this run only (records
    `stale_reason=forced_fresh` in the report).
  - `--allow-real-home` — copilot/real-HOME opt-in after a sandbox-breach
    diagnostic; never persistent.

  Prebump uses the hybrid env-var-first auth policy: if the relevant API-key
  env var (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`,
  `FACTORY_API_KEY`, `GITHUB_TOKEN`) is set it is forwarded into the sandbox
  and real HOME is never read. Otherwise the driver copies the declared
  credential file from real HOME into the sandbox after running three hygiene
  gates (64 KiB max, mode `0600`, ≤90-day mtime warning). v1 drivers:
  `codex_exec`, `claude_print`, `gemini_prompt`, `droid_exec`, `copilot_prompt`.
  opencode + openclaw are v2.
  ```

- [ ] **Verification.**

  ```
  grep -n "Prebump Validation" skills/agent-session-format-check/SKILL.md
  ```

  Expected: one matching line in §1a.

- [ ] **Commit.**

  ```
  git add skills/agent-session-format-check/SKILL.md
  git commit -m "$(cat <<'EOF'
  docs(skill): document prebump workflow in agent-session-format-check

  Adds §1a covering when to run --mode prebump, the exit-code contract,
  the flag surface, and the env-var-first auth + credential-hygiene
  gates.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §4.6 doc requirement
  EOF
  )"
  ```

---

### Task 4.2 — monitoring.md: staleness fields + prebump snippet

**Files**
- Modify: `docs/agent-support/monitoring.md`

- [ ] **Step 1: Locate insertion point.** Read `docs/agent-support/monitoring.md` to find the severity vocabulary table and the "what weekly emits" section.

- [ ] **Step 2: Write the literal content.** Two insertions:

  A. In the severity/recommendation vocabulary section, add a new row:

  ```markdown
  | `medium` | `run_prebump_validator` | Weekly evidence passed schema diff but the sampled session predates the installed CLI binary. Run `./scripts/agent_watch.py --mode prebump --agent <name>` before bumping. |
  ```

  B. Append a new subsection "## Sample freshness (weekly)":

  ```markdown
  ## Sample freshness (weekly)

  `results.<agent>.evidence.sample_freshness` records whether the newest
  local session predates the currently installed CLI binary. Fields:

  - `sample_mtime_utc`, `cli_binary_mtime_utc`, `cli_binary_path` — raw inputs.
  - `freshness_window_seconds` — per-agent backstop (14d hot / 30d cold).
  - `sample_older_than_cli` — primary staleness signal.
  - `sample_older_than_window` — backstop signal.
  - `is_stale` — OR of both signals (with `forced_fresh` short-circuit).
  - `stale_reason` — one of `sample_older_than_cli`, `sample_older_than_window`,
    `cli_binary_unresolved`, `forced_fresh`, or `null`.
  - `mode_context` — `normal` or `skip_update`.

  When `installed > verified`, `schema_matches_baseline == true`, and
  `is_stale == true`, severity is `medium` and the recommendation is
  `run_prebump_validator`. Fresh samples retain the existing
  `bump_verified_version` auto-downgrade.

  ### Gating a matrix bump on prebump

  ```
  ./scripts/agent_watch.py --mode prebump --agent codex --agent claude \
      && git add docs/agent-support/agent-support-matrix.yml \
      && git commit -m "chore(matrix): bump codex_cli / claude_code"
  ```

  Exit 0 is required. Exit 2 means the fresh session does not match baseline.
  Exit 3 means a driver failed (CLI error, timeout, no headless mode, or
  discovery-contract violation). Exit 4 means a config error (unknown
  agent, missing/invalid `discover_session` contract, credential hygiene
  failure) or a sandbox breach (the copilot hermeticity gate, overridable
  only via `--allow-real-home`).
  ```

- [ ] **Verification.**

  ```
  grep -n "run_prebump_validator" docs/agent-support/monitoring.md
  grep -n "sample_freshness" docs/agent-support/monitoring.md
  ```

  Expected: each pattern matches at least one line.

- [ ] **Commit.**

  ```
  git add docs/agent-support/monitoring.md
  git commit -m "$(cat <<'EOF'
  docs(monitoring): document sample_freshness and run_prebump_validator

  Adds the new severity row and a 'Sample freshness (weekly)' subsection
  that lists every field in evidence.sample_freshness, explains the
  stale_reason / mode_context split, and shows the pre-commit snippet
  for gating a matrix bump on --mode prebump exit 0.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: spec §3.3 + §4.6
  EOF
  )"
  ```

---

### Task 4.3 — CHANGELOG entry

**Files**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Read the top of CHANGELOG.md** to confirm the existing section heading style. Insert a new entry under an `## Unreleased` section (create it if missing) above the most recent released version.

- [ ] **Step 2: Write the literal content.**

  ```markdown
  ## Unreleased

  ### Added
  - Fresh-session validator for `scripts/agent_watch.py`: weekly staleness
    detection (`evidence.sample_freshness`) across all 7 agents and a new
    opt-in `--mode prebump` path with per-agent drivers for codex, claude,
    gemini, droid, and copilot. New recommendation `run_prebump_validator`
    blocks auto-downgrade to `bump_verified_version` when the newest local
    sample predates the installed CLI binary. Hybrid env-var-first auth
    with credential-copy hygiene gates (64 KiB / mode 0600 / 90-day
    warning). Copilot driver enforces a fail-closed sandbox-leak assertion
    overridable only via `--allow-real-home` per run.
  ```

- [ ] **Verification.**

  ```
  grep -n "Fresh-session validator" CHANGELOG.md
  ```

- [ ] **Commit.**

  ```
  git add CHANGELOG.md
  git commit -m "$(cat <<'EOF'
  docs(changelog): record fresh-session validator v1 landing

  Adds an Unreleased entry covering staleness detection for all 7
  agents and prebump drivers for the codex/claude/gemini/droid/copilot
  subset, plus the new run_prebump_validator recommendation and the
  hybrid env-var-first auth policy.

  Tool: Claude Code
  Model: claude-opus-4-6
  Why: release notes for v1 rollout
  EOF
  )"
  ```

---

## Open spec questions

None — the spec (commit `580fa61`) resolves every decision this plan depends on: freshness windows, stale_reason/mode_context split, forced_fresh override, env-var-first auth with hygiene gates, copilot hermeticity gate with --allow-real-home opt-in, exit-code contract, and v1/v2 rollout scope.
