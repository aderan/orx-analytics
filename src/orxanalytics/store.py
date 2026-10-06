"""The analytics tool's own database.

Everything here lives under the data dir (default ``~/.orx-analytics``) and
is ours to write. Source databases are only ever opened through
:mod:`orxanalytics.dbutil` read-only helpers.

Idempotency contract: every imported row lands in a table whose natural
primary key comes from the source (session id, thread id, composer id, ...) or
from an append-only ORX snapshot id. Re-running an import upserts the same
rows and changes nothing else, so repeated collects never double count.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

STORE_VERSION = "1"

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS projects(
  project_key TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  orx_enabled INTEGER NOT NULL DEFAULT 1,
  registered_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sources(
  source_id TEXT PRIMARY KEY, kind TEXT NOT NULL, location TEXT NOT NULL,
  reader_version TEXT NOT NULL, last_probe_json TEXT, last_probe_at TEXT
);
CREATE TABLE IF NOT EXISTS import_state(
  source_id TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
  PRIMARY KEY(source_id, key)
);
CREATE TABLE IF NOT EXISTS import_runs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_id TEXT NOT NULL, started_at TEXT NOT NULL, finished_at TEXT,
  status TEXT NOT NULL, counts_json TEXT, error TEXT
);
-- zcode mirror --------------------------------------------------------
CREATE TABLE IF NOT EXISTS zc_sessions(
  session_id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT,
  zcode_project_id TEXT, title TEXT,
  created_ms INTEGER, updated_ms INTEGER
);
CREATE TABLE IF NOT EXISTS zc_turns(
  session_id TEXT NOT NULL, turn_id TEXT NOT NULL,
  status TEXT, started_ms INTEGER, completed_ms INTEGER, duration_ms INTEGER,
  model_request_count INTEGER, model_retry_count INTEGER,
  tool_call_count INTEGER, tool_error_count INTEGER,
  input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
  cache_read INTEGER, cache_creation INTEGER,
  PRIMARY KEY(session_id, turn_id)
);
CREATE TABLE IF NOT EXISTS zc_requests(
  session_id TEXT NOT NULL, logical_request_id TEXT NOT NULL,
  attempt_index INTEGER NOT NULL, turn_id TEXT, provider_id TEXT,
  model_id TEXT, status TEXT, started_ms INTEGER, completed_ms INTEGER,
  PRIMARY KEY(session_id, logical_request_id, attempt_index)
);
CREATE TABLE IF NOT EXISTS zc_tools(
  tool_call_id TEXT PRIMARY KEY, session_id TEXT, turn_id TEXT,
  tool_name TEXT, status TEXT, started_ms INTEGER, completed_ms INTEGER,
  duration_ms INTEGER, exit_code INTEGER
);
CREATE TABLE IF NOT EXISTS zc_first_parts(
  session_id TEXT PRIMARY KEY, first_part_text TEXT
);
-- codex mirror --------------------------------------------------------
CREATE TABLE IF NOT EXISTS cx_threads(
  thread_id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, cwd TEXT,
  created_at TEXT, updated_at TEXT
);
CREATE TABLE IF NOT EXISTS cx_turn_ctx(
  thread_id TEXT NOT NULL, turn_id TEXT NOT NULL,
  model TEXT, effort TEXT, cwd TEXT,
  PRIMARY KEY(thread_id, turn_id)
);
CREATE TABLE IF NOT EXISTS cx_usage(
  thread_id TEXT NOT NULL, response_id TEXT NOT NULL,
  turn_id TEXT, recorded_at TEXT,
  input_tokens INTEGER, cached_input INTEGER, cache_write INTEGER,
  output_tokens INTEGER, reasoning_output INTEGER, total_tokens INTEGER,
  PRIMARY KEY(thread_id, response_id)
);
CREATE TABLE IF NOT EXISTS cx_turn_events(
  thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, kind TEXT NOT NULL,
  at_epoch INTEGER, PRIMARY KEY(thread_id, turn_id, kind)
);
-- cursor mirror -------------------------------------------------------
CREATE TABLE IF NOT EXISTS cur_workspaces(
  workspace_id TEXT PRIMARY KEY, folder TEXT
);
CREATE TABLE IF NOT EXISTS cur_composers(
  composer_id TEXT PRIMARY KEY, workspace_id TEXT, name TEXT,
  created_ms INTEGER, updated_ms INTEGER, is_subagent INTEGER,
  subagent_type TEXT, usage_json TEXT, model_json TEXT
);
-- ORX snapshots (append-only per collect) ------------------------------
CREATE TABLE IF NOT EXISTS orx_snapshots(
  snapshot_id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_key TEXT NOT NULL, taken_at TEXT NOT NULL,
  schema_version TEXT NOT NULL, source_path TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS orx_runs(
  snapshot_id INTEGER NOT NULL, id TEXT NOT NULL, goal_id TEXT, status TEXT,
  created_at TEXT, updated_at TEXT, started_at TEXT, completed_at TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_goals(
  snapshot_id INTEGER NOT NULL, id TEXT NOT NULL, objective TEXT, status TEXT,
  context TEXT, constraints_json TEXT, acceptance_json TEXT,
  created_at TEXT, updated_at TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_revisions(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, run_id TEXT,
  revision INTEGER, depth INTEGER, planner_profile TEXT, status TEXT,
  created_at TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_tasks(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, revision_id INTEGER,
  task_id TEXT, objective TEXT, status TEXT, failure_reason TEXT,
  created_at TEXT, updated_at TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_attempts(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, revision_id INTEGER,
  task_id TEXT, assignment_id TEXT, role TEXT, profile TEXT, driver TEXT,
  harness TEXT, model TEXT, requested_effort TEXT, actual_effort TEXT,
  fallback_used INTEGER, started_at TEXT, ended_at TEXT, result TEXT,
  failure_reason TEXT, session_ref TEXT, run_id TEXT,
  usage_missing_reason TEXT, actual_model TEXT, model_source TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_verifications(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, revision_id INTEGER,
  task_id TEXT, attempt_id INTEGER, kind TEXT, command TEXT,
  exit_code INTEGER, passed INTEGER, output_path TEXT, created_at TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_usage_obs(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, attempt_id INTEGER,
  profile TEXT, run_id TEXT, task_id TEXT, input_tokens INTEGER,
  output_tokens INTEGER, cached_input INTEGER, source TEXT, accuracy TEXT,
  created_at TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_task_events(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, revision_id INTEGER,
  task_id TEXT, from_status TEXT, to_status TEXT, event TEXT, reason TEXT,
  created_at TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_evidence(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, attempt_id INTEGER,
  kind TEXT, path TEXT, created_at TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_replan_maps(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, run_id TEXT,
  revision_id INTEGER, prior_revision INTEGER,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_replan_task_maps(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, mapping_id INTEGER,
  run_id TEXT, revision_id INTEGER, task_id TEXT, classification TEXT,
  redo_reason TEXT,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_replan_sources(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, task_mapping_id INTEGER,
  run_id TEXT, source_revision INTEGER, source_task_id TEXT,
  source_task_row_id INTEGER, part INTEGER,
  PRIMARY KEY(snapshot_id, id)
);
CREATE TABLE IF NOT EXISTS orx_replan_superseded(
  snapshot_id INTEGER NOT NULL, id INTEGER NOT NULL, mapping_id INTEGER,
  run_id TEXT, source_revision INTEGER, source_task_id TEXT,
  disposition TEXT, successors_json TEXT, note TEXT,
  PRIMARY KEY(snapshot_id, id)
);
-- correlation ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS links(
  project_key TEXT NOT NULL, attempt_id INTEGER NOT NULL,
  harness TEXT NOT NULL, session_id TEXT NOT NULL,
  authority TEXT NOT NULL,        -- stored | inferred
  basis TEXT, evidence_json TEXT, confidence TEXT,
  computed_at TEXT NOT NULL, superseded_by INTEGER,
  PRIMARY KEY(project_key, attempt_id, harness)
);
-- findings (phase 4) ----------------------------------------------------
CREATE TABLE IF NOT EXISTS findings(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fingerprint TEXT NOT NULL UNIQUE,
  rule TEXT NOT NULL, project_key TEXT, title TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',   -- open|merged|linked|dismissed
  first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
  payload_json TEXT NOT NULL, merged_into INTEGER
);
CREATE TABLE IF NOT EXISTS finding_refs(
  finding_id INTEGER NOT NULL, kind TEXT NOT NULL, ref TEXT NOT NULL,
  PRIMARY KEY(finding_id, kind, ref)
);
CREATE TABLE IF NOT EXISTS finding_fixes(
  finding_id INTEGER NOT NULL, fix_ref TEXT NOT NULL,
  verified_at TEXT, before_json TEXT, after_json TEXT, comparable INTEGER,
  note TEXT, PRIMARY KEY(finding_id, fix_ref)
);
"""

DEFAULT_DATA_DIR = Path.home() / ".orx-analytics"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Store:
    def __init__(self, data_dir: Path | None = None):
        import os
        if data_dir is None:
            env = os.environ.get("ORX_ANALYTICS_HOME")
            data_dir = Path(env) if env else DEFAULT_DATA_DIR
        self.data_dir = Path(data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.path = self.data_dir / "analytics.db"
        self.conn = sqlite3.connect(self.path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys = ON")
        self.conn.executescript(SCHEMA)
        cur = self.conn.execute(
            "SELECT value FROM meta WHERE key='store_version'")
        row = cur.fetchone()
        if row is None:
            self.conn.execute(
                "INSERT INTO meta VALUES ('store_version', ?)", (STORE_VERSION,))
            self.conn.commit()
        elif row["value"] != STORE_VERSION:
            raise RuntimeError(
                f"analytics.db store_version {row['value']} != {STORE_VERSION}; "
                "this reader cannot open it")

    # -- generic helpers -------------------------------------------------
    def upsert(self, table: str, row: dict[str, Any],
               pk: list[str]) -> str:
        """Idempotent insert-or-replace by natural key. Returns the action."""
        cols = list(row.keys())
        exists = self.conn.execute(
            f"SELECT 1 FROM {table} WHERE "
            + " AND ".join(f"{k}=?" for k in pk),
            [row[k] for k in pk]).fetchone()
        ph = ",".join("?" for _ in cols)
        self.conn.execute(
            f"INSERT OR REPLACE INTO {table}({','.join(cols)}) VALUES ({ph})",
            [row[c] for c in cols])
        return "unchanged" if exists else "inserted"

    def get_state(self, source_id: str, key: str) -> str | None:
        r = self.conn.execute(
            "SELECT value FROM import_state WHERE source_id=? AND key=?",
            (source_id, key)).fetchone()
        return r["value"] if r else None

    def set_state(self, source_id: str, key: str, value: str) -> None:
        self.conn.execute(
            "INSERT OR REPLACE INTO import_state VALUES (?,?,?)",
            (source_id, key, value))

    def begin_import(self, source_id: str) -> int:
        cur = self.conn.execute(
            "INSERT INTO import_runs(source_id, started_at, status) "
            "VALUES (?,?,'running')", (source_id, now_iso()))
        self.conn.commit()
        return cur.lastrowid

    def finish_import(self, run_id: int, counts: dict[str, Any],
                      error: str | None = None) -> None:
        status = "error" if error else "done"
        self.conn.execute(
            "UPDATE import_runs SET finished_at=?, status=?, counts_json=?, "
            "error=? WHERE id=?",
            (now_iso(), status, json.dumps(counts), error, run_id))
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()
