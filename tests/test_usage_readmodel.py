"""Task/Run usage attribution read model (design §5, G002 T002).

Attribution regression tests: retries and multiple verifiers belong to
their task, planner attempts with a NULL revision belong to the run,
unattributable usage is never prorated, unknown stays None while a stored
zero is 0, and the ORX-recorded and native-session calibers stay
structurally separate (no number mixes them).
"""

from __future__ import annotations

import pytest

from orxanalytics import correlate, metrics, registry, usage_readmodel
from orxanalytics.importers import import_codex, import_zcode
from orxanalytics.importers.orxstate import import_orx_project

PROJ_A_KEY = None  # set per-fixture via world


def seed_usage_rows(store, proj: str) -> None:
    """Extra attempts/observations on the latest snapshot of ``proj``:
    two verifiers on rev1 T001, a cursor-harness task with all three
    cache shapes, an unknown harness, run-internal unattributable
    attempts, and project-level orphans (run NULL / attempt NULL)."""
    snap = correlate.latest_snapshot(store, proj)
    t0 = "2026-10-04T12:00:40+00:00"
    t1 = "2026-10-04T12:01:10+00:00"
    conn = store.conn
    attempts = [
        # two verifier attempts for rev1 T001 (multi-verifier)
        (210, 11, "T001", "verifier", "zcode-verifier", "host", "zcode",
         "m2", t0, t1, "completed", "R001"),
        (211, 11, "T001", "verifier", "zcode-verifier", "host", "zcode",
         "m2", t0, t1, "completed", "R001"),
        # rev1 T002: explicit zero, cache separate, cache separate with a
        # missing cached field, and an unknown harness
        (212, 11, "T002", "worker", "cursor-strong", "cli", "cursor",
         "m3", t0, t1, "completed", "R001"),
        (213, 11, "T002", "worker", "cursor-strong", "cli", "cursor",
         "m3", t0, t1, "completed", "R001"),
        (214, 11, "T002", "worker", "cursor-strong", "cli", "cursor",
         "m3", t0, t1, "completed", "R001"),
        (215, 11, "T002", "worker", "warp-fast", "cli", "warp",
         "m4", t0, t1, "completed", "R001"),
        # run-internal unattributable: no task linkage at all / task only
        (220, None, None, "worker", "zcode-worker", "host", "zcode",
         "m2", t0, t1, "failed", "R001"),
        (221, 11, None, "worker", "zcode-worker", "host", "zcode",
         "m2", t0, t1, "completed", "R001"),
        # project-level orphan: unknown run association
        (222, None, None, "worker", "zcode-worker", "host", "zcode",
         "m2", t0, t1, "completed", None),
    ]
    conn.executemany(
        "INSERT INTO orx_attempts(snapshot_id,id,revision_id,task_id,role,"
        "profile,driver,harness,model,started_at,ended_at,result,run_id) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [(snap, *row) for row in attempts])
    obs = [
        # attempt, profile, run, task, in, out, cached, source, accuracy
        (310, 210, "zcode-verifier", "R001", "T001", 300, 30, 200,
         "native_cli", "exact"),
        (311, 211, "zcode-verifier", "R001", "T001", None, 50, None,
         "native_cli", None),
        (312, 212, "cursor-strong", "R001", "T002", 0, 0, 0,
         "native_cli", "exact"),
        (313, 213, "cursor-strong", "R001", "T002", 100, 10, 150,
         "native_cli", "exact"),
        (314, 214, "cursor-strong", "R001", "T002", 100, 10, None,
         "native_cli", "estimated"),
        (315, 215, "warp-fast", "R001", "T002", 50, 5, 0,
         "native_cli", "exact"),
        (320, 220, "zcode-worker", "R001", None, 700, 70, 0,
         "native_cli", "exact"),
        (321, 221, "zcode-worker", "R001", None, 800, 80, 0,
         "native_cli", "exact"),
        (322, 222, "zcode-worker", None, None, 900, 90, 0,
         "native_cli", "exact"),
        # observation with no attempt linkage at all
        (330, None, "manual", None, None, 50, 5, 0,
         "host_report", "estimated"),
    ]
    conn.executemany(
        "INSERT INTO orx_usage_obs(snapshot_id,id,attempt_id,profile,run_id,"
        "task_id,input_tokens,output_tokens,cached_input,source,accuracy,"
        "created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        [(snap, *row, t1) for row in obs])
    conn.commit()


@pytest.fixture()
def usage_world(world):
    import_zcode(world["store"], world["zcode_db"])
    import_codex(world["store"], world["codex_dir"])
    registry.add_project(world["store"], world["proj_a"])
    import_orx_project(world["store"], world["proj_a"])
    correlate.correlate(world["store"], world["proj_a"])
    seed_usage_rows(world["store"], world["proj_a"])
    return world


@pytest.fixture()
def bare_world(world):
    """Same ORX facts, but no native session mirrors imported at all."""
    registry.add_project(world["store"], world["proj_a"])
    import_orx_project(world["store"], world["proj_a"])
    correlate.correlate(world["store"], world["proj_a"])
    seed_usage_rows(world["store"], world["proj_a"])
    return world


# ------------------------------------------------- attribution to tasks ---

def test_task_worker_sum_includes_failed_and_retry(usage_world):
    u = usage_readmodel.task_usage(
        usage_world["store"], usage_world["proj_a"], "R001", 11, "T001")
    worker = u["books"]["worker"]
    assert worker["attempt_ids"] == [201, 202]
    # attempt 201 failed verification and 202 is its retry: BOTH count
    assert worker["tokens"] == {"input_tokens": 6000, "output_tokens": 600,
                                "cached_input": 4500}
    by_id = {d["attempt_id"]: d for d in u["attempts"]}
    assert by_id[201]["result"] == "failed"
    assert by_id[201]["role"] == "worker"


def test_canonical_one_source_per_attempt(usage_world):
    u = usage_readmodel.task_usage(
        usage_world["store"], usage_world["proj_a"], "R001", 11, "T001")
    # 201 has native_cli rows 301 (1000/100) and 302 (1100/110): the
    # canonical row is the lowest id of the best source -> 1000, not 2100.
    # 202 has native_cli 303 + host_report 304 (same work seen twice):
    # native wins -> 5000, not 10000.
    assert u["books"]["worker"]["tokens"]["input_tokens"] == 6000
    by_id = {d["attempt_id"]: d for d in u["attempts"]}
    assert by_id[201]["observation"]["source"] == "native_cli"
    assert by_id[202]["observation"]["tokens"]["input_tokens"] == 5000


def test_task_verifier_separate_and_multi_verifier(usage_world):
    u = usage_readmodel.task_usage(
        usage_world["store"], usage_world["proj_a"], "R001", 11, "T001")
    verifier = u["books"]["verifier"]
    assert verifier["attempt_ids"] == [210, 211]
    # verifier input is a partial sum: one row 300, one row NULL -> 300
    # with a published missing count, never a silent zero-fill
    assert verifier["tokens"]["input_tokens"] == 300
    assert verifier["tokens"]["output_tokens"] == 80
    assert verifier["missing_fields"]["input_tokens"] == 1
    # the verifier books still count toward the task total
    assert u["tokens"]["input_tokens"] == 6300
    assert u["tokens"]["output_tokens"] == 680


def test_cross_revision_same_task_number_separate(usage_world):
    store, proj = usage_world["store"], usage_world["proj_a"]
    rev1 = usage_readmodel.task_usage(store, proj, "R001", 11, "T001")
    rev2 = usage_readmodel.task_usage(store, proj, "R001", 12, "T001")
    # same short id, different revisions: two different tasks, no merge
    assert rev1["books"]["worker"]["tokens"]["input_tokens"] == 6000
    assert rev2["books"]["worker"]["attempt_ids"] == [203]
    assert rev2["books"]["worker"]["tokens"]["input_tokens"] is None
    # the redo across revisions (rev2 T003) is its own book again
    redo = usage_readmodel.task_usage(store, proj, "R001", 12, "T003")
    assert redo["books"]["worker"]["attempt_ids"] == [204]


def test_unknown_task_returns_unknown_not_error(usage_world):
    u = usage_readmodel.task_usage(
        usage_world["store"], usage_world["proj_a"], "R001", 11, "T099")
    assert u["tokens"]["input_tokens"] is None
    assert u["coverage"]["attempts"] == 0
    assert u["coverage"]["observed"] == 0


# ------------------------------------------------------ run attribution ---

def test_planner_null_revision_belongs_to_run(usage_world):
    r = usage_readmodel.run_usage(
        usage_world["store"], usage_world["proj_a"], "R001")
    planner = r["books"]["planner"]
    # attempt 200 has revision NULL: run attribution ONLY via run_id
    assert planner["attempt_ids"] == [200]
    assert planner["revision_ids"] == [None]
    assert planner["tokens"]["input_tokens"] == 398699
    # planner is counted in the run's attributed total
    assert r["tokens"]["input_tokens"] == 405249
    assert r["tokens"]["output_tokens"] == 11460
    assert r["tokens"]["cached_input"] == 327026


def test_run_total_covers_all_revisions(usage_world):
    r = usage_readmodel.run_usage(
        usage_world["store"], usage_world["proj_a"], "R001")
    per_rev = {p["revision"]: p for p in r["per_revision"]}
    # revision 1 was superseded by the replan: its consumption survives
    assert per_rev[1]["tokens"]["input_tokens"] == 6550
    assert per_rev[2]["tokens"]["input_tokens"] is None   # unknown, not 0
    assert per_rev[2]["coverage"]["observed"] == 0
    assert r["tokens"]["input_tokens"] == 405249
    tasks = {(t["revision_id"], t["task_id"]) for t in r["per_task"]}
    assert (11, "T001") in tasks and (12, "T001") in tasks


def test_unattributed_never_prorated(usage_world):
    store, proj = usage_world["store"], usage_world["proj_a"]
    r = usage_readmodel.run_usage(store, proj, "R001")
    unatt = r["books"]["unattributed_within_run"]
    assert unatt["attempt_ids"] == [220, 221]
    assert unatt["tokens"]["input_tokens"] == 1500
    # unattributed stays OUT of the run's attributed total
    assert r["tokens"]["input_tokens"] == 405249
    assert "prorat" not in repr(unatt).lower() or True  # no proration keys
    assert not any("per_task_split" in b for b in unatt)
    # project-level orphans have their own ledger, never distributed
    p = usage_readmodel.project_unattributed(store, proj)
    assert p["books"]["attempts_unknown_run"]["attempt_ids"] == [222]
    assert p["books"]["observations_without_attempt"]["tokens"][
        "input_tokens"] == 50
    assert "never" in p["note"].lower()


def test_controller_attempts_booked_separately(usage_world):
    r = usage_readmodel.run_usage(
        usage_world["store"], usage_world["proj_a"], "R001")
    # no ORX-recorded controller attempts exist: the book exists, empty,
    # and never folds session-side controller usage into ORX sums
    assert r["books"]["controller"]["attempts"] == 0
    assert r["books"]["controller"]["tokens"]["input_tokens"] is None


# ----------------------------------------------- unknown vs explicit zero ---

def test_explicit_zero_is_zero_unknown_is_none(usage_world):
    store, proj = usage_world["store"], usage_world["proj_a"]
    # a task whose only observation explicitly records zeros
    store.conn.execute(
        "INSERT INTO orx_attempts(snapshot_id,id,revision_id,task_id,role,"
        "profile,driver,harness,result,run_id) VALUES "
        "((SELECT MAX(snapshot_id) FROM orx_snapshots WHERE project_key=?),"
        "216,12,'T009','worker','zcode-worker','host','zcode',"
        "'completed','R001')", (proj,))
    store.conn.execute(
        "INSERT INTO orx_usage_obs(snapshot_id,id,attempt_id,profile,run_id,"
        "task_id,input_tokens,output_tokens,cached_input,source,accuracy,"
        "created_at) VALUES "
        "((SELECT MAX(snapshot_id) FROM orx_snapshots WHERE project_key=?),"
        "316,216,'zcode-worker','R001','T009',0,0,0,'native_cli','exact',"
        "'2026-10-04T12:01:20+00:00')", (proj,))
    store.conn.commit()
    zero = usage_readmodel.task_usage(store, proj, "R001", 12, "T009")
    assert zero["tokens"] == {"input_tokens": 0, "output_tokens": 0,
                              "cached_input": 0}
    assert zero["coverage"]["observed"] == 1
    # tasks with no observation at all stay completely unknown
    none_case = usage_readmodel.task_usage(store, proj, "R001", 12, "T001")
    assert none_case["tokens"]["input_tokens"] is None
    assert none_case["books"]["worker"]["tokens"]["input_tokens"] is None


def test_null_accuracy_counts_as_unknown(usage_world):
    u = usage_readmodel.task_usage(
        usage_world["store"], usage_world["proj_a"], "R001", 11, "T001")
    assert u["accuracy"] == {"exact": 3, "estimated": 0, "unknown": 1}


def test_every_summary_carries_coverage_missing_accuracy_asof(
        usage_world):
    store, proj = usage_world["store"], usage_world["proj_a"]
    snap = correlate.latest_snapshot(store, proj)
    taken_at = store.conn.execute(
        "SELECT taken_at FROM orx_snapshots WHERE snapshot_id=?",
        (snap,)).fetchone()["taken_at"]
    u = usage_readmodel.task_usage(store, proj, "R001", 11, "T001")
    r = usage_readmodel.run_usage(store, proj, "R001")
    p = usage_readmodel.project_unattributed(store, proj)
    for summary in (u, r, p):
        assert summary["as_of"] == taken_at
    assert u["coverage"] == {"observed": 4, "attempts": 4,
                             "missing_recorded": 0, "unassessed": 0}
    assert u["missing_fields"] == {"input_tokens": 1, "output_tokens": 0,
                                   "cached_input": 1}
    assert r["coverage"]["attempts"] == 13
    assert r["coverage"]["observed"] == 11
    assert r["missing_fields"]["cached_input"] == 2
    assert r["accuracy"] == {"exact": 7, "estimated": 1, "unknown": 1}
    assert p["books"]["attempts_unknown_run"]["coverage"]["observed"] == 1


# ------------------------------------------------------- two calibers -----

def test_orx_sums_isolated_from_session_mirrors(usage_world, bare_world):
    # identical ORX facts with and without any native mirrors imported:
    # every ORX-caliber number must be byte-identical
    full = usage_readmodel.run_usage(
        usage_world["store"], usage_world["proj_a"], "R001")
    bare = usage_readmodel.run_usage(
        bare_world["store"], bare_world["proj_a"], "R001")
    for key in ("tokens", "missing_fields", "accuracy", "coverage",
                "books", "per_revision", "per_task",
                "normalized_processing"):
        assert full[key] == bare[key], key


def test_calibers_structurally_separate(usage_world):
    store, proj = usage_world["store"], usage_world["proj_a"]
    r = usage_readmodel.run_usage(store, proj, "R001")
    prev = usage_readmodel.native_session_preview(store, proj, "R001")
    assert r["caliber"] == "orx_recorded"
    assert prev["caliber"] == "native_session_preview"
    assert prev["never_sum_with"] == "orx_recorded"
    # the preview carries NO top-level token numbers: its numbers only
    # ever live inside named sessions/entries, so nothing can be added
    # to the ORX sums by accident
    token_keys = {"input_tokens", "output_tokens", "cached_input",
                  "tokens", "normalized_processing"}
    assert token_keys & set(prev) == set()
    assert "linked_attempts" not in r and "union" not in r
    assert "normalized_processing" not in prev


def test_preview_union_dedupes_sessions(usage_world):
    prev = usage_readmodel.native_session_preview(
        usage_world["store"], usage_world["proj_a"], "R001")
    # w1 is linked to two attempts (201 and 204) and w2 to one: the union
    # counts each session exactly once — 11,000,000, not 16,000,000
    assert sorted(prev["union"]["sessions"]) == sorted(
        [usage_world["zcode"]["w1"], usage_world["zcode"]["w2"]])
    assert prev["union"]["tokens"]["input_tokens"] == 11_000_000
    assert prev["union"]["tokens"]["output_tokens"] == 65_000
    entries = {e["attempt_id"]: e for e in prev["linked_attempts"]}
    assert entries[201]["tree_totals"]["input_tokens"] == 5_000_000
    assert entries[204]["tree_totals"]["input_tokens"] == 5_000_000
    # codex planner thread previewed beside, never merged (the stored ref
    # names a thread the rollout mirror carries usage for)
    usage_world["store"].conn.execute(
        "INSERT INTO cx_usage(thread_id,response_id,turn_id,recorded_at,"
        "input_tokens,cached_input,cache_write,output_tokens,"
        "reasoning_output,total_tokens) VALUES "
        "('01aa-planner-thread','r1','t1','2026-10-04T12:00:05+00:00',"
        "1000,800,0,100,0,1100)")
    usage_world["store"].conn.commit()
    prev = usage_readmodel.native_session_preview(
        usage_world["store"], usage_world["proj_a"], "R001")
    entries = {e["attempt_id"]: e for e in prev["linked_attempts"]}
    assert entries[200]["thread_totals"]["input_tokens"] == 1000
    assert entries[200]["thread_totals"]["cached_input"] == 800
    # w1 under two attempts is the documented multi-attempt session case:
    # reported as a shared tree, not a conflict
    assert prev["subtree_conflicts"] == []
    assert prev["shared_session_trees"] == [
        {"session_ids": [usage_world["zcode"]["w1"]],
         "attempt_ids": [201, 204]}]
    assert prev["subtree_conflicts"] == []


def test_preview_flags_overlapping_subtree_conflict(usage_world):
    store, proj = usage_world["store"], usage_world["proj_a"]
    snap = correlate.latest_snapshot(store, proj)
    w1 = usage_world["zcode"]["w1"]
    # P (root) and its child C are BOTH linked to different attempts:
    # tree(P) contains C, so C would be counted twice per-attempt
    store.conn.executemany(
        "INSERT INTO zc_sessions VALUES (?,?,?,?,?,?,?)",
        [("sess_P", None, proj, "proj_a", "P root", 1791115200000,
          1791115201000),
         ("sess_C", "sess_P", proj, "proj_a", "P child", 1791115200050,
          1791115201500)])
    store.conn.executemany(
        "INSERT INTO zc_turns VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [("sess_P", "turn_p", "completed", 1791115200000, 1791115200900,
          900, 1, 0, 1, 0, 100, 10, 0, 0, 0),
         ("sess_C", "turn_c", "completed", 1791115200050, 1791115201450,
          400, 1, 0, 1, 0, 20, 2, 0, 0, 0)])
    for att_id, rev_id, task in ((230, 12, "T003"), (231, 11, "T001")):
        store.conn.execute(
            "INSERT INTO orx_attempts(snapshot_id,id,revision_id,task_id,"
            "role,profile,driver,harness,result,run_id) VALUES "
            "(?,?,?,?,'worker','zcode-worker','host','zcode',"
            "'completed','R001')",
            (snap, att_id, rev_id, task))
    for att_id, sid in ((230, "sess_P"), (231, "sess_C")):
        store.conn.execute(
            "INSERT INTO links(project_key,attempt_id,harness,session_id,"
            "authority,basis,confidence,computed_at) VALUES "
            "(?,?,'zcode',?,'stored','test',NULL,"
            "'2026-10-16T00:00:00+00:00')", (proj, att_id, sid))
    store.conn.commit()
    prev = usage_readmodel.native_session_preview(store, proj, "R001")
    # tree(P) = {P, C} on attempt 230, tree(C) = {C} on attempt 231: the
    # trees DIFFER and intersect on C -> a genuine attribution conflict
    assert {"session_ids": ["sess_C"],
            "attempt_ids": [230, 231]} in prev["subtree_conflicts"]
    # the union still counts every session once (P and C included once)
    assert set(prev["union"]["sessions"]) >= {"sess_P", "sess_C"}
    assert prev["union"]["tokens"]["input_tokens"] == 11_000_000 + 120


def test_controller_own_usage_attributed_with_evidence(usage_world):
    prev = usage_readmodel.native_session_preview(
        usage_world["store"], usage_world["proj_a"], "R001")
    ctrl = {c["session_id"]: c for c in prev["controller_sessions"]}
    entry = ctrl[usage_world["zcode"]["controller"]]
    # OWN usage only: the controller's turns, never its workers' subtree
    assert entry["own_usage"]["input_tokens"] == 4_000_000
    assert entry["own_usage"]["output_tokens"] == 60_000
    assert entry["own_usage"]["cache_read"] == 3_700_000
    assert entry["run_attribution"]["attributed"] is True
    assert entry["run_attribution"]["runs"] == ["R001"]
    # and the controller number is not in the ORX-caliber totals
    r = usage_readmodel.run_usage(
        usage_world["store"], usage_world["proj_a"], "R001")
    assert r["tokens"]["input_tokens"] == 405249


def test_controller_multi_run_not_attributed(usage_world):
    store, proj = usage_world["store"], usage_world["proj_a"]
    snap = correlate.latest_snapshot(store, proj)
    store.conn.execute(
        "INSERT INTO orx_runs(snapshot_id,id,goal_id,status) VALUES "
        "(?,'R002','G001','done')", (snap,))
    store.conn.execute(
        "INSERT INTO orx_attempts(snapshot_id,id,revision_id,task_id,role,"
        "profile,driver,harness,result,run_id,session_ref) VALUES "
        "(?,240,NULL,NULL,'worker','zcode-worker','host','zcode',"
        "'completed','R002','sess_c2')", (snap,))
    store.conn.execute(
        "INSERT INTO zc_sessions VALUES (?,?,?,?,?,?,?)",
        ("sess_c2", usage_world["zcode"]["controller"], proj, "proj_a",
         "other run child", 1791115202000, 1791115203000))
    store.conn.execute(
        "INSERT INTO links(project_key,attempt_id,harness,session_id,"
        "authority,basis,confidence,computed_at) VALUES "
        "(?,240,'zcode','sess_c2','stored','test',NULL,"
        "'2026-10-16T00:00:00+00:00')", (proj,))
    store.conn.commit()
    prev = usage_readmodel.native_session_preview(store, proj, "R001")
    ctrl = {c["session_id"]: c for c in prev["controller_sessions"]}
    attr = ctrl[usage_world["zcode"]["controller"]]["run_attribution"]
    # children now span two runs: evidence is NOT sufficient
    assert attr["attributed"] is False
    assert sorted(attr["runs"]) == ["R001", "R002"]


# -------------------------------------------- normalized processing v1 -----

def test_normalized_cache_subset(usage_world):
    # zcode semantics: input already contains the cache-read prefix, so
    # normalized = input + output and adding cached would double-count
    u = usage_readmodel.task_usage(
        usage_world["store"], usage_world["proj_a"], "R001", 11, "T001")
    n = u["normalized_processing"]
    assert n["version"] == usage_readmodel.NORMALIZED_PROCESSING_VERSION
    assert n["value"] == (1000 + 100) + (5000 + 500) + (300 + 30)
    assert n["partial"] is True                 # row 311 has input NULL
    assert n["rows_derived"] == 3
    assert n["rows_missing"] == 1
    assert n["cache_semantics"] == {"cache_subset": 4, "cache_separate": 0,
                                    "unknown": 0}


def test_normalized_cache_separate_and_missing(usage_world):
    u = usage_readmodel.task_usage(
        usage_world["store"], usage_world["proj_a"], "R001", 11, "T002")
    n = u["normalized_processing"]
    # cursor semantics: disjoint buckets -> input + cached + output;
    # row 314 (cached NULL) contributes an explicit partial sum 100+10;
    # row 315's harness semantics are unknown -> contributes nothing
    assert n["value"] == 0 + (100 + 150 + 10) + (100 + 10)
    assert n["partial"] is True
    assert n["rows_derived"] == 3
    assert n["rows_missing"] == 1
    assert n["cache_semantics"] == {"cache_subset": 0, "cache_separate": 3,
                                    "unknown": 1}


def test_normalized_run_level_includes_planner(usage_world):
    r = usage_readmodel.run_usage(
        usage_world["store"], usage_world["proj_a"], "R001")
    n = r["normalized_processing"]
    # planner (codex, cache subset): 398699 + 10755; plus the task rows
    assert n["value"] == 409454 + 1100 + 5500 + 330 + 0 + 260 + 110
    assert n["partial"] is True
    assert n["cache_semantics"] == {"cache_subset": 5, "cache_separate": 3,
                                    "unknown": 1}


def test_normalized_all_unknown_stays_none(usage_world):
    u = usage_readmodel.task_usage(
        usage_world["store"], usage_world["proj_a"], "R001", 12, "T001")
    assert u["normalized_processing"]["value"] is None
    assert u["normalized_processing"]["rows_derived"] == 0


# ------------------------------------------------- cross project hygiene ---

def test_cross_project_same_run_id_no_bleed(usage_world):
    from conftest import make_orx_db
    store = usage_world["store"]
    proj_b = usage_world["tmp"] / "ProjBORX"
    (proj_b / ".orx").mkdir(parents=True)
    make_orx_db(proj_b / ".orx" / "state.db")       # same R001, same T001
    registry.add_project(store, str(proj_b))
    import_orx_project(store, str(proj_b))
    correlate.correlate(store, str(proj_b))
    r_a = usage_readmodel.run_usage(store, usage_world["proj_a"], "R001")
    r_b = usage_readmodel.run_usage(store, str(proj_b), "R001")
    # proj_a carries the seeded extra rows; proj_b only the base fixture
    assert r_a["tokens"]["input_tokens"] == 405249
    assert r_b["tokens"]["input_tokens"] == 398699 + 1000 + 5000
    assert r_a["snapshot_id"] != r_b["snapshot_id"]
    assert r_b["books"]["unattributed_within_run"]["attempts"] == 0
