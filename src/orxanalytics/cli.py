"""Command line entry: probe / projects / collect / report / session."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import __version__, metrics, probe
from .store import Store, DEFAULT_DATA_DIR


def _store(args) -> Store:
    return Store(Path(args.data_dir) if args.data_dir else None)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="orx-analytics",
        description="Read-only execution observability across projects "
                    "and agents")
    ap.add_argument("--version", action="version", version=__version__)
    ap.add_argument("--data-dir", default=None,
                    help=f"analytics home (default {DEFAULT_DATA_DIR}); "
                         f"env ORX_ANALYTICS_HOME overrides")
    if os.environ.get("ORX_ANALYTICS_HOME"):
        ap.set_defaults(data_dir=os.environ["ORX_ANALYTICS_HOME"])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("probe", help="probe local sources honestly")
    p.add_argument("--project", action="append", default=[])
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("projects", help="manage the project registry")
    p.add_argument("action", choices=["add", "remove", "list"])
    p.add_argument("root", nargs="?")
    p.add_argument("--name")

    p = sub.add_parser("collect", help="one incremental read-only pass")
    p.add_argument("--project", action="append", default=[],
                   help="restrict ORX snapshots to these projects")
    p.add_argument("--skip-global", action="store_true")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("report", help="six-reading run report (ORX project)")
    p.add_argument("project")
    p.add_argument("--run")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("session", help="native zcode session report")
    p.add_argument("session_id")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("provenance", help="import provenance summary")

    args = ap.parse_args(argv)

    if args.cmd == "probe":
        result = probe.probe_all([Path(x) for x in args.project])
        if args.json:
            print(json.dumps(result, indent=1, ensure_ascii=False))
        else:
            for r in result["results"] + result["orx_projects"]:
                mark = "ok  " if r["ok"] else "GAP "
                print(f"[{mark}] {r['kind']}: {r['detail']}")
                for g in r["gaps"]:
                    print(f"        gap: {g}")
        return 0

    if args.cmd == "projects":
        from . import registry
        store = _store(args)
        try:
            if args.action == "add":
                if not args.root:
                    ap.error("projects add needs a root path")
                row = registry.add_project(store, args.root, args.name)
                print(f"registered {row['project_key']} "
                      f"(orx={row['orx_enabled']}) {row['note']}")
            elif args.action == "remove":
                if not args.root:
                    ap.error("projects remove needs a root path or key")
                print("removed" if registry.remove_project(store, args.root)
                      else "not found")
            else:
                for r in registry.list_projects(store):
                    print(f"{r['project_key']}\t{r['name']}\t"
                          f"orx={r['orx_enabled']}")
        finally:
            store.close()
        return 0

    if args.cmd == "collect":
        from .collect import collect
        store = _store(args)
        try:
            res = collect(store, args.project or None,
                          skip_global=args.skip_global)
        finally:
            store.close()
        if args.json:
            print(json.dumps(res, indent=1, ensure_ascii=False,
                             default=str))
        else:
            for r in res["global"]:
                if "error" in r:
                    print(f"[ERR ] {r['source']}: {r['error']}")
                else:
                    c = r["counts"]
                    print(f"[ok  ] {r['source']}: {c}")
            for r in res["orx"]:
                if "error" in r:
                    print(f"[ERR ] orx {r['project']}: {r['error']}")
                else:
                    print(f"[ok  ] orx {r['project']}: snapshot "
                          f"{r['snapshot_id']} "
                          f"({r['counts'].get('orx_attempts', '?')} attempts)")
        return 0 if all("error" not in r for r in res["global"]) and \
            all("error" not in r for r in res["orx"]) else 1

    if args.cmd == "report":
        store = _store(args)
        try:
            key = str(Path(args.project).expanduser().resolve())
            rep = metrics.run_report(store, key, args.run)
        finally:
            store.close()
        print(json.dumps(rep, indent=1, ensure_ascii=False, default=str))
        return 0

    if args.cmd == "session":
        store = _store(args)
        try:
            rep = metrics.session_report(store, args.session_id)
        finally:
            store.close()
        print(json.dumps(rep, indent=1, ensure_ascii=False, default=str))
        return 0

    if args.cmd == "provenance":
        from .collect import provenance
        store = _store(args)
        try:
            rows = provenance(store)
        finally:
            store.close()
        for r in rows:
            err = f" ERROR={r['last_error']}" if r["last_error"] else ""
            print(f"{r['source_id']}\tlast={r['last_import_at']}{err}\t"
                  f"{json.dumps(r['counts'], ensure_ascii=False)}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
