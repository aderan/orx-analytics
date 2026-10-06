"""Anomaly rules: hit AND no-hit, with baseline/confidence requirements."""

from __future__ import annotations

import json

from orxanalytics import anomalies, correlate, findings, registry
from orxanalytics.importers import import_zcode
from orxanalytics.importers.orxstate import import_orx_project


def _loaded(world):
    import_zcode(world["store"], world["zcode_db"])
    registry.add_project(world["store"], world["proj_a"])
    import_orx_project(world["store"], world["proj_a"])
    correlate.correlate(world["store"], world["proj_a"])
    return world["store"]


def test_rules_hit_and_miss(world):
    store = _loaded(world)
    pk = world["proj_a"]
    # duplicate_delivery: fixture declares rev1 T003 -> rev2 T003 redo
    hits = anomalies.duplicate_delivery(store, pk, {})
    assert len(hits) == 1
    assert hits[0].payload["evidence"]["redo_reason"] == "scope widened"
    assert hits[0].payload["missing_evidence"]  # must say what's missing

    # repeat_failures: rev1 T001 failed once -> below threshold of 2
    misses = anomalies.repeat_failures(store, pk, {"min_failed_events": 2})
    assert misses == []
    hits = anomalies.repeat_failures(store, pk, {"min_failed_events": 1})
    assert len(hits) == 1 and "T001" in hits[0].title

    # replan_burst: single replan -> no burst at >=2
    assert anomalies.replan_burst(store, pk, {"min_replans": 2}) == []
    assert len(anomalies.replan_burst(store, pk, {"min_replans": 1})) == 1

    # check_loop_overflow: fixture rows are all 1 per command -> no hit
    assert anomalies.check_loop_overflow(store, pk, {"budget": 3}) == []

    # coverage_gap: workers=4, unassessed=1 (204), unlinked host workers=1
    # (201 has inferred-high link, 204/202 linked, 203 is cli) -> no hit at
    # 0.5 threshold
    assert anomalies.coverage_gap(store, pk, {}) == []
    hits = anomalies.coverage_gap(
        store, pk, {"min_unassessed_frac": 0.2, "min_attempts": 3})
    assert any(h.detail_key == "unassessed" for h in hits)

    # usage_outlier: 3 canonical observations < min_samples 5 -> no claim
    assert anomalies.usage_outlier(store, pk, {"min_samples": 5}) == []

    # no_progress: fixture turn gaps are ~35-100s -> no hit at 3600
    assert anomalies.no_progress(store, {"min_gap_sec": 3600}) == []
    hits = anomalies.no_progress(store, {"min_gap_sec": 30})
    assert hits and hits[0].payload["confidence"] == "low"


def test_findings_dedupe_and_merge(world):
    store = _loaded(world)
    res = anomalies.run_all(store, [world["proj_a"]])
    assert res
    ids = set()
    for r in res:
        row = findings.upsert_finding(store, **r.upsert_args())
        ids.add(row["id"])
    n1 = len(findings.list_findings(store))
    # the same round again: fingerprints match, nothing new is created
    for r in anomalies.run_all(store, [world["proj_a"]]):
        row = findings.upsert_finding(store, **r.upsert_args())
        assert row["merged"] is True or row["id"] in ids
    assert len(findings.list_findings(store)) == n1


def test_issue_draft_structure_and_fix_link(world):
    store = _loaded(world)
    res = anomalies.run_all(store, [world["proj_a"]])
    row = findings.upsert_finding(store, **res[0].upsert_args())
    draft = findings.draft_issue(store, row["id"])
    for key in ("actual_behavior", "expected_behavior", "impact",
                "evidence", "hypotheses_to_verify",
                "minimal_fix_suggestion", "acceptance_criteria",
                "regression_verification", "missing_evidence",
                "linked_refs"):
        assert key in draft
    # a fix link without a comparable after-sample says unproven
    out = findings.link_fix(store, row["id"], "commit-abc",
                            before={"first_pass": 0.5}, after=None)
    assert out["comparable"] is False and out["verified_at"] is None
    draft = findings.draft_issue(store, row["id"])
    assert draft["linked_fixes"][0]["comparable"] == 0
    out = findings.link_fix(store, row["id"], "commit-abc",
                            before={"first_pass": 0.5},
                            after={"first_pass": 1.0})
    assert out["comparable"] is True


def test_watch_round_once_and_state(world, tmp_path):
    from orxanalytics import watch
    home = tmp_path / "watchhome"
    home.mkdir()
    # seed: a project registered in this data dir, sources pointed at the
    # fixture via env is complex; here we only exercise the loop with the
    # fixture store's data dir already containing data
    watch.run_one_round(world["store"].data_dir, 1, once=True)
    st = watch.status(world["store"].data_dir)
    assert st["rounds"] >= 1
    assert st["last_round_at"]
    # errors from unreachable global sources are recorded, not fatal
    if st["last_error"]:
        assert isinstance(st["last_error"], str)
    assert not (world["store"].data_dir / "watch.pid").exists()
