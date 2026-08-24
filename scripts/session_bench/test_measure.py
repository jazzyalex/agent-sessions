"""Extractor tests: malformed input, byte accounting, sqlite handling.

Run: python3 -m pytest scripts/session_bench/test_measure.py -q
"""
import json
import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
from measure import (content_bytes, measure_jsonl, measure_sqlite,  # noqa: E402
                     sqlite_freelist, sqlite_newest_snapshot_share)


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


def test_sqlite_freelist_counts_deleted_pages(tmp_path):
    db = tmp_path / "f.db"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE t (data TEXT)")
    con.executemany("INSERT INTO t VALUES (?)",
                    (("x" * 500,) for _ in range(400)))  # span many pages
    con.commit()
    con.execute("DELETE FROM t")
    con.commit()  # no vacuum: freed pages must sit on the freelist
    r = sqlite_freelist(db)
    con.close()
    assert r["freelist_pages"] > 0
    assert r["freelist_bytes"] == r["freelist_pages"] * r["page_size"]
    assert 0 < r["freelist_share_pct"] <= 100.0


def test_newest_snapshot_share_keeps_one_row_per_key(tmp_path):
    db = tmp_path / "s.db"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE event (id INTEGER PRIMARY KEY, key TEXT, data BLOB)")
    for blob in (b"a" * 100, b"b" * 120):  # superseded snapshot, then newest
        con.execute("INSERT INTO event (key, data) VALUES ('m1', ?)", (blob,))
    con.execute("INSERT INTO event (key, data) VALUES ('m2', (?))", (b"c" * 50,))
    con.commit()
    r = sqlite_newest_snapshot_share(db, "event", key_expr="key",
                                     order_expr="id", bytes_expr="LENGTH(data)")
    con.close()
    assert r["total_row_bytes"] == 270
    assert r["kept_row_bytes"] == 170
    assert r["removed_row_bytes"] == 100
    assert r["superseded_share_pct"] == 37.0


def test_collapse_cli_requires_key_and_bytes(tmp_path):
    import subprocess
    import sys
    db = tmp_path / "x.db"
    sqlite3.connect(db).close()
    r = subprocess.run(
        [sys.executable, str(Path(__file__).parent / "measure.py"),
         "--collapse-newest-per-key", str(db), "--collapse-table", "t"],
        capture_output=True, text=True)
    assert r.returncode != 0
    assert "--collapse-key" in r.stderr and "--collapse-bytes" in r.stderr
    assert "--collapse-key expr" not in r.stderr  # flag names, not human labels


def test_sqlite_freelist_bounded_on_live_wal_store(tmp_path):
    # A writer holding an un-checkpointed WAL: freelist_count sees the WAL
    # frames but the main file's st_size does not. The share must still be
    # computed from one consistent snapshot and stay within 0..100.
    db = tmp_path / "wal.db"
    con = sqlite3.connect(db)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA wal_autocheckpoint=0")
    con.execute("CREATE TABLE t (x)")
    con.executemany("INSERT INTO t VALUES (?)", [("a" * 1000,)] * 3000)
    con.commit()
    con.execute("DELETE FROM t")
    con.commit()  # writer stays open: WAL is not checkpointed
    r = sqlite_freelist(db)
    con.close()
    assert r["freelist_pages"] > 0
    assert 0 < r["freelist_share_pct"] <= 100.0
