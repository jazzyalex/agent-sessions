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
                    "--verbose",
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

    def run(self, sandbox: Path, env: dict[str, str], prompt: str, timeout: int) -> DriverResult:
        copilot_home = sandbox / ".copilot"
        copilot_home.mkdir(parents=True, exist_ok=True)
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
