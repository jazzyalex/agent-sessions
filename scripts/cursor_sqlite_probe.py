#!/usr/bin/env python3
"""Privacy-safe health check for Cursor chat and ACP SQLite persistence.

The weekly probe reports only schema key names, JSON value types, SQLite column
names, protobuf field/wire pairs, and aggregate counts. It never emits paths,
session IDs, metadata values, transcript text, or blob contents.

Exit codes:
  0 — all discovered supported Cursor SQLite surfaces passed, and at least one was found
  1 — no supported Cursor SQLite store was found
  2 — a store was unreadable
  3 — required structure or types did not match the app parser
"""
import heapq
import hashlib
import json
import os
import sqlite3
import stat
import sys
import uuid
from pathlib import Path
from typing import Any


REQUIRED_CHAT_META_KEYS = {"agentId", "name", "createdAt"}
ACP_TABLE_COLUMNS = {"blobs": ["id", "data"], "meta": ["key", "value"]}
ACP_SAMPLE_LIMIT = 5
ACP_MAX_BLOB_BYTES = 16 * 1024 * 1024
ACP_MAX_TOTAL_BLOB_BYTES = 64 * 1024 * 1024
ACP_MAX_PROTO_FIELDS = 100_000
ACP_MAX_SIDECAR_BYTES = 1024 * 1024
ACP_MAX_ROOT_META_HEX_CHARS = 2 * 1024 * 1024
ACP_MAX_REFERENCES = 10_000
ACP_MAX_DISCOVERY_ENTRIES = 10_000
CHAT_MAX_DISCOVERY_ENTRIES = 10_000
CHAT_MAX_META_HEX_CHARS = 2 * 1024 * 1024


class _ACPProbeLimitError(Exception):
    pass


def _json_type(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return "unknown"


def _failure(error: str, exit_code: int = 3, **details: Any) -> dict[str, Any]:
    return {"ok": False, **details, "error": error, "exit_code": exit_code}


def find_newest_store_db() -> Path | None:
    root = Path.home() / ".cursor" / "chats"
    if not root.exists():
        return None
    newest: tuple[int, Path] | None = None
    entry_count = 0
    try:
        with os.scandir(root) as workspaces:
            for workspace in workspaces:
                entry_count += 1
                if entry_count > CHAT_MAX_DISCOVERY_ENTRIES:
                    raise _ACPProbeLimitError("chat_discovery_entry_limit")
                if not workspace.is_dir(follow_symlinks=False):
                    continue
                with os.scandir(workspace.path) as agents:
                    for agent in agents:
                        entry_count += 1
                        if entry_count > CHAT_MAX_DISCOVERY_ENTRIES:
                            raise _ACPProbeLimitError("chat_discovery_entry_limit")
                        if not agent.is_dir(follow_symlinks=False):
                            continue
                        store = Path(agent.path) / "store.db"
                        if not _regular_file(store, required=True):
                            continue
                        candidate = (store.lstat().st_mtime_ns, store)
                        if newest is None or candidate[0] > newest[0]:
                            newest = candidate
    except OSError as error:
        raise _ACPProbeLimitError(
            f"chat_discovery_failed: {type(error).__name__}"
        ) from None
    return newest[1] if newest is not None else None


def probe(db_path: Path) -> dict[str, Any]:
    """Validate one legacy Cursor chat store without returning metadata values."""
    try:
        con = sqlite3.connect(f"{db_path.resolve().as_uri()}?mode=ro", uri=True)
    except Exception as error:
        return _failure(f"open_failed: {type(error).__name__}", exit_code=2)

    try:
        # Keep the size check and value read on one SQLite snapshot so an
        # active writer cannot replace the row with a larger value between
        # the two statements.
        con.execute("BEGIN")
        size_row = con.execute(
            "SELECT length(value) FROM meta WHERE key='0' LIMIT 1"
        ).fetchone()
        if size_row is None or not isinstance(size_row[0], int):
            return _failure("meta_key_0_missing", exit_code=2)
        if size_row[0] > CHAT_MAX_META_HEX_CHARS:
            return _failure("meta_size_limit", exit_code=2)
        row = con.execute("SELECT value FROM meta WHERE key='0' LIMIT 1").fetchone()
    except Exception as error:
        return _failure(f"meta_read_failed: {type(error).__name__}", exit_code=2)
    finally:
        con.close()

    if row is None:
        return _failure("meta_key_0_missing", exit_code=2)

    try:
        if not isinstance(row[0], str):
            raise TypeError("meta value is not text")
        meta = json.loads(bytes.fromhex(row[0]).decode("utf-8"))
    except Exception as error:
        return _failure(f"meta_decode_failed: {type(error).__name__}", exit_code=2)
    if not isinstance(meta, dict):
        return _failure("meta_not_dict")

    meta_keys = sorted(meta)
    missing = REQUIRED_CHAT_META_KEYS - set(meta_keys)
    if missing:
        return _failure("missing_required_keys", meta_keys=meta_keys,
                        missing_required_keys=sorted(missing))

    invalid_types = []
    if not isinstance(meta.get("agentId"), str):
        invalid_types.append("agentId:string")
    created_at = meta.get("createdAt")
    if isinstance(created_at, bool) or not isinstance(created_at, (int, float)):
        invalid_types.append("createdAt:number")
    if invalid_types:
        return _failure("invalid_required_types", meta_keys=meta_keys,
                        invalid_required_types=invalid_types)

    return {
        "ok": True,
        "status": "checked",
        "schema_fingerprint": {
            "type_counts": {"meta": 1},
            "type_keys": {"meta": meta_keys},
            "key_types": {key: _json_type(meta[key]) for key in meta_keys},
        },
        "error": None,
        "exit_code": 0,
    }


def _regular_file(path: Path, *, required: bool) -> bool:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return not required
    except OSError:
        return False
    return stat.S_ISREG(mode)


def _read_varint(data: bytes, offset: int) -> tuple[int, int] | None:
    value = 0
    for index in range(10):
        if offset >= len(data):
            return None
        byte = data[offset]
        offset += 1
        if index == 9 and byte > 1:
            return None
        value |= (byte & 0x7F) << (index * 7)
        if byte & 0x80 == 0:
            return value, offset
    return None


def _parse_proto_fields(
    data: bytes, budget: dict[str, int] | None = None
) -> list[tuple[int, int, bytes | None]] | None:
    fields: list[tuple[int, int, bytes | None]] = []
    offset = 0
    while offset < len(data):
        decoded = _read_varint(data, offset)
        if decoded is None:
            return None
        key, offset = decoded
        number, wire = key >> 3, key & 7
        if number == 0:
            return None
        payload = None
        if wire == 0:
            decoded = _read_varint(data, offset)
            if decoded is None:
                return None
            _, offset = decoded
        elif wire == 1:
            if len(data) - offset < 8:
                return None
            offset += 8
        elif wire == 2:
            decoded = _read_varint(data, offset)
            if decoded is None:
                return None
            length, offset = decoded
            if length > len(data) - offset:
                return None
            payload = data[offset:offset + length]
            offset += length
        elif wire == 5:
            if len(data) - offset < 4:
                return None
            offset += 4
        else:
            return None
        fields.append((number, wire, payload))
        if budget is not None:
            budget["proto_fields"] += 1
            if budget["proto_fields"] > ACP_MAX_PROTO_FIELDS:
                raise _ACPProbeLimitError("acp_protobuf_field_count_limit")
    return fields


def _data_fields(fields: list[tuple[int, int, bytes | None]], number: int) -> list[bytes]:
    return [payload for field, wire, payload in fields
            if field == number and wire == 2 and payload is not None]


def _wire_signature(fields: list[tuple[int, int, bytes | None]]) -> list[str]:
    return sorted({f"{number}:{wire}" for number, wire, _ in fields})


def _table_columns(con: sqlite3.Connection, table: str) -> list[str]:
    return [str(row[1]) for row in con.execute(f"PRAGMA table_info({table})")]


def _read_blob(
    con: sqlite3.Connection, blob_id: bytes, budget: dict[str, int]
) -> bytes | None:
    blob_key = blob_id.hex()
    size_row = con.execute("SELECT length(data) FROM blobs WHERE id = ? LIMIT 1",
                           (blob_key,)).fetchone()
    if size_row is None or not isinstance(size_row[0], int):
        return None
    if size_row[0] > ACP_MAX_BLOB_BYTES:
        raise _ACPProbeLimitError("acp_blob_size_limit")
    budget["blob_bytes"] += size_row[0]
    if budget["blob_bytes"] > ACP_MAX_TOTAL_BLOB_BYTES:
        raise _ACPProbeLimitError("acp_total_blob_size_limit")
    row = con.execute("SELECT data FROM blobs WHERE id = ? LIMIT 1",
                      (blob_key,)).fetchone()
    if row is None or not isinstance(row[0], bytes):
        return None
    data = row[0]
    return data if hashlib.sha256(data).digest() == blob_id else None


def _read_bounded_text(path: Path, max_bytes: int) -> str:
    size = path.stat().st_size
    if size > max_bytes:
        raise _ACPProbeLimitError("acp_meta_sidecar_size_limit")
    with path.open("r", encoding="utf-8") as handle:
        return handle.read(max_bytes + 1)


def _decode_blob_id(value: Any) -> bytes | None:
    if not isinstance(value, str):
        return None
    clean = value[2:] if value.startswith("0x") else value
    try:
        decoded = bytes.fromhex(clean)
    except ValueError:
        return None
    return decoded if len(decoded) == 32 else None


def _utf8(value: bytes) -> str | None:
    try:
        return value.decode("utf-8")
    except UnicodeDecodeError:
        return None


def probe_acp(db_path: Path) -> dict[str, Any]:
    """Validate one ACP store using the app's current persisted graph boundary."""
    session_dir = db_path.parent
    try:
        expected_uuid = uuid.UUID(session_dir.name)
    except ValueError:
        return _failure("acp_session_directory_not_uuid")
    if session_dir.parent.name != "acp-sessions":
        return _failure("acp_parent_directory_mismatch")
    try:
        if not stat.S_ISDIR(session_dir.lstat().st_mode) or session_dir.is_symlink():
            return _failure("acp_session_directory_not_canonical")
        acp_root = session_dir.parent
        if not stat.S_ISDIR(acp_root.lstat().st_mode) or acp_root.is_symlink():
            return _failure("acp_root_not_canonical_directory")
    except OSError:
        return _failure("acp_session_directory_unreadable", exit_code=2)
    if not _regular_file(db_path, required=True):
        return _failure("acp_store_not_regular")
    sidecar_path = session_dir / "meta.json"
    if not _regular_file(sidecar_path, required=True):
        return _failure("acp_meta_sidecar_missing_or_not_regular")
    for companion in (session_dir / "store.db-wal", session_dir / "store.db-shm"):
        if companion.exists() and not _regular_file(companion, required=False):
            return _failure("acp_sqlite_companion_not_regular")

    try:
        sidecar = json.loads(_read_bounded_text(sidecar_path, ACP_MAX_SIDECAR_BYTES))
    except _ACPProbeLimitError as error:
        return _failure(str(error))
    except Exception as error:
        return _failure(f"acp_meta_sidecar_decode_failed: {type(error).__name__}")
    if not isinstance(sidecar, dict):
        return _failure("acp_meta_sidecar_not_dict")
    schema_version = sidecar.get("schemaVersion")
    if isinstance(schema_version, bool) or not isinstance(schema_version, int):
        return _failure("acp_schema_version_wrong_type")
    if schema_version != 1:
        return _failure("acp_schema_version_unsupported")

    try:
        con = sqlite3.connect(f"{db_path.resolve().as_uri()}?mode=ro", uri=True,
                              timeout=0.25)
    except Exception as error:
        return _failure(f"acp_open_failed: {type(error).__name__}", exit_code=2)
    try:
        columns = {table: _table_columns(con, table) for table in ACP_TABLE_COLUMNS}
        if columns != ACP_TABLE_COLUMNS:
            return _failure("acp_sqlite_schema_mismatch", table_columns=columns)
        con.execute("BEGIN")
        size_row = con.execute(
            "SELECT length(value) FROM meta WHERE key = '0'"
        ).fetchone()
        if size_row is None or not isinstance(size_row[0], int):
            return _failure("acp_root_meta_missing_or_wrong_type")
        if size_row[0] > ACP_MAX_ROOT_META_HEX_CHARS:
            return _failure("acp_root_meta_size_limit")
        row = con.execute("SELECT value FROM meta WHERE key = '0'").fetchone()
        if row is None or not isinstance(row[0], str):
            return _failure("acp_root_meta_missing_or_wrong_type")
        try:
            root_meta = json.loads(bytes.fromhex(row[0]).decode("utf-8"))
        except Exception:
            return _failure("acp_root_meta_decode_failed")
        if not isinstance(root_meta, dict):
            return _failure("acp_root_meta_not_dict")
        try:
            agent_uuid = uuid.UUID(root_meta.get("agentId"))
        except (AttributeError, TypeError, ValueError):
            return _failure("acp_agent_id_missing_or_wrong_type")
        if agent_uuid != expected_uuid:
            return _failure("acp_agent_id_directory_mismatch")
        root_id = _decode_blob_id(root_meta.get("latestRootBlobId"))
        if root_id is None:
            return _failure("acp_root_blob_id_missing_or_wrong_type")

        budget = {"blob_bytes": 0, "proto_fields": 0}
        root_blob = _read_blob(con, root_id, budget)
        root_fields = (_parse_proto_fields(root_blob, budget)
                       if root_blob is not None else None)
        if root_fields is None:
            return _failure("acp_root_blob_missing_or_malformed")
        wire_fields: dict[str, set[str]] = {"root": set(_wire_signature(root_fields))}
        blob_count = 1
        reference_count = 0

        def count_references(count: int) -> None:
            nonlocal reference_count
            reference_count += count
            if reference_count > ACP_MAX_REFERENCES:
                raise _ACPProbeLimitError("acp_reference_count_limit")

        turn_ids = _data_fields(root_fields, 8)
        count_references(len(turn_ids))
        for turn_id in turn_ids:
            if len(turn_id) != 32:
                return _failure("acp_turn_reference_wrong_type")
            turn_blob = _read_blob(con, turn_id, budget)
            turn_fields = (_parse_proto_fields(turn_blob, budget)
                           if turn_blob is not None else None)
            if turn_fields is None:
                return _failure("acp_turn_blob_missing_or_malformed")
            wire_fields.setdefault("turn", set()).update(_wire_signature(turn_fields))
            blob_count += 1
            agent_turns = _data_fields(turn_fields, 1)
            shell_turns = _data_fields(turn_fields, 2)
            if len(agent_turns) + len(shell_turns) != 1:
                return _failure("acp_turn_variant_invalid")
            if shell_turns:
                shell_fields = _parse_proto_fields(shell_turns[0], budget)
                if shell_fields is None:
                    return _failure("acp_shell_turn_malformed")
                wire_fields.setdefault("shell_turn", set()).update(_wire_signature(shell_fields))
                continue

            agent_fields = _parse_proto_fields(agent_turns[0], budget)
            if agent_fields is None:
                return _failure("acp_agent_turn_malformed")
            wire_fields.setdefault("agent_turn", set()).update(_wire_signature(agent_fields))
            user_ids = _data_fields(agent_fields, 1)
            count_references(len(user_ids))
            if not user_ids or len(user_ids[0]) != 32:
                return _failure("acp_user_reference_missing_or_wrong_type")
            user_blob = _read_blob(con, user_ids[0], budget)
            user_fields = (_parse_proto_fields(user_blob, budget)
                           if user_blob is not None else None)
            user_text = _data_fields(user_fields, 1) if user_fields is not None else []
            if not user_text or not user_text[0] or _utf8(user_text[0]) is None:
                return _failure("acp_user_blob_missing_or_malformed")
            wire_fields.setdefault("user_message", set()).update(_wire_signature(user_fields))
            blob_count += 1

            step_ids = _data_fields(agent_fields, 2)
            count_references(len(step_ids))
            for step_id in step_ids:
                if len(step_id) != 32:
                    return _failure("acp_step_reference_wrong_type")
                step_blob = _read_blob(con, step_id, budget)
                step_fields = (_parse_proto_fields(step_blob, budget)
                               if step_blob is not None else None)
                if step_fields is None:
                    return _failure("acp_step_blob_missing_or_malformed")
                wire_fields.setdefault("step", set()).update(_wire_signature(step_fields))
                blob_count += 1
                variants = [number for number in (1, 2, 3) if _data_fields(step_fields, number)]
                if len(variants) != 1:
                    return _failure("acp_step_variant_invalid")
                if variants[0] != 1:
                    continue
                assistant_id = _data_fields(step_fields, 1)[0]
                count_references(1)
                if len(assistant_id) != 32:
                    return _failure("acp_assistant_reference_wrong_type")
                assistant_blob = _read_blob(con, assistant_id, budget)
                assistant_fields = (_parse_proto_fields(assistant_blob, budget)
                                    if assistant_blob is not None else None)
                assistant_text = (_data_fields(assistant_fields, 1)
                                  if assistant_fields is not None else [])
                if not assistant_text or not assistant_text[0] or _utf8(assistant_text[0]) is None:
                    return _failure("acp_assistant_blob_missing_or_malformed")
                wire_fields.setdefault("assistant_message", set()).update(
                    _wire_signature(assistant_fields))
                blob_count += 1
    except _ACPProbeLimitError as error:
        return _failure(str(error))
    except sqlite3.Error as error:
        return _failure(f"acp_sqlite_read_failed: {type(error).__name__}", exit_code=2)
    finally:
        con.close()

    root_keys = sorted(root_meta)
    sidecar_keys = sorted(sidecar)
    return {
        "ok": True,
        "status": "checked",
        "schema_fingerprint": {
            "table_columns": ACP_TABLE_COLUMNS,
            "root_meta_keys": root_keys,
            "root_meta_key_types": {key: _json_type(root_meta[key]) for key in root_keys},
            "sidecar_keys": sidecar_keys,
            "sidecar_key_types": {key: _json_type(sidecar[key]) for key in sidecar_keys},
            "protobuf_wire_fields": {key: sorted(value) for key, value in sorted(wire_fields.items())},
            "validated_blob_count": blob_count,
        },
        "error": None,
        "exit_code": 0,
    }


def probe_acp_root(root: Path | None = None,
                   sample_limit: int = ACP_SAMPLE_LIMIT) -> dict[str, Any]:
    root = root or (Path.home() / ".cursor" / "acp-sessions")
    if not root.exists():
        return {"ok": True, "status": "not_found", "sample_count": 0,
                "error": None, "exit_code": 0}
    try:
        if root.is_symlink() or not root.is_dir():
            return _failure("acp_root_not_canonical_directory")
        newest: list[tuple[int, str, Path]] = []
        with os.scandir(root) as entries:
            for entry_index, entry in enumerate(entries, start=1):
                if entry_index > ACP_MAX_DISCOVERY_ENTRIES:
                    return _failure("acp_discovery_entry_limit")
                try:
                    uuid.UUID(entry.name)
                except ValueError:
                    continue
                store = Path(entry.path) / "store.db"
                if not _regular_file(store, required=True):
                    continue
                item = (store.lstat().st_mtime_ns, str(store), store)
                if len(newest) < sample_limit:
                    heapq.heappush(newest, item)
                elif item > newest[0]:
                    heapq.heapreplace(newest, item)
        candidates = [item[2] for item in sorted(newest, reverse=True)]
    except OSError as error:
        return _failure(f"acp_discovery_failed: {type(error).__name__}", exit_code=2)
    if not candidates:
        return {"ok": True, "status": "not_found", "sample_count": 0,
                "error": None, "exit_code": 0}

    fingerprints = []
    for store in candidates:
        result = probe_acp(store)
        if not result["ok"]:
            result["sample_count"] = len(fingerprints) + 1
            return result
        fingerprints.append(result["schema_fingerprint"])
    return {
        "ok": True,
        "status": "checked",
        "sample_count": len(fingerprints),
        "schema_fingerprints": fingerprints,
        "error": None,
        "exit_code": 0,
    }


def main() -> int:
    try:
        chat_path = find_newest_store_db()
        chat = (probe(chat_path) if chat_path is not None else
                {"ok": True, "status": "not_found", "error": None, "exit_code": 0})
    except _ACPProbeLimitError as error:
        chat = _failure(str(error), exit_code=2)
    acp = probe_acp_root()
    chat_code = chat.pop("exit_code")
    acp_code = acp.pop("exit_code")
    found = chat.get("status") == "checked" or acp.get("status") == "checked"
    ok = bool(chat.get("ok")) and bool(acp.get("ok")) and found
    result = {"ok": ok, "chat": chat, "acp": acp}
    if not found and chat["ok"] and acp["ok"]:
        result["error"] = "no_cursor_sqlite_store_found"
        exit_code = 1
    elif not chat["ok"]:
        result["error"] = "chat_probe_failed"
        exit_code = chat_code
    elif not acp["ok"]:
        result["error"] = "acp_probe_failed"
        exit_code = acp_code
    else:
        result["error"] = None
        exit_code = 0
    print(json.dumps(result, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
