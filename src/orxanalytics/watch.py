"""Continuous collection: a small local loop, not a service platform.

`watch start` spawns one detached process that repeats the same bounded
round — collect (incremental cursors), correlate, anomaly rules, finding
upserts — and sleeps. State lives in <data_dir>/watch.state.json; a
pidfile guards against double starts; a dead pid is reclaimed. Failures
are recorded and the loop continues: one bad round never stops the watch,
and the next round resumes from the cursors (idempotent imports mean no
double counting on recovery).

Newly inserted findings raise one mac notification (confidence "low"
rows stay silent; ORX_ANALYTICS_NOTIFY=0 disables) — the loop has no
terminal, so without it a stall finding sits unread until someone looks.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from .store import Store, now_iso

DEFAULT_INTERVAL_SEC = 600


def _state_path(data_dir: Path) -> Path:
    return data_dir / "watch.state.json"


def _pid_path(data_dir: Path) -> Path:
    return data_dir / "watch.pid"


def _read_state(data_dir: Path) -> dict[str, Any] | None:
    p = _state_path(data_dir)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError:
        return {"corrupt": True}


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _write_state(data_dir: Path, state: dict[str, Any]) -> None:
    p = _state_path(data_dir)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1) + "\n")
    tmp.replace(p)


def start(data_dir: Path, interval: int = DEFAULT_INTERVAL_SEC) -> dict:
    if data_dir.exists() is False:
        data_dir.mkdir(parents=True, exist_ok=True)
    pidfile = _pid_path(data_dir)
    if pidfile.exists():
        try:
            old = int(pidfile.read_text().strip())
        except ValueError:
            old = 0
        if old and _pid_alive(old):
            return {"started": False, "reason": f"already running (pid {old})",
                    "state": _read_state(data_dir)}
    # detach: the loop child must survive this process
    cmd = [sys.executable, "-m", "orxanalytics.watch", "_loop",
           "--data-dir", str(data_dir), "--interval", str(interval)]
    proc = subprocess.Popen(
        cmd, start_new_session=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        if pidfile.exists():
            break
        time.sleep(0.1)
    return {"started": True, "pid": proc.pid,
            "interval_sec": interval,
            "state": _read_state(data_dir)}


def stop(data_dir: Path) -> dict:
    pidfile = _pid_path(data_dir)
    if not pidfile.exists():
        return {"stopped": False, "reason": "not running"}
    pid = int(pidfile.read_text().strip())
    if not _pid_alive(pid):
        pidfile.unlink(missing_ok=True)
        return {"stopped": False, "reason": f"pid {pid} was already dead "
                "(stale pidfile removed)"}
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        if not _pid_alive(pid):
            break
        time.sleep(0.1)
    pidfile.unlink(missing_ok=True)
    return {"stopped": True, "pid": pid,
            "state": _read_state(data_dir)}


def status(data_dir: Path) -> dict:
    state = _read_state(data_dir) or {}
    pidfile = _pid_path(data_dir)
    pid = None
    running = False
    if pidfile.exists():
        try:
            pid = int(pidfile.read_text().strip())
            running = _pid_alive(pid)
        except ValueError:
            pass
    return {"running": running, "pid": pid, **state}


def _notify(rows: list[dict]) -> int:
    """One mac notification for newly inserted findings.

    The loop runs detached with no terminal, so a finding that is only
    recorded changes nothing until someone thinks to look (To2050
    2026-10-06: a stall finding would have sat unread for hours). Rows
    whose payload self-describes as confidence "low" (no_progress:
    gap may be think-time) stay silent; the rest notify once —
    fingerprint dedupe upstream keeps rounds from repeating themselves.
    Best-effort: any failure returns 0 and the round continues.
    Kill switch: ORX_ANALYTICS_NOTIFY=0.
    """
    if os.environ.get("ORX_ANALYTICS_NOTIFY") == "0" or not rows:
        return 0
    notable: list[dict] = []
    for row in rows:
        try:
            conf = json.loads(row["payload_json"]).get("confidence")
        except (json.JSONDecodeError, TypeError, KeyError):
            conf = None
        if conf != "low":
            notable.append(row)
    if not notable:
        return 0
    lines = [f'{r["rule"]}: {r["title"]}' for r in notable[:5]]
    if len(notable) > 5:
        lines.append(f'… +{len(notable) - 5} more')
    msg = "\n".join(lines)[:400].replace('"', "'")
    try:
        subprocess.run(
            ["osascript", "-e",
             f'display notification "{msg}" with title '
             f'"orx-analytics watch" subtitle '
             f'"{len(notable)} new finding(s)"'],
            timeout=10, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, check=False)
    except (OSError, subprocess.SubprocessError):
        return 0
    return len(notable)


def run_one_round(data_dir: Path, interval: int,
                  once: bool = False) -> None:
    """The loop body. Each round is bounded: incremental imports + rule
    evaluation only; nothing sends history anywhere."""
    from . import anomalies, correlate, findings
    from .collect import collect
    from .registry import list_projects

    state = _read_state(data_dir) or {
        "started_at": now_iso(), "rounds": 0, "last_round_at": None,
        "last_error": None, "findings_upserted": 0}
    _pid_path(data_dir).write_text(str(os.getpid()))
    try:
        while True:
            round_started = now_iso()
            error: str | None = None
            new_findings: list[dict] = []
            try:
                store = Store(data_dir)
                try:
                    res = collect(store)
                    errors = [r for r in res["global"] + res["orx"]
                              if "error" in r]
                    if errors:
                        error = json.dumps(errors, ensure_ascii=False)[:400]
                    keys = [p["project_key"] for p in list_projects(store)
                            if p["orx_enabled"]]
                    for pk in keys:
                        correlate.correlate(store, pk)
                    results = anomalies.run_all(store, keys)
                    for r in results:
                        row = findings.upsert_finding(store, **r.upsert_args())
                        if not row.get("merged"):
                            new_findings.append(row)
                    state["findings_upserted"] = \
                        len(findings.list_findings(store))
                finally:
                    store.close()
            except Exception as e:  # noqa: BLE001 - loop must survive
                error = f"{type(e).__name__}: {e}"
            notified = _notify(new_findings)
            state["rounds"] = state.get("rounds", 0) + 1
            state["last_round_at"] = round_started
            state["last_error"] = error
            state["notified_last_round"] = notified
            state["pid"] = os.getpid()
            _write_state(data_dir, state)
            if once:
                return
            time.sleep(interval)
    finally:
        _pid_path(data_dir).unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    import argparse
    ap = argparse.ArgumentParser(prog="orx-analytics-watch")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("start", "stop", "status", "_loop", "once"):
        p = sub.add_parser(name)
        p.add_argument("--data-dir", default=None)
        p.add_argument("--interval", type=int,
                       default=DEFAULT_INTERVAL_SEC)
    args = ap.parse_args(argv)
    data_dir = Path(args.data_dir) if args.data_dir else None
    if args.cmd in ("start",):
        out = start(data_dir or Store().data_dir, args.interval)
    elif args.cmd == "stop":
        out = stop(data_dir or Store().data_dir)
    elif args.cmd == "status":
        out = status(data_dir or Store().data_dir)
    elif args.cmd == "once":
        run_one_round(data_dir or Store().data_dir, args.interval,
                      once=True)
        out = {"round": "done", "state": _read_state(
            data_dir or Store().data_dir)}
    else:
        run_one_round(data_dir or Store().data_dir, args.interval)
        out = {}
    if out:
        print(json.dumps(out, indent=1, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
