"""Regression tests for the corrected readings (Goal acceptance item 4)."""

from __future__ import annotations

import pytest

from orxanalytics import correlate, metrics, registry
from orxanalytics.importers import import_zcode
from orxanalytics.importers.orxstate import import_orx_project


@pytest.fixture()
def loaded(world):
    import_zcode(world["store"], world["zcode_db"])
    registry.add_project(world["store"], world["proj_a"])
    import_orx_project(world["store"], world["proj_a"])
    correlate.correlate(world["store"], world["proj_a"])
    return world


def test_planner_counted_via_run_id_not_revision(loaded):
    rep = metrics.run_report(loaded["store"], loaded["proj_a"], "R001")
    c = rep["consumption"]
    # 5 attempts: planner (NULL revision) + 4 workers — all via run_id
    assert c["attempts"] == 5
    assert c["attempts_with_observation"] == 3   # planner, 201, 202
    assert c["input_tokens_sum"] == 398699 + 1000 + 5000
    assert c["output_tokens_sum"] == 10755 + 100 + 500


def test_canonical_dedupe_two_native_cli_and_host_report(loaded):
    rep = metrics.run_report(loaded["store"], loaded["proj_a"], "R001")
    c = rep["consumption"]
    # attempt 201 has native_cli rows 301 (1000/100) and 302 (1100/110):
    # canonical is the LOWEST id within the best source -> 1000/100
    # attempt 202 has native_cli 303 and host_report 304: native wins
    assert c["input_tokens_sum"] == 398699 + 1000 + 5000


def test_unknown_usage_stays_unknown(loaded):
    rep = metrics.run_report(loaded["store"], loaded["proj_a"], "R001")
    c = rep["consumption"]
    # attempts 203/204 have no observation: not zero-filled, flagged
    assert c["attempts_without_observation"] == 2
    assert c["partial"] is True
    cov = rep["coverage"]["by_role"]["worker"]
    assert cov == {"attempts": 4, "observed": 2, "missing_recorded": 1,
                   "unassessed": 1}


def test_first_pass_rate_corrected(loaded):
    fp = metrics.run_report(loaded["store"], loaded["proj_a"],
                            "R001")["first_pass_rate"]
    # rev1 T001: earliest row green but a failed event exists -> not first
    # rev1 T003, rev2 T001, rev2 T003: green earliest, no failed events
    assert fp["denominator"] == 4
    assert fp["numerator"] == 3
    # rev1 T002 never verified: outside the rate (the legacy script would
    # have counted it via worker_attempts <= 1)
    assert fp["tasks_never_verified"] == 1


def test_completion_time_separates_span_and_waiting(loaded):
    ct = metrics.run_report(loaded["store"], loaded["proj_a"],
                            "R001")["completion_time"]
    assert ct["spans_complete"] == 5
    assert ct["spans_incomplete"] == 0
    assert ct["execution_span_sum_sec"] == 8 + 9 + 8 + 28 + 37
    assert ct["waiting_sec"] == 79


def test_correlation_stored_and_inferred_with_basis(loaded):
    links = correlate.links_for_snapshot(
        loaded["store"], loaded["proj_a"],
        correlate.latest_snapshot(loaded["store"], loaded["proj_a"]))
    by_att = {l.attempt_id: l for l in links}
    assert by_att[200].authority == "stored"      # codex thread ref
    assert by_att[204].authority == "stored"      # zcode ref written by ORX
    l201 = by_att[201]
    assert l201.authority == "inferred" and l201.confidence == "high"
    assert l201.session_id == loaded["zcode"]["w1"]
    assert "attempt" in l201.basis and "marker" in l201.basis
    assert l201.evidence["matched_text"] == "attempt 201"
    l202 = by_att[202]
    assert l202.session_id == loaded["zcode"]["w2"]
    # 203 is a cursor/cli attempt with no ref: honestly unlinked
    assert 203 not in by_att


def test_ambiguous_marker_downgrades(loaded):
    store = loaded["store"]
    # a second subagent session whose first prompt names attempt 201
    store.conn.execute(
        "INSERT INTO zc_sessions VALUES ('sess_dup',?,?,NULL,'dup',1,2)",
        (loaded["zcode"]["w1"], loaded["proj_a"]))
    store.conn.execute(
        "INSERT INTO zc_first_parts VALUES ('sess_dup', "
        "'worker for attempt 201 again')")
    store.conn.commit()
    correlate.correlate(store, loaded["proj_a"])
    links = correlate.links_for_snapshot(
        store, loaded["proj_a"],
        correlate.latest_snapshot(store, loaded["proj_a"]))
    l = {x.attempt_id: x for x in links}[201]
    assert l.confidence == "ambiguous"
    assert set(l.session_id.split(",")) == {loaded["zcode"]["w1"],
                                            "sess_dup"}


def test_multi_attempt_session_window_split_honest(loaded):
    rep = metrics.run_report(loaded["store"], loaded["proj_a"], "R001")
    entries = {e["attempt_id"]: e for e in rep["session_side"]["linked"]}
    # w1 carries attempt 201 (inferred) and 204 (stored)
    ws = entries[204]["window_split"]
    assert ws is not None and ws["attributable"] is True
    # w1's only turn straddles both attempt spans: matched to neither
    assert ws["unattributed_within_session"]["input"] == 5_000_000
    assert ws["input_tokens"] == 0
    assert entries[201]["tree_totals"]["input_tokens"] == 5_000_000


def test_tree_totals_dedupe_and_isolation(loaded):
    store = loaded["store"]
    t = correlate.zcode_tree_totals(store, loaded["zcode"]["controller"])
    assert t["sessions_in_tree"] == 3            # controller + w1 + w2
    assert t["turns"] == 4
    assert t["input_tokens"] == 1_000_000 + 3_000_000 + 5_000_000 + 6_000_000
    assert t["output_tokens"] == 20_000 + 40_000 + 30_000 + 35_000
    # the other project's session is not part of this tree
    assert loaded["zcode"]["other"] not in t["session_ids"]
    t2 = correlate.zcode_tree_totals(store, loaded["zcode"]["w1"])
    assert t2["sessions_in_tree"] == 1
    assert t2["input_tokens"] == 5_000_000


def test_cross_project_same_short_ids_do_not_bleed(loaded):
    import sqlite3
    from conftest import make_orx_db
    proj_b = loaded["tmp"] / "ProjBORX"
    (proj_b / ".orx").mkdir(parents=True)
    make_orx_db(proj_b / ".orx" / "state.db")     # same R001, same T001
    registry.add_project(loaded["store"], str(proj_b))
    import_orx_project(loaded["store"], str(proj_b))
    correlate.correlate(loaded["store"], str(proj_b))
    rep_a = metrics.run_report(loaded["store"], loaded["proj_a"], "R001")
    rep_b = metrics.run_report(loaded["store"], str(proj_b), "R001")
    # both projects have their own 5 tasks; nothing doubled or mixed
    assert len(rep_a["delivery_quality"]["tasks"]) == 5
    assert len(rep_b["delivery_quality"]["tasks"]) == 5
    assert rep_a["snapshot_id"] != rep_b["snapshot_id"]
    # proj_b links resolved against proj_b's zcode directory: none match,
    # because its sessions live under a different directory
    idx = metrics.project_session_index(loaded["store"], loaded["proj_b"])
    assert all(s["session_id"] == loaded["zcode"]["other"]
               for s in idx["zcode_sessions"])


def test_replan_redo_requires_declared_edge(loaded):
    rw = metrics.run_report(loaded["store"], loaded["proj_a"],
                            "R001")["rework"]
    redo = rw["declared_cross_revision_redo"]
    assert len(redo) == 1
    assert redo[0]["source_revision"] == 1
    assert redo[0]["source_task_id"] == "T003"
    # rev1 T001 and rev2 T001 share a short id with NO declared edge:
    # they must not appear as redo/waste
    assert not any(r["source_task_id"] == "T001" for r in redo)
    # cross-attempt retry is visible on (revision, task)
    assert any(r["task_id"] == "T001" and r["revision_id"] == 11
               for r in rw["cross_attempt_retries"])


def test_native_session_report_without_orx(loaded):
    rep = metrics.session_report(loaded["store"], loaded["zcode"]["w1"])
    assert rep["tree"]["input_tokens"] == 5_000_000
    assert rep["logical_requests"] == 1
    assert rep["request_retry_rows"] == 0
    assert {t["tool_name"] for t in rep["tools"]} == {"Bash", "Read"}
    assert rep["longest_no_progress_sec"] == 130
    rep_o = metrics.session_report(loaded["store"], loaded["zcode"]["w2"])
    assert rep_o["request_retry_rows"] == 1
    assert rep_o["logical_requests"] == 1
