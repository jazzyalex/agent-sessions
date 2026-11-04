"""Small workflow helpers. Preflight never starts a model turn or prints auth values."""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path


def _capture(argv, timeout):
    import agent_watch as watch
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False,
                              env=watch._child_env())
        return proc.returncode, proc.stdout, proc.stderr
    except (OSError, subprocess.TimeoutExpired):
        return 1, "", "command_failed"


def _version(argv, timeout):
    import agent_watch as watch
    rc, out, _ = _capture(argv, timeout)
    if rc != 0:
        return None
    return watch._extract_dsh_semver(out) if Path(argv[0]).name == "dsh" else watch._extract_semver(out)


def _credential_shape(value):
    """Keys/types only. Do not return primitive values, even in error messages."""
    if isinstance(value, dict):
        return {key: _credential_shape(item) for key, item in value.items()}
    if isinstance(value, list):
        return [type(item).__name__ for item in value]
    return type(value).__name__


def _expired(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key.lower() in ("expires_at", "expiresat", "expiry", "expiration"):
                try:
                    if isinstance(item, (int, float)):
                        epoch = item / 1000 if item > 1e12 else item
                    else:
                        epoch = datetime.fromisoformat(str(item).replace("Z", "+00:00")).timestamp()
                    if epoch < datetime.now(timezone.utc).timestamp():
                        return True
                except (ValueError, TypeError, OverflowError):
                    pass
            if _expired(item):
                return True
    return False


def latest(agent_cfg, timeout):
    import agent_watch as watch
    for source in agent_cfg.get("upstream", []):
        result = watch._fetch_upstream(source, timeout=timeout)
        if result.get("ok") and result.get("version"):
            return result["version"]
    return None


def preflight(cfg, *, timeout=12):
    import os
    results, actions = {}, []
    for name, agent in cfg.get("agents", {}).items():
        argv = agent.get("installed_version_cmd", [])
        checks = agent.get("preflight", {})
        pb = agent.get("prebump", {})
        present, expired, shapes = False, False, []
        for spec in checks.get("credential_files", pb.get("credential_files", [])):
            path = Path(spec).expanduser()
            if not path.is_file():
                continue
            present = True
            try:
                value = json.loads(path.read_text())
                shapes.append(_credential_shape(value))
                expired = expired or _expired(value)
            except (OSError, ValueError):
                shapes.append({"file": "present_uninspected"})
        env_present = any(os.environ.get(key) for key in pb.get("env_vars", []))
        present = present or env_present
        binary = shutil.which(argv[0]) if argv else None
        model_status = "not_checked"
        if binary and checks.get("models_argv"):
            rc, out, _ = _capture(checks["models_argv"], timeout)
            model = pb.get("model")
            if rc == 0 and model:
                # Exact tokens: a similarly named model must not hide an ended one.
                model_status = "available" if model in re.split(r"[\s\"',\[\]{}]+", out) else "model_unavailable"
            elif rc:
                model_status = "model_list_failed"
        if expired and not env_present:
            actions.append({"agent": name, "reason": "credential_expired", "action": "sign in using the CLI"})
        elif checks.get("credential_required") and binary and not present:
            actions.append({"agent": name, "reason": "credential_missing", "action": "check CLI authentication"})
        if model_status == "model_unavailable":
            actions.append({"agent": name, "reason": model_status, "action": "choose an available configured model"})
        # Auth status stdout can contain account details; retain only its classification.
        auth_status = "not_checked"
        if binary and checks.get("auth_argv"):
            rc, out, err = _capture(checks["auth_argv"], timeout)
            detail = (out + err).lower()
            failed = rc != 0 or any(s in detail for s in ("not signed in", "not logged in", "session expired"))
            auth_status = "auth_failed" if failed else "status_check_passed"
            if failed and not any(a["agent"] == name and a["reason"].startswith("credential_") for a in actions):
                actions.append({"agent": name, "reason": "auth_failed", "action": "sign in using the CLI"})
        results[name] = {"binary": binary, "installed_version": _version(argv, timeout) if binary else None,
                         "credential_status": "credential present" if present else "not inspected or absent",
                         "credential_shapes": shapes, "credential_expired": expired,
                         "pinned_model": pb.get("model"), "model_status": model_status,
                         "auth_status": auth_status, "latest_version": latest(agent, timeout)}
    return {"mode": "preflight", "results": results, "owner_actions": actions}


def update_agent(agent, *, target, timeout=600):
    install = agent.get("install", {})
    probe = install.get("version_probe", agent.get("installed_version_cmd", []))
    old = _version(probe, 20)
    row = {"old_version": old, "target_version": target, "new_version": old, "ok": False}
    if not old:
        return dict(row, error="not_installed")
    if not target:
        return dict(row, error="latest_unknown")
    import agent_watch as watch
    comparison = watch._compare_dsh_semver(old, target)
    if comparison is None:
        comparison = watch._compare_semver(old, target)
    if comparison == 0:
        return dict(row, ok=True, error=None)
    if comparison == 1:
        return dict(row, error="upstream_older_than_installed")
    if "-" in target:
        return dict(row, error="prerelease_not_authorized")
    if not install.get("argv"):
        return dict(row, error="install_not_configured")
    rc, _, _ = _capture([part.replace("{version}", target) for part in install["argv"]], timeout)
    new = _version(probe, 20)  # Probe PATH, never trust updater stdout.
    return dict(row, new_version=new, ok=rc == 0 and new == target,
                error=None if rc == 0 and new == target else ("update_failed" if rc else "update_not_effective"))


def repo_status(root):
    import hashlib
    import os
    import stat
    proc = subprocess.run(["git", "status", "--porcelain"], cwd=root,
                          capture_output=True, text=True, check=True, timeout=15)
    digest = hashlib.sha256()
    # Include staged and unstaged bytes, not just porcelain's two-letter state.
    for args in (["diff", "--binary", "--no-ext-diff"],
                 ["diff", "--cached", "--binary", "--no-ext-diff"]):
        diff = subprocess.run(["git", *args], cwd=root, capture_output=True, check=True, timeout=15)
        digest.update(diff.stdout)
    untracked = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root,
                               capture_output=True, check=True, timeout=15).stdout
    remaining = 256 * 1024 * 1024
    for raw in sorted(filter(None, untracked.split(b"\0"))):
        path = Path(root) / os.fsdecode(raw)
        mode = path.lstat().st_mode
        digest.update(raw + b"\0" + str(mode).encode() + b"\0")
        if stat.S_ISLNK(mode):
            digest.update(os.fsencode(os.readlink(path)))
        elif stat.S_ISREG(mode):
            with path.open("rb") as handle:
                while chunk := handle.read(min(1024 * 1024, remaining + 1)):
                    remaining -= len(chunk)
                    if remaining < 0:
                        raise RuntimeError("repository_integrity_snapshot_limit")
                    digest.update(chunk)
        else:
            raise RuntimeError("repository_integrity_unsupported_file")
    return proc.stdout + "\ncontent_sha256=" + digest.hexdigest()


def guarded_driver_run(root, run):
    before = repo_status(root)
    try:
        result = run()
    except BaseException:
        if repo_status(root) != before:
            raise RuntimeError("sandbox_breach:repository_changed") from None
        raise
    if repo_status(root) != before:
        return replace(result, ok=False, error="sandbox_breach:repository_changed")
    return result


def run_with_fallback(run, model, fallback_models, classify):
    attempts = []
    for candidate in [model, *fallback_models]:
        result = run(candidate)
        entry = {"error": result.error, "stdout_file": str(result.stdout_file), "stderr_file": str(result.stderr_file)}
        reason = None if result.ok else classify(entry)
        attempt = {"model": candidate, "ok": result.ok, "failure_class": reason}
        for key in ("stdout_file", "stderr_file"):
            source = Path(entry[key])
            if source.exists():
                destination = source.with_name(f"attempt-{len(attempts)+1}-{source.name}")
                shutil.copy2(source, destination)
                attempt[key] = str(destination)
        attempts.append(attempt)
        if result.ok or reason != "model_unavailable":
            break
    return result, attempts


def _store_count(name, config, fp):
    import sqlite3
    import agent_watch as watch
    file = Path(fp.get("file") or "")
    if file.is_file() and file.suffix in (".db", ".sqlite"):
        try:
            with sqlite3.connect(file.resolve().as_uri() + "?mode=ro", uri=True, timeout=2) as db:
                tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if name == "opencode":
                    # Count logical IDs once, including migrated v1/v2 duplicates.
                    stores = [t for t in ("session", "session_v2") if t in tables]
                    query = " UNION ".join(f'SELECT id FROM "{t}"' for t in stores)
                    return db.execute(f"SELECT count(*) FROM ({query})").fetchone()[0] if query else 0
                table = {"hermes": "sessions", "devin": "sessions", "openclaw": "session_windows"}.get(name)
                if table in tables:
                    return db.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0]
        except sqlite3.Error:
            return None
    roots = config.get("roots", [])
    if name == "cline":
        return len(watch._newest_cline_files(watch._cline_effective_roots(roots), config.get("glob", "*/*.json"), 10**9,
                                           exclude_globs=config.get("exclude_globs")))
    if name == "fx":
        return len(watch._fx_newest_session_files(roots, 10**9))
    return len(watch._newest_files(roots, config.get("glob", "**/*"), 10**9,
                                  exclude_globs=config.get("exclude_globs")))


def add_sampling_contract(name, config, fp):
    import agent_watch as watch
    count = fp.get("sampled_sessions")
    if count is None:
        count = len(fp.get("sampled_files") or fp.get("sampled_session_ids") or [])
        if not count and fp.get("type_counts"):
            count = 1
    fp["store_sessions"] = _store_count(name, config, fp)
    fp["store_count_scope"] = "configured schema-discovery candidates; database IDs are deduplicated"
    fp["sampled_sessions"] = count
    fp["sampled_events"] = watch._observed_event_count(fp)
    versions = set(fp.get("sampled_versions") or [])
    # OpenCode stores the creating CLI version on session_v2.version. Do not
    # confuse integer JSONL format versions (Pi's v3) with CLI versions.
    stored = fp.get("session_version")
    if name == "opencode" and isinstance(stored, str) and re.fullmatch(r"\d+\.\d+\.\d+(?:[-+].+)?", stored):
        versions.add(stored)
    if name in ("codex", "claude"):
        for spec in fp.get("sampled_files") or ([fp["file"]] if fp.get("file") else []):
            try:
                with watch._open_session_text(Path(spec)) as handle:
                    head = handle.read(64 * 1024)
                for line in head.splitlines()[:50]:
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(record, dict):
                        continue
                    payload = record.get("payload")
                    version = record.get("version") if name == "claude" else (
                        payload.get("cli_version") if record.get("type") == "session_meta" and isinstance(payload, dict) else None)
                    if isinstance(version, str) and re.fullmatch(r"\d+\.\d+\.\d+(?:[-+].+)?", version):
                        versions.add(version)
            except watch._SESSION_READ_ERRORS:
                pass
    fp["sampled_versions"] = sorted(versions)
    if config.get("single_session_reason"):
        fp["single_session_reason"] = config["single_session_reason"]
    elif count == 1 and isinstance(fp["store_sessions"], int) and fp["store_sessions"] > 1:
        fp["sampling_contract_error"] = "single_session_without_declared_reason"


def sampling_summary(fp):
    if "sampled_sessions" not in fp:
        return ""
    return f" sampled {fp['sampled_sessions']} of {fp.get('store_sessions', 'unknown')}"


def price_key(raw, table):
    """Mirror RunwayPriceSnapshot + ModelPriceKeyResolver, including guarded prefixes."""
    if raw == "<synthetic>":
        return raw  # Zero-token synthetic rows only; not a model price.
    models = table.get("models", {})
    known = {"opus": {"4-5", "4-6", "4-7", "4-8", "5"},
             "sonnet": {"3", "3-5", "4", "4-5", "4-6", "5"},
             "haiku": {"4-5"}, "fable": {"5"}, "mythos": {"5"}}
    def match(value):
        if value in models:
            return value
        for key in sorted(models, key=len, reverse=True):
            if not value.startswith(key):
                continue
            suffix = value[len(key):]
            if key.startswith("claude-"):
                family = key.removeprefix("claude-")
                if family in known:
                    version = re.sub(r"-\d{8}$", "", suffix.removeprefix("-"))
                    if suffix.startswith("-") and version in known[family]:
                        return key
                elif re.fullmatch(r"-\d{8}", suffix):
                    return key
            elif re.fullmatch(r"-(?:\d{8}|\d{4}-\d{2}-\d{2})", suffix):
                return key
        return None
    direct = match(raw)
    if direct:
        return direct
    value = raw.strip().lower()
    value = re.sub(r"\s*\((?:minimal|low|medium|high|xhigh|thinking)\)$", "", value).strip()
    value = value.removeprefix("cline-free/")
    value = re.sub(r"(?::free|-free)$", "", value)
    parts = value.split("/")
    prefixes = {"anthropic", "openai", "google", "z-ai", "moonshotai", "moonshot-ai", "deepseek", "minimax",
                "x-ai", "qwen", "meta", "opencode", "openrouter", "poolside"}
    if len(parts) == 2 and parts[0] in prefixes:
        value = parts[1]
    value = table.get("aliases", {}).get(value, value)
    if value.startswith("claude-"):
        value = re.sub(r"(?<=\d)\.(?=\d)", "-", value)
    return match(value)


def price_coverage(name, config, table):
    """Model identifiers from recently modified transcripts and timestamped DB rows.

    Inspect provider-owned wrappers only; tool inputs and free text are never searched.
    This is coverage, not verification of the dollar rates on official provider pages.
    """
    import sqlite3
    import time
    import agent_watch as watch
    cutoff = time.time() - 30 * 86400
    slugs, files, errors = set(), set(), 0
    synthetic_positive = 0
    def observe(obj):
        nonlocal synthetic_positive
        if isinstance(obj, list):
            for item in obj:
                observe(item)
        elif isinstance(obj, dict):
            if obj.get("model") == "<synthetic>" and isinstance(obj.get("usage"), dict):
                if any(isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0
                       for value in obj["usage"].values()):
                    synthetic_positive += 1
            for key in ("model", "modelID", "modelId", "model_id", "model_name", "current_model_id"):
                value = obj.get(key)
                if isinstance(value, dict):
                    value = value.get("id") or value.get("name")
                if isinstance(value, str) and value and len(value) < 160:
                    slugs.add(value)
            for key in ("payload", "state", "message", "messages", "metadata", "data", "usage", "events", "records", "configuration", "config"):
                if key in obj:
                    observe(obj[key])
    roots = config.get("roots", [])
    if name == "cline":
        roots = watch._cline_effective_roots(roots)
    candidates = watch._newest_files(roots, config.get("glob", "**/*.jsonl"), 10**9,
                                     exclude_globs=config.get("exclude_globs"))
    if name == "fx":
        candidates = watch._fx_newest_session_files(roots, 10**9)
    if name == "deepseek_harness":
        selected = {}
        root = watch._dsh_resolve_sessions_root(config)
        for path in root.glob("*/*/session*.jsonl*"):
            generation, _ = watch._dsh_parse_generation_filename(path.name)
            if generation is None or not path.is_file():
                continue
            prior = selected.get(path.parent)
            if prior is None or generation > prior[0]:
                selected[path.parent] = (generation, path)
        candidates = [pair[1] for pair in selected.values()]
    for path in candidates:
        try:
            if path.stat().st_mtime < cutoff:
                continue
            if name == "fx":
                observe(json.loads(path.with_name("session.json").read_text()))
            if name == "deepseek_harness":
                raw, _ = watch._dsh_read_stable_bytes(path)
                frames = watch._dsh_zstd_frames(raw) if path.name.endswith(".zstd") else [raw]
                for frame in frames:
                    for obj in watch._dsh_record_lines(frame):
                        observe(obj)
            elif path.suffix == ".json":
                observe(json.loads(path.read_text()))
                if name == "cline":
                    companion = path.with_name(path.stem + ".messages.json")
                    if companion.exists():
                        observe(json.loads(companion.read_text()))
            else:
                with watch._open_session_text(path) as handle:
                    for line in handle:
                        if '"model' in line or '"current_model_id"' in line:
                            try:
                                observe(json.loads(line))
                            except ValueError:
                                errors += 1
            files.add(str(path))
        except (OSError, ValueError, watch._DeepSeekHarnessMonitorError, *watch._SESSION_READ_ERRORS):
            errors += 1
    dbs = [watch._expand_path(spec) for spec in config.get("db_roots", [])]
    if name == "openclaw":
        dbs = watch._openclaw_sqlite_databases(roots, config.get("db_globs", []))
    for path in dbs:
        if not path.is_file():
            continue
        try:
            with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=2) as db:
                tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if name == "openclaw" and "transcript_events" in tables:
                    for row in db.execute("SELECT event_json,event_zstd,event_utf8_bytes FROM transcript_events WHERE created_at >= ?",
                                          (cutoff * 1000,)):
                        try:
                            observe(json.loads(watch._openclaw_decode_event_payload(*row)))
                        except (ValueError, TypeError, *watch._SESSION_READ_ERRORS):
                            errors += 1
                for table_name, column, timestamp, scale in (
                    ("session_message", "data", "time_created", 1000),
                    ("message", "data", "time_created", 1000),
                    ("sessions", "model", "started_at", 1),
                ):
                    if table_name not in tables:
                        continue
                    cols = {row[1] for row in db.execute(f'PRAGMA table_info("{table_name}")')}
                    if column not in cols or timestamp not in cols:
                        continue
                    for row in db.execute(f'SELECT "{column}" FROM "{table_name}" WHERE "{timestamp}" >= ?', (cutoff*scale,)):
                        if column == "model":
                            observe({"model": row[0]})
                        elif isinstance(row[0], str):
                            try:
                                observe(json.loads(row[0]))
                            except ValueError:
                                errors += 1
                files.add(str(path))
        except sqlite3.Error:
            errors += 1
    return {"window_days": 30, "selection": "recently_modified_files_and_timestamped_db_rows",
            "sources_read": len(files), "read_errors": errors,
            "synthetic_positive_usage": synthetic_positive,
            "observed_slugs": sorted(slugs), "exemptions": ["<synthetic>: zero-token synthetic messages only"],
            "unpriced_slugs": sorted(slug for slug in slugs if price_key(slug, table) is None
                                      or (slug == "<synthetic>" and synthetic_positive > 0))}


def summary(report):
    rows = ["| Agent | Tier | Version evidence (old -> new when observed) | Format change | App change | Held or blocked | What clears it |",
            "|---|---|---|---|---|---|---|"]
    for name, row in report.get("results", {}).items():
        weekly = row.get("weekly") or {}
        diff = weekly.get("schema_diff") or {}
        compat = row.get("compatibility") or {}
        hold = row.get("hold") or {}
        changes = row.get("changes") or {}
        drift = ", ".join(diff.get("unknown_types") or [])
        if diff.get("unknown_keys"):
            drift += " additive keys"
        clears = changes.get("clears") or compat.get("next_action") or "none"
        status = hold.get("reason") or compat.get("verdict", "unknown")
        if row.get("tier") == "Steward-verified" and not (row.get("installed") or {}).get("parsed_version"):
            status = "awaiting steward"
            clears = "steward verification" + (" via #83" if name == "fx" else "")
        if name == "qwen":
            clears = "owner-provided native evidence; unavailable maintainer lane"
        installed = row.get("new_version") or (row.get("installed") or {}).get("parsed_version") or "?"
        version = (f"{row['old_version']} -> {installed}" if row.get("old_version") is not None else
                   f"ceiling {row.get('verified_version', '?')}; installed {installed}")
        cells = [name, row.get("tier", "unrecorded"), version,
                 changes.get("format", drift or "not tracked"), changes.get("app", "not tracked"),
                 status, clears]
        rows.append("| " + " | ".join(str(cell).replace("|", "/").replace("\n", " ") for cell in cells) + " |")
    return "\n".join(rows)


def tiers():
    names = {"Codex": "codex", "Claude Code": "claude", "Cursor Agent": "cursor", "GitHub Copilot CLI": "copilot",
             "OpenCode": "opencode", "Antigravity CLI": "antigravity", "Pi": "pi", "Kimi Code": "kimi",
             "Grok CLI": "grok", "OpenClaw": "openclaw", "Hermes": "hermes", "Qwen Code": "qwen",
             "Devin CLI": "devin", "fx (vercel-labs)": "fx", "Cline CLI and Desktop": "cline",
             "DeepSeek Harness": "deepseek_harness"}
    result = {}
    for line in Path("STEWARDS.md").read_text().splitlines():
        cells = [part.strip() for part in line.strip("|").split("|")]
        if len(cells) == 4 and cells[0] in names:
            result[names[cells[0]]] = cells[3]
    return result


def matrix_hold(name):
    import agent_watch as watch
    key = watch.MATRIX_KEY_FOR_AGENT.get(name)
    active = False
    for line in Path("docs/agent-support/agent-support-matrix.yml").read_text().splitlines():
        if re.match(r"^  \w+:$", line):
            active = line.strip() == f"{key}:"
        if active and line.startswith("    hold: "):
            return json.loads(line.split("hold: ", 1)[1])
    return None
