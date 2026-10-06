"""Command line entry. Subcommands grow per phase; `probe` is phase 1."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import __version__, probe


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="orx-analytics",
        description="Read-only execution observability across projects and agents",
    )
    ap.add_argument("--version", action="version", version=__version__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("probe", help="probe local sources; report capabilities "
                                     "and gaps honestly")
    p.add_argument("--project", action="append", default=[],
                   help="ORX project root to probe (repeatable)")
    p.add_argument("--json", action="store_true", help="JSON output")

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
    return 2


if __name__ == "__main__":
    sys.exit(main())
