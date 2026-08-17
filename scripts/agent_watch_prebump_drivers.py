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

import os
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import time
import uuid as _uuid
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


def _newest_matching(root: Path, patterns: tuple[str, ...]) -> Path | None:
    newest: Path | None = None
    newest_m = -1.0
    if not root.exists():
        return None
    for pattern in patterns:
        for p in root.rglob(pattern):
            if not p.is_file():
                continue
            try:
                m = p.stat().st_mtime
            except OSError:
                continue
            if m > newest_m:
                newest = p
                newest_m = m
    return newest


def _newest_matching_after(root: Path, patterns: tuple[str, ...], min_mtime: float) -> Path | None:
    newest: Path | None = None
    newest_m = -1.0
    if not root.exists():
        return None
    for pattern in patterns:
        for p in root.rglob(pattern):
            if not p.is_file():
                continue
            try:
                m = p.stat().st_mtime
            except OSError:
                continue
            if m < min_mtime:
                continue
            if m > newest_m:
                newest = p
                newest_m = m
    return newest


def _newest_matching_after_with_text(root: Path, patterns: tuple[str, ...], min_mtime: float, needle: str) -> Path | None:
    matches: list[tuple[float, Path]] = []
    if not root.exists():
        return None
    for pattern in patterns:
        for p in root.rglob(pattern):
            if not p.is_file():
                continue
            try:
                m = p.stat().st_mtime
            except OSError:
                continue
            if m < min_mtime:
                continue
            matches.append((m, p))
    for _, p in sorted(matches, key=lambda item: item[0], reverse=True):
        if _file_contains(p, needle):
            return p
    return None


def _write_completed_output(sandbox: Path, label: str, proc: subprocess.CompletedProcess[str]) -> tuple[Path, Path]:
    stdout_file = sandbox / f"{label}.stdout.txt"
    stderr_file = sandbox / f"{label}.stderr.txt"
    stdout_file.write_text(proc.stdout or "")
    stderr_file.write_text(proc.stderr or "")
    return stdout_file, stderr_file


def _timeout_result(sandbox: Path, label: str, timeout: int, exc: subprocess.TimeoutExpired) -> DriverResult:
    stdout_file = sandbox / f"{label}.stdout.txt"
    stderr_file = sandbox / f"{label}.stderr.txt"
    stdout_file.write_text("")
    stderr_file.write_text(f"timeout after {timeout}s: {exc}")
    return DriverResult(False, None, stdout_file, stderr_file, 124, f"timeout:{timeout}")


def _not_found_result(sandbox: Path, label: str, binary: str, exc: FileNotFoundError) -> DriverResult:
    stdout_file = sandbox / f"{label}.stdout.txt"
    stderr_file = sandbox / f"{label}.stderr.txt"
    stdout_file.write_text("")
    stderr_file.write_text(f"{binary} not found: {exc}")
    return DriverResult(False, None, stdout_file, stderr_file, 127, f"{binary}_not_found")


def _file_contains(path: Path, needle: str) -> bool:
    try:
        return needle in path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


def _hermes_state_db_contains_recent_marker(path: Path, needle: str, min_started: float) -> bool:
    try:
        conn = sqlite3.connect(str(path))
    except Exception:
        return False
    try:
        message_columns = {
            row[1]
            for row in conn.execute("PRAGMA table_info(messages);").fetchall()
            if len(row) > 1
        }
        marker_columns = [
            col
            for col in ("content", "tool_calls", "codex_message_items", "codex_reasoning_items", "reasoning", "reasoning_content")
            if col in message_columns
        ]
        if not marker_columns:
            return False
        marker_clause = " OR ".join(f"COALESCE(m.{col}, '') LIKE ?" for col in marker_columns)
        row = conn.execute(
            f"""
            SELECT 1
            FROM sessions s
            JOIN messages m ON m.session_id = s.id
            WHERE s.started_at >= ?
              AND m.timestamp >= ?
              AND ({marker_clause})
            LIMIT 1;
            """,
            (min_started, min_started, *([f"%{needle}%"] * len(marker_columns))),
        ).fetchone()
        return row is not None
    except Exception:
        return False
    finally:
        conn.close()


def make_sandbox(*, parent: Path, label: str) -> Path:
    """Create a fresh temp directory inside *parent* to use as $HOME."""
    parent.mkdir(parents=True, exist_ok=True)
    sb = Path(tempfile.mkdtemp(prefix=f"agent-watch-prebump-{label}-", dir=str(parent)))
    return sb


def teardown_sandbox(sandbox: Path, *, keep: bool) -> None:
    if keep:
        return
    shutil.rmtree(sandbox, ignore_errors=True)


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
    4. Copy non-secret support files listed under
       prebump_cfg["support_files"] into the sandbox. These files provide
       auth selection/account metadata and are size-limited, but do not use
       strict credential mode gates because CLI settings are commonly 0644.

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

    support_specs = list(prebump_cfg.get("support_files") or [])
    for spec in support_specs:
        if isinstance(spec, str) and spec.startswith("~/"):
            src = real_home / spec[2:]
        else:
            src = Path(spec)
        if not src.exists() or not src.is_file():
            continue
        try:
            if src.stat().st_size > 64 * 1024:
                raise HygieneError(f"support file {src} is > 64 KiB")
            rel = src.relative_to(real_home)
        except ValueError:
            rel = Path(src.name)
        dst = sandbox / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        os.chmod(dst, 0o600)
    return env, warnings


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


class ClaudePrintDriver:
    name = "claude_print"

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        session_home = Path(env.get("AGENT_WATCH_SESSION_HOME", str(sandbox)))
        claude_home = session_home / ".claude"
        claude_home.mkdir(parents=True, exist_ok=True)
        # F2: env comes from prepare_auth; do not call os.environ.copy().
        env = dict(env)
        session_id = str(_uuid.uuid4())
        stdout_file = sandbox / "claude.stdout.txt"
        stderr_file = sandbox / "claude.stderr.txt"
        cmd = [
            "claude", "-p",
            "--verbose",
            "--output-format", "stream-json",
            "--session-id", session_id,
        ]
        model = env.get("AGENT_WATCH_MODEL")
        if model:
            cmd.extend(["--model", model])
        cmd.append(prompt)
        run_started = time.time()
        try:
            proc = subprocess.run(
                cmd,
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
        if newest is not None:
            try:
                if newest.stat().st_mtime < run_started:
                    newest = None
            except OSError:
                newest = None

        if rc != 0 or newest is None:
            err = f"claude_print_failed rc={rc}" if rc != 0 else "claude_no_run_session"
            return DriverResult(False, newest, stdout_file, stderr_file, rc, err)
        return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


DRIVERS["claude_print"] = ClaudePrintDriver()


class AntigravityPrintDriver:
    name = "antigravity_print"

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        session_home = Path(env.get("AGENT_WATCH_SESSION_HOME") or env.get("HOME") or str(sandbox))
        brain_root = session_home / ".gemini" / "antigravity-cli" / "brain"
        brain_root.mkdir(parents=True, exist_ok=True)
        # F2: env comes from prepare_auth.
        env = dict(env)
        stdout_file = sandbox / "antigravity.stdout.txt"
        stderr_file = sandbox / "antigravity.stderr.txt"
        marker = f"AGENT_WATCH_PREBUMP_{_uuid.uuid4().hex}"
        probe_prompt = f"{prompt}\n\nInclude this exact marker in your final answer: {marker}"
        run_started = time.time()
        try:
            proc = subprocess.run(
                ["agy", "-p", probe_prompt],
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
            stderr_file.write_text(f"agy not found: {exc}")
            return DriverResult(False, None, stdout_file, stderr_file, 127, "agy_not_found")

        newest = _newest_matching_after_with_text(
            brain_root, ("*/.system_generated/logs/transcript.jsonl",), run_started, marker
        )

        if rc != 0 or newest is None:
            if rc == 0 and marker in (proc.stdout or ""):
                return DriverResult(False, newest, stdout_file, stderr_file, rc, "antigravity_no_transcript_artifact")
            return DriverResult(False, newest, stdout_file, stderr_file, rc, f"antigravity_print_failed rc={rc}")
        return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


DRIVERS["antigravity_print"] = AntigravityPrintDriver()


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
        # Check for deleted files: paths in the pre-snapshot that no longer exist.
        for path_str in before:
            p = Path(path_str)
            if not p.exists():
                leaks.append(path_str)
        return leaks

    @staticmethod
    def _gh_auth_token() -> str | None:
        """Token from the locally authenticated gh CLI, or None.

        Never logged or written to the report — it is only placed in the child env.
        """
        try:
            proc = subprocess.run(
                ["gh", "auth", "token"],
                # Explicit env, matching every other subprocess call in this module.
                # gh reads its own config/keyring, so the real environment is required.
                env=os.environ.copy(),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if proc.returncode != 0:
            return None
        token = (proc.stdout or "").strip()
        return token or None

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        session_home = Path(env.get("AGENT_WATCH_SESSION_HOME", str(sandbox)))
        using_real_session_home = session_home != sandbox
        copilot_home = session_home / ".copilot"
        copilot_home.mkdir(parents=True, exist_ok=True)
        env = dict(env)
        env["COPILOT_ALLOW_ALL"] = "1"
        if not using_real_session_home:
            # `--config-dir` is deprecated in favour of COPILOT_HOME (copilot warns on
            # every invocation and the flag is slated to go away).
            env["COPILOT_HOME"] = str(copilot_home)
        # Env-var-first auth per the prebump policy. When none of the declared vars is
        # set, fall back to the locally authenticated gh CLI — that is one of the three
        # methods copilot's own "No authentication information found" error lists, and
        # the previously declared credential file (~/.copilot/hosts.json) no longer
        # exists, so without this the driver could never authenticate on a machine that
        # signs in through gh.
        if not any(env.get(v) for v in ("COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN")):
            token = self._gh_auth_token()
            if token:
                env["COPILOT_GITHUB_TOKEN"] = token
        real_home = Path(os.environ.get("HOME", str(Path.home())))
        pre = {} if using_real_session_home else self._snapshot_real_home_copilot(real_home)

        stdout_file = sandbox / "copilot.stdout.txt"
        stderr_file = sandbox / "copilot.stderr.txt"
        marker = f"AGENT_WATCH_PREBUMP_{_uuid.uuid4().hex}"
        probe_prompt = f"{prompt}\n\nInclude this exact marker in your final answer: {marker}"
        cmd = ["copilot", "-p", probe_prompt, "--allow-all-tools"]
        model = env.get("AGENT_WATCH_MODEL")
        if model:
            cmd.extend(["--model", model])
        run_started = time.time()
        try:
            proc = subprocess.run(
                cmd,
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

        leaks = [] if using_real_session_home else self._find_leaks(real_home, pre)
        if leaks:
            msg = "sandbox_breach: real ~/.copilot was modified during the run: " + ", ".join(leaks[:5])
            stderr_file.write_text((stderr_file.read_text() if stderr_file.exists() else "") + "\n" + msg)
            return DriverResult(False, None, stdout_file, stderr_file, rc, msg)

        sessions_root = copilot_home / "session-state"
        newest = _newest_matching_after_with_text(
            sessions_root,
            ("events.jsonl", "*.jsonl"),
            run_started,
            marker,
        )

        if rc != 0 or newest is None:
            err = f"copilot_prompt_failed rc={rc}" if rc != 0 else "copilot_marker_missing"
            return DriverResult(False, newest, stdout_file, stderr_file, rc, err)
        return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


DRIVERS["copilot_prompt"] = CopilotPromptDriver()


class OpenCodeRunDriver:
    name = "opencode_run"

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        data_home = sandbox / ".local" / "share"
        config_home = sandbox / ".config"
        state_home = sandbox / ".local" / "state"
        for root in (data_home, config_home, state_home):
            root.mkdir(parents=True, exist_ok=True)
        env = dict(env)
        env["XDG_DATA_HOME"] = str(data_home)
        env["XDG_CONFIG_HOME"] = str(config_home)
        env["XDG_STATE_HOME"] = str(state_home)
        run_started = time.time()
        try:
            proc = subprocess.run(
                [
                    "opencode",
                    "run",
                    "--pure",
                    "--format",
                    "json",
                    "--dir",
                    str(sandbox),
                    prompt,
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            return _timeout_result(sandbox, "opencode", timeout, exc)
        except FileNotFoundError as exc:
            return _not_found_result(sandbox, "opencode", "opencode", exc)

        stdout_file, stderr_file = _write_completed_output(sandbox, "opencode", proc)
        opencode_root = data_home / "opencode"
        storage_root = opencode_root / "storage" / "session"
        newest = _newest_matching_after(storage_root, ("ses_*.json",), run_started)
        if newest is None:
            db = opencode_root / "opencode.db"
            try:
                if db.is_file() and db.stat().st_mtime >= run_started:
                    newest = db
            except OSError:
                pass
        if proc.returncode != 0:
            return DriverResult(False, newest, stdout_file, stderr_file, proc.returncode, f"opencode_run_failed rc={proc.returncode}")
        if newest is None:
            return DriverResult(False, None, stdout_file, stderr_file, proc.returncode, "opencode_no_session_store")
        return DriverResult(True, newest, stdout_file, stderr_file, proc.returncode, None)


DRIVERS["opencode_run"] = OpenCodeRunDriver()


class OpenClawLocalAgentDriver:
    name = "openclaw_local_agent"

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        session_home = Path(env.get("AGENT_WATCH_SESSION_HOME", str(sandbox)))
        state_dir = session_home / ".openclaw"
        state_dir.mkdir(parents=True, exist_ok=True)
        env = dict(env)
        env["OPENCLAW_STATE_DIR"] = str(state_dir)
        session_key = f"agent:main:prebump-{_uuid.uuid4()}"
        marker = f"AGENT_WATCH_PREBUMP_{_uuid.uuid4().hex}"
        probe_prompt = f"{prompt}\n\nInclude this exact marker in your final answer: {marker}"
        run_started = time.time()
        try:
            proc = subprocess.run(
                [
                    "openclaw",
                    "agent",
                    "--local",
                    "--json",
                    "--session-key",
                    session_key,
                    "--message",
                    probe_prompt,
                    "--timeout",
                    str(timeout),
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                timeout=timeout + 5,
            )
        except subprocess.TimeoutExpired as exc:
            return _timeout_result(sandbox, "openclaw", timeout, exc)
        except FileNotFoundError as exc:
            return _not_found_result(sandbox, "openclaw", "openclaw", exc)

        stdout_file, stderr_file = _write_completed_output(sandbox, "openclaw", proc)
        agents_root = state_dir / "agents"
        newest: Path | None = None
        if agents_root.exists():
            candidates: list[tuple[float, Path]] = []
            for p in agents_root.rglob("*.jsonl"):
                if p.name.endswith(".jsonl.lock") or p.name.endswith(".trajectory.jsonl"):
                    continue
                if ".jsonl.deleted." in p.name or ".jsonl.reset." in p.name:
                    continue
                if "sessions" not in p.parts:
                    continue
                try:
                    m = p.stat().st_mtime
                except OSError:
                    continue
                if m < run_started:
                    continue
                candidates.append((m, p))
            for _, p in sorted(candidates, key=lambda item: item[0], reverse=True):
                if _file_contains(p, marker):
                    newest = p
                    break
        if proc.returncode != 0:
            return DriverResult(False, newest, stdout_file, stderr_file, proc.returncode, f"openclaw_local_agent_failed rc={proc.returncode}")
        if newest is None:
            return DriverResult(False, None, stdout_file, stderr_file, proc.returncode, "openclaw_marker_missing")
        return DriverResult(True, newest, stdout_file, stderr_file, proc.returncode, None)


DRIVERS["openclaw_local_agent"] = OpenClawLocalAgentDriver()


class CursorAgentPrintDriver:
    name = "cursor_agent_print"

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        session_home = Path(env.get("AGENT_WATCH_SESSION_HOME", str(sandbox)))
        cursor_home = session_home / ".cursor"
        cursor_home.mkdir(parents=True, exist_ok=True)
        env = dict(env)
        marker = f"AGENT_WATCH_PREBUMP_{_uuid.uuid4().hex}"
        probe_prompt = f"{prompt}\n\nInclude this exact marker in your final answer: {marker}"
        run_started = time.time()
        try:
            proc = subprocess.run(
                [
                    "cursor-agent",
                    "--print",
                    "--output-format",
                    "stream-json",
                    "--mode",
                    "ask",
                    "--trust",
                    "--sandbox",
                    "enabled",
                    "--workspace",
                    str(sandbox),
                    probe_prompt,
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            return _timeout_result(sandbox, "cursor", timeout, exc)
        except FileNotFoundError as exc:
            return _not_found_result(sandbox, "cursor", "cursor-agent", exc)

        stdout_file, stderr_file = _write_completed_output(sandbox, "cursor", proc)
        newest = _newest_matching_after_with_text(cursor_home / "projects", ("*.jsonl",), run_started, marker)
        if proc.returncode != 0:
            return DriverResult(False, newest, stdout_file, stderr_file, proc.returncode, f"cursor_agent_print_failed rc={proc.returncode}")
        if newest is None:
            return DriverResult(False, None, stdout_file, stderr_file, proc.returncode, "cursor_marker_missing")
        return DriverResult(True, newest, stdout_file, stderr_file, proc.returncode, None)


DRIVERS["cursor_agent_print"] = CursorAgentPrintDriver()


class HermesOneshotDriver:
    name = "hermes_oneshot"

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        session_home = Path(env.get("AGENT_WATCH_SESSION_HOME", str(sandbox)))
        hermes_home = session_home / ".hermes"
        hermes_home.mkdir(parents=True, exist_ok=True)
        marker = f"AGENT_WATCH_PREBUMP_{_uuid.uuid4().hex}"
        marked_prompt = f"{prompt}\n\nInclude this exact marker in your final answer: {marker}"
        env = dict(env)
        env["HERMES_HOME"] = str(hermes_home)
        env["HERMES_ACCEPT_HOOKS"] = "1"
        run_started = time.time()
        try:
            proc = subprocess.run(
                [
                    "hermes",
                    "--oneshot",
                    marked_prompt,
                    "--accept-hooks",
                    "--ignore-rules",
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            return _timeout_result(sandbox, "hermes", timeout, exc)
        except FileNotFoundError as exc:
            return _not_found_result(sandbox, "hermes", "hermes", exc)

        stdout_file, stderr_file = _write_completed_output(sandbox, "hermes", proc)
        newest = _newest_matching_after_with_text(hermes_home / "sessions", ("session_*.json",), run_started, marker)
        db = hermes_home / "state.db"
        if db.is_file():
            db_fresh = False
            for candidate in (db, hermes_home / "state.db-wal", hermes_home / "state.db-shm"):
                try:
                    if candidate.is_file() and candidate.stat().st_mtime >= run_started:
                        db_fresh = True
                        break
                except OSError:
                    continue
            if db_fresh and _hermes_state_db_contains_recent_marker(db, marker, run_started):
                try:
                    os.utime(db, None)
                except OSError:
                    pass
                if newest is None:
                    newest = db
                else:
                    try:
                        if db.stat().st_mtime > newest.stat().st_mtime:
                            newest = db
                    except OSError:
                        newest = db
        if proc.returncode != 0:
            return DriverResult(False, newest, stdout_file, stderr_file, proc.returncode, f"hermes_oneshot_failed rc={proc.returncode}")
        if newest is None:
            return DriverResult(False, None, stdout_file, stderr_file, proc.returncode, "hermes_no_session_store")
        return DriverResult(True, newest, stdout_file, stderr_file, proc.returncode, None)


DRIVERS["hermes_oneshot"] = HermesOneshotDriver()


class PiPromptDriver:
    name = "pi_prompt"

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        pi_home = sandbox / ".pi" / "agent"
        sessions_root = pi_home / "sessions"
        sessions_root.mkdir(parents=True, exist_ok=True)
        env = dict(env)
        env["PI_CODING_AGENT_DIR"] = str(pi_home)
        env["PI_CODING_AGENT_SESSION_DIR"] = str(sessions_root)
        stdout_file = sandbox / "pi.stdout.txt"
        stderr_file = sandbox / "pi.stderr.txt"
        session_id = str(_uuid.uuid4())
        try:
            proc = subprocess.run(
                [
                    "pi",
                    "--print",
                    "--mode", "json",
                    "--session-dir", str(sessions_root),
                    "--session-id", session_id,
                    "--no-extensions",
                    "--no-skills",
                    "--no-prompt-templates",
                    "--no-themes",
                    "--no-context-files",
                    "--no-tools",
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
            stderr_file.write_text(f"pi not found: {exc}")
            return DriverResult(False, None, stdout_file, stderr_file, 127, "pi_not_found")

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
            return DriverResult(False, newest, stdout_file, stderr_file, rc, f"pi_prompt_failed rc={rc}")
        return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


DRIVERS["pi_prompt"] = PiPromptDriver()


class KimiPromptDriver:
    name = "kimi_prompt"

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        kimi_home = sandbox / ".kimi-code"
        sessions_root = kimi_home / "sessions"
        sessions_root.mkdir(parents=True, exist_ok=True)
        # F2: env is built by prepare_auth in _run_prebump. The driver only
        # adds CLI-specific HOME-relative pins; it never calls os.environ.copy().
        env = dict(env)
        env["KIMI_CODE_HOME"] = str(kimi_home)

        # Kimi's own moonshot-ai/"kimi" provider gates every call on
        # providerConfig.apiKey being present in the *loaded config*
        # (packages/agent-core-v2/src/app/auth/auth.ts: AuthTokenMissingError
        # otherwise) -- confirmed by reading dist/main.mjs. A bare KIMI_API_KEY
        # env var with no config.toml on disk still fails with "provider
        # moonshot-ai has no credential configured", so forwarding that var
        # alone is not sufficient. kimi-code ships a purpose-built escape
        # hatch for exactly this: KIMI_MODEL_NAME + KIMI_MODEL_API_KEY
        # (applyEnvModelConfig) synthesize an in-memory-only provider+model
        # that the CLI itself guarantees is never persisted back to
        # config.toml (stripEnvModelConfig guards the getConfig->setConfig
        # round-trip). Normalize whichever credential prepare_auth forwarded
        # (env_vars-first: KIMI_API_KEY or KIMI_MODEL_API_KEY) into that
        # shape. When prepare_auth instead copied a real
        # ~/.kimi-code/config.toml via credential_files, neither var is set
        # here and this block is a no-op -- the copied file's own
        # default_model/providers already carry a real api_key.
        # Endpoint and provider type come from the agent's prebump config
        # (model_base_url / model_provider_type, forwarded as AGENT_WATCH_*),
        # never baked in here: a user whose moonshot provider points at another
        # region, a gateway, or a self-hosted proxy would otherwise have the
        # sandbox authenticate against a backend they do not use — reported as a
        # driver failure when nothing is wrong with the session format.
        api_key = env.get("KIMI_MODEL_API_KEY") or env.get("KIMI_API_KEY")
        if api_key:
            env["KIMI_MODEL_API_KEY"] = api_key
            env["KIMI_MODEL_NAME"] = env.get("AGENT_WATCH_MODEL") or "kimi-k2.7-code"
            env.setdefault(
                "KIMI_MODEL_PROVIDER_TYPE",
                env.get("AGENT_WATCH_MODEL_PROVIDER_TYPE") or "kimi",
            )
            env.setdefault(
                "KIMI_MODEL_BASE_URL",
                env.get("AGENT_WATCH_MODEL_BASE_URL") or "https://api.moonshot.ai/v1",
            )

        stdout_file = sandbox / "kimi.stdout.txt"
        stderr_file = sandbox / "kimi.stderr.txt"
        try:
            proc = subprocess.run(
                ["kimi", "-p", prompt, "--output-format", "text"],
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
            stderr_file.write_text(f"kimi not found: {exc}")
            return DriverResult(False, None, stdout_file, stderr_file, 127, "kimi_not_found")

        # Discover the newest main-agent wire.jsonl under the sandboxed
        # KIMI_CODE_HOME. Restricted to agents/main/ (not agents/<subagent>/)
        # to match the weekly local_schema glob
        # (sessions/**/agents/main/wire.jsonl) -- a "say hello" prompt has no
        # subagents, but a stray agents/agent-0/wire.jsonl must never win.
        newest: Path | None = None
        newest_m = -1.0
        if sessions_root.exists():
            for p in sessions_root.rglob("agents/main/wire.jsonl"):
                try:
                    m = p.stat().st_mtime
                except OSError:
                    continue
                if m > newest_m:
                    newest = p
                    newest_m = m

        if rc != 0 or newest is None:
            return DriverResult(False, newest, stdout_file, stderr_file, rc, f"kimi_prompt_failed rc={rc}")
        return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


DRIVERS["kimi_prompt"] = KimiPromptDriver()


class GrokSingleDriver:
    """Grok Build headless single-turn run.

    Grok was the last actively-monitored agent with no prebump driver, which capped it
    at `supports_installed_only` permanently: without a fresh session from the installed
    build, `supports_latest` is structurally unclaimable no matter how clean the weekly
    scan looks.

    Two things make this driver different from the others:

    1. A Grok session is a DIRECTORY, not a file. `chat_history.jsonl` is only half of
       it — the sibling `summary.json` carries everything discovery depends on, and
       `GrokSessionDiscovery` skips any session directory that lacks it. The driver
       therefore returns the transcript path but VERIFIES the sidecar exists first;
       returning a transcript whose sidecar never landed would hand the fingerprinter a
       half-written session and report the resulting gap as schema drift.
    2. Grok has no API-key env var (its only documented one is GROK_SANDBOX), so the
       env-var-first branch of prepare_auth can never fire. Auth is always the
       credential-file copy of ~/.grok/auth.json into the sandbox HOME.

    The run is hermetic: HOME is the sandbox, so ~/.grok/sessions lands inside it, and
    `--cwd` pins the working directory to a sandbox subdirectory so the percent-encoded
    workdir bucket is predictable and no real repository is ever the session's cwd.
    """

    name = "grok_single"

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        sessions_root = sandbox / ".grok" / "sessions"
        sessions_root.mkdir(parents=True, exist_ok=True)
        workdir = sandbox / "workspace"
        workdir.mkdir(parents=True, exist_ok=True)
        # A file to look at, so a tool-using prompt has something real to do. A prompt
        # that completes without calling a tool yields the four most basic event types
        # and a genuinely thin sample.
        (workdir / "README.md").write_text("agent-watch prebump probe\n", encoding="utf-8")

        stdout_file = sandbox / "grok.stdout.txt"
        stderr_file = sandbox / "grok.stderr.txt"
        session_id = str(_uuid.uuid4())
        try:
            proc = subprocess.run(
                [
                    "grok",
                    "-p", prompt,
                    "--session-id", session_id,
                    "--cwd", str(workdir),
                    "--always-approve",
                    "--disable-web-search",
                    "--output-format", "plain",
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
            return _timeout_result(sandbox, "grok", timeout, exc)
        except FileNotFoundError as exc:
            return _not_found_result(sandbox, "grok", "grok", exc)

        # Prefer the session we named; fall back to newest so a Grok that ignores
        # --session-id still produces evidence rather than a confusing "not found".
        pinned = list(sessions_root.glob(f"*/{session_id}/chat_history.jsonl"))
        newest: Path | None = pinned[0] if pinned else None
        if newest is None:
            newest_m = -1.0
            for p in sessions_root.glob("*/*/chat_history.jsonl"):
                try:
                    m = p.stat().st_mtime
                except OSError:
                    continue
                if m > newest_m:
                    newest = p
                    newest_m = m

        if rc != 0 or newest is None:
            return DriverResult(False, newest, stdout_file, stderr_file, rc,
                                f"grok_single_failed rc={rc}")
        if not (newest.parent / "summary.json").exists():
            # Half a session. See the class docstring: the sidecar is a discovery
            # precondition, so a missing one is a driver failure, not clean evidence.
            return DriverResult(False, newest, stdout_file, stderr_file, rc,
                                "grok_summary_json_missing")
        return DriverResult(True, newest, stdout_file, stderr_file, rc, None)


DRIVERS["grok_single"] = GrokSingleDriver()
