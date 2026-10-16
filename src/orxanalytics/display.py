"""Display-layer contract: status mapping, identity keys, data health.

docs/menubar-app-design.md §2/§4 frozen rules:

- Execution status maps from ORX facts; the raw value is always preserved
  and an unrecognized value displays 未知状态 — never guessed into a
  terminal state.
- Identity keys are composite. A short number (T001/R001) is never a
  global key: Run = Project + run_id, Task = Project + Run + Revision +
  task_id, Attempt = Project + the source database's attempt row id.
- Data health (正常/更新延迟/来源不可读/版本不支持) is a third dimension,
  separate from execution status and attention by construction.
"""

from __future__ import annotations

from pathlib import Path

UNKNOWN_LABEL = "未知状态"

RUN_DISPLAY: dict[str, str] = {
    "planning": "规划中",
    "running": "执行中",
    "blocked": "暂停",
    "done": "完成",
}

TASK_DISPLAY: dict[str, str] = {
    "pending": "等待前置",
    "runnable": "待执行",
    "running": "执行中",
    "waiting_host": "等待宿主",
    "waiting_external": "等待外部",
    "verifying": "等待验证",
    "passed": "完成",
    "failed": "失败",
    "blocked": "受阻",
    "cancelled": "已取消",
}

GOAL_DISPLAY: dict[str, str] = {
    "active": "进行中",
    "done": "已完成",
    "cancelled": "已取消",
}

_TERMINAL_DISPLAY = {"完成", "失败", "已取消"}

HEALTH_OK = "正常"
HEALTH_DELAYED = "更新延迟"
HEALTH_UNREADABLE = "来源不可读"
HEALTH_UNSUPPORTED = "版本不支持"
HEALTH_UNKNOWN = "未知"


def _status(raw, table: dict[str, str]) -> dict:
    known = raw in table
    return {
        "raw": raw,
        "known": known,
        "display": table[raw] if known else UNKNOWN_LABEL,
    }


def run_status(raw: str | None) -> dict:
    return _status(raw, RUN_DISPLAY)


def task_status(raw: str | None) -> dict:
    return _status(raw, TASK_DISPLAY)


def goal_status(raw: str | None) -> dict:
    return _status(raw, GOAL_DISPLAY)


def is_terminal(status: dict) -> bool:
    """True only for a KNOWN terminal display (完成/失败/已取消). An
    unknown value is never terminal — it is not a verdict."""
    return status["known"] and status["display"] in _TERMINAL_DISPLAY


def project_key(root: str | Path) -> str:
    """Canonical project identity: resolved absolute path, the exact
    transformation registry.add_project uses."""
    return str(Path(root).expanduser().resolve())


def run_identity(project: str, run_id: str) -> tuple[str, str]:
    """Compose identity keys from an already-canonical project key (see
    project_key). Pure composition — resolution is the caller's one job."""
    return (project, run_id)


def task_identity(project: str, run_id: str, revision_id: int,
                  task_id: str) -> tuple[str, int, int, str]:
    return (project, run_id, revision_id, task_id)


def attempt_identity(project: str, attempt_row_id: int) -> tuple[str, int]:
    return (project, attempt_row_id)


def data_health(source_readable: bool | None, schema_supported: bool | None,
                stale: bool | None) -> dict:
    """Classify data health from three facts. None means the fact is
    unknown — health then reports 未知, never a guessed 正常.
    Precedence: unreadable > unsupported > delayed > ok."""
    if source_readable is False:
        health = HEALTH_UNREADABLE
    elif schema_supported is False:
        health = HEALTH_UNSUPPORTED
    elif stale is True:
        health = HEALTH_DELAYED
    elif source_readable is None or schema_supported is None or stale is None:
        health = HEALTH_UNKNOWN
    else:
        health = HEALTH_OK
    return {
        "health": health,
        "source_readable": source_readable,
        "schema_supported": schema_supported,
        "stale": stale,
    }
