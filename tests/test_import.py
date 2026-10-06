"""Importer behavior: idempotency, read-only, incremental cursors."""

from __future__ import annotations

import json
import sqlite3

from orxanalytics.dbutil import file_digest
from orxanalytics.importers import (import_codex, import_cursor,
                                    import_zcode)
from orxanalytics.importers.orxstate import import_orx_project
from orxanalytics import registry


def test_zcode_import_idempotent_and_readonly(world):
    d0 = file_digest(world["zcode_db"])
    r1 = import_zcode(world["store"], world["zcode_db"])
    assert "error" not in r1, r1
    assert r1["counts"]["sessions"] == 4
    assert r1["counts"]["turns"] == 5
    assert r1["counts"]["requests"] == 6
    assert r1["counts"]["tools"] == 4
    assert r1["counts"]["first_parts"] == 4
    r2 = import_zcode(world["store"], world["zcode_db"])
    assert all(v == 0 for k, v in r2["counts"].items()
               if k != "first_parts"), r2["counts"]
    assert r2["counts"]["first_parts"] == 0
    assert file_digest(world["zcode_db"]) == d0


def test_zcode_new_rows_are_incremental(world):
    import_zcode(world["store"], world["zcode_db"])
    conn = sqlite3.connect(world["zcode_db"])
    conn.execute(
        "INSERT INTO session VALUES ('sess_new',NULL,'/x','p','t',1,2)")
    conn.commit()
    conn.close()
    r = import_zcode(world["store"], world["zcode_db"])
    assert r["counts"]["sessions"] == 1
    assert r["counts"]["turns"] == 0  # untouched tables cost nothing


def test_orx_snapshot_refuses_gate_and_imports(world):
    # wrong schema version is refused honestly
    bad = world["tmp"] / "badproj"
    (bad / ".orx").mkdir(parents=True)
    conn = sqlite3.connect(bad / ".orx" / "state.db")
    conn.executescript("CREATE TABLE meta(key TEXT, value TEXT);"
                       "INSERT INTO meta VALUES ('schema_version','7');")
    conn.commit()
    conn.close()
    r = import_orx_project(world["store"], str(bad))
    assert "error" in r

    registry.add_project(world["store"], world["proj_a"])
    r = import_orx_project(world["store"], world["proj_a"])
    assert "error" not in r, r
    assert r["counts"]["orx_attempts"] == 5
    assert r["counts"]["orx_replan_sources"] == 1
    # second snapshot appends; both are independently recomputable
    r2 = import_orx_project(world["store"], world["proj_a"])
    assert r2["snapshot_id"] != r["snapshot_id"]
    rows = world["store"].conn.execute(
        "SELECT COUNT(*) FROM orx_snapshots").fetchone()[0]
    assert rows == 2
    # per-snapshot rows are not duplicated within one snapshot
    n = world["store"].conn.execute(
        "SELECT COUNT(*) FROM orx_attempts WHERE snapshot_id=?",
        (r2["snapshot_id"],)).fetchone()[0]
    assert n == 5


def test_orx_v8_file_imports_without_replan(world):
    v8 = world["tmp"] / "v8proj"
    (v8 / ".orx").mkdir(parents=True)
    # build a v8-shaped file: same core tables, no replan tables, version 8
    from conftest import make_orx_db
    make_orx_db(v8 / ".orx" / "state.db")
    conn = sqlite3.connect(v8 / ".orx" / "state.db")
    conn.execute("UPDATE meta SET value='8'")
    for t in ("replan_mappings", "replan_task_mappings", "replan_sources",
              "replan_superseded"):
        conn.execute(f"DROP TABLE {t}")
    conn.commit()
    conn.close()
    r = import_orx_project(world["store"], str(v8))
    assert "error" not in r, r
    assert r["counts"]["orx_tasks"] == 5
    assert "orx_replan_maps" not in r["counts"]


def test_codex_import_incremental_and_torn_tail(world):
    r1 = import_codex(world["store"], world["codex_dir"])
    assert r1["counts"]["threads"] == 1
    assert r1["counts"]["usage"] == 1
    # append a new record plus a torn (partial) line
    f = world["codex_dir"] / "2026" / "10" / "04" / "rollout-test.jsonl"
    with open(f, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "timestamp": "2026-10-04T12:01:00.000Z", "ordinal": 5,
            "type": "token_usage_record",
            "payload": {"thread_id": "01aa-cx-1", "turn_id": "turn1",
                        "response_id": "resp_2",
                        "usage": {"input_tokens": 50, "output_tokens": 5,
                                  "total_tokens": 55}}}) + "\n")
        fh.write('{"timestamp": "2026-10-04T12:0')   # torn tail
    r2 = import_codex(world["store"], world["codex_dir"])
    assert r2["counts"]["usage"] == 1
    assert r2["counts"]["threads"] == 0
    # completing the torn line next round parses it (no double count)
    with open(f, "a", encoding="utf-8") as fh:
        fh.write('1:00.500Z","ordinal":6,"type":"event_msg","payload":'
                 '{"type":"task_complete","turn_id":"turn2",'
                 '"completed_at":1791115261}}\n')
    r3 = import_codex(world["store"], world["codex_dir"])
    assert r3["counts"]["events"] == 1
    n = world["store"].conn.execute(
        "SELECT COUNT(*) FROM cx_usage").fetchone()[0]
    assert n == 2


def test_cursor_import_preserves_usage_across_rounds(world):
    r1 = import_cursor(world["store"], world["cursor_db"])
    assert r1["counts"]["composers_inserted"] == 1
    row = world["store"].conn.execute(
        "SELECT name, usage_json FROM cur_composers").fetchone()
    assert row["name"] == "cursor task"
    assert json.loads(row["usage_json"])["total"]["input"] == 2000
    # second round with no change: no refresh, usage preserved
    r2 = import_cursor(world["store"], world["cursor_db"])
    assert r2["counts"]["composers_inserted"] == 0
    assert r2["counts"]["composers_refreshed"] == 0
    row = world["store"].conn.execute(
        "SELECT usage_json FROM cur_composers").fetchone()
    assert row["usage_json"] is not None
    assert r1["counts"]["workspaces"] == 1
    assert r2["counts"]["workspaces"] == 0
    ws = world["store"].conn.execute(
        "SELECT folder FROM cur_workspaces").fetchone()
    assert ws["folder"] == "file://" + world["proj_a"]
