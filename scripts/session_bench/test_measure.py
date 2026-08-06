"""Extractor tests: malformed input, byte accounting, sqlite handling.

Run: python3 -m pytest scripts/session_bench/test_measure.py -q
"""
import json
import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
from measure import content_bytes, measure_jsonl, measure_sqlite  # noqa: E402


def test_malformed_and_blank_lines(tmp_path):
    p = tmp_path / "s.jsonl"
    p.write_bytes(b'{"type":"a","text":"hi"}\n\nnot json at all\n{"type":"b"}\n')
    r = measure_jsonl(p)
    assert r["records"] == 3  # blank excluded; malformed counts as a record
    assert r["record_types"] == {"a": 1, "b": 1}  # malformed contributes no type
    assert r["content_bytes"] == 2


def test_unicode_utf8_byte_accounting(tmp_path):
    p = tmp_path / "u.jsonl"
    line = json.dumps({"type": "m", "text": "héé🙂"}, ensure_ascii=False).encode("utf-8")
    p.write_bytes(line + b"\n")
    r = measure_jsonl(p)
    assert r["content_bytes"] == len("héé🙂".encode("utf-8")) == 9


def test_max_record_and_truncated_last_line(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_bytes(b'{"type":"a","text":"xxxx"}\n{"type":"b","te')  # torn tail
    r = measure_jsonl(p)
    assert r["records"] == 2
    assert r["max_record_bytes"] == 26


def test_content_keys_include_tool_output_by_design():
    o = {"type": "tool", "output": "abc", "meta": {"stdout": "de"}, "id": "zz"}
    assert content_bytes(o) == 5  # documented: broad key heuristic counts tool output


def test_sqlite_with_wal_and_rows(tmp_path):
    db = tmp_path / "s.db"
    con = sqlite3.connect(db)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("CREATE TABLE part (id INTEGER, data TEXT)")
    con.execute("INSERT INTO part VALUES (1, ?)", ("x" * 100,))
    con.commit()
    r = measure_sqlite(db, ["part"], "data")
    con.close()
    assert r["tables"]["part"]["rows"] == 1
    assert r["tables"]["part"]["max_row_bytes"] == 100
    assert "wal_bytes" in r


def test_sqlite_missing_table_raises(tmp_path):
    db = tmp_path / "e.db"
    sqlite3.connect(db).close()
    with pytest.raises(sqlite3.OperationalError):
        measure_sqlite(db, ["nope"], "data")


def test_sqlite_empty_table_zeroes(tmp_path):
    db = tmp_path / "z.db"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE m (data TEXT)")
    con.commit()
    r = measure_sqlite(db, ["m"], "data")
    con.close()
    assert r["tables"]["m"] == {"rows": 0, "max_row_bytes": 0, "total_row_bytes": 0}
