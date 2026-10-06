# 闭环演示 — 发现 → 调查 → issue 草案 → 修复关联 → 回归验证

录制于真实数据（真实分析库 `var/analytics.db`，finding #59）。演示对象是
本工具前任脚本的一个真实缺陷：**首过率把从未执行的任务计为一次通过**。

## 1 发现（异常/审查信号）

对 R003 跑两代口径，数字冲突：

- legacy（`orx_analytics.py --run R003`）：首过率 **22/22 = 100%**，
  消耗 attempts=10。
- 修正口径（`orxanalytics.metrics`）：**10/10 judged**，另有 **12 个任务
  从未到达验证**（在率之外）；消耗 attempts=**11**（planner 经
  `attempts.run_id` 归属，revision 为 NULL 不丢）。

## 2 调查（根因，两条均已确认）

- legacy `_first_pass_rate` 以 tasks 全表为分母、`worker_attempts<=1` 为
  判据 → 取消/未执行任务全部计入"一次通过"。
- legacy `_consumption` 经 `revision_id IN (...)` 归属 → planner attempt
  （revision NULL、仅 run_id 有值）被漏掉。

## 3 issue 草案（`orx-analytics findings draft 59`）

完整结构见 `reports/issue-draft-first-pass.json`：actual/expected/impact/
evidence（两代口径的并排数字）/confirmed_causes/minimal_fix_suggestion/
acceptance_criteria/regression_verification。默认本地草案，不发布。

## 4 修复关联（同口径前后对比）

- 修复：commit `b94b432`（corrected six readings：最早 verification 行 +
  无失败事件 + run_id 归属）。
- `findings.link_fix`：before = legacy 口径数字，after = 修正口径数字，
  **comparable=true**（同一快照、同一源库、同一任务集），verified_at
  已盖戳。
- 回归保护：`test_first_pass_rate_corrected`（含"legacy 会把 T002 计入"
  的反例断言）与 `test_planner_counted_via_run_id_not_revision`。

## 5 验证结论

同一 R003 数据上，修复后口径给出可解释的分母与显式的
`tasks_never_verified=12`；planner 消耗不再丢失。由于修复前后的两代口径
都作用在同一份源数据上，改善是被证明的（comparable=true），不是宣称。

（第二个确定性场景在测试里：`test_bundle_detects_tampering` 演示
证据完整性自检——篡改数据后 recompute 报 MISMATCH 并以非零退出。）
