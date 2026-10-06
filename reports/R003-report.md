# R003 真实报告 — G003 交付协议 run（2026-10-04）

生成：2026-10-06，orx-analytics（快照 5，源 `.orx/state.db` schema v9 +
zcode/codex 只读导入）。所有数字可由 `orx-analytics report` 与
`var/bundles/r003/recompute.py` 复算。

## Run 概况

- Goal G003（交付协议改进），Run R003：`running` 2026-10-04T12:28:34Z →
  `done` 14:43:25Z，**等待 8090s**；11 个 attempt 执行跨度合计 8148s
  （重叠未合并——两口径分开，见 docs/metrics.md）。
- 3 个计划修订：rev1（8 任务，superseded）、rev2（codex-frontier 产物，
  全 8 任务 cancelled）、rev3（6 任务，active，全部 passed）。
  跨修订交付质量：10 passed / 22 terminal（rev2 是被否决的计划，其取消
  不是交付失败）。
- 失败转换：0（rev1→rev3 的任务切换以 replan 取消完成，不是 fail 事件）。

## 首次交付通过率（修正口径）

- **分母 10 / 分子 10**（每个到达验证的任务，最早 verification 行绿且
  无失败事件）。**12 个任务从未到达验证**（rev1 T004-T008、rev2 全部），
  在率之外单独计数——不算失败也不算通过。
- 对照：legacy 脚本同一 Run 报 **22/22=100%**（把从未执行的任务按
  `worker_attempts<=1` 计为一次通过）——该缺陷即闭环演示案例
  （见 closed-loop-demo.md）。

## 消耗（两口径并排，不合并）

| 口径 | 范围 | input | output | 说明 |
|---|---|---|---|---|
| ORX 观测 | 11 attempts（含 planner） | 398,699 | 10,755 | 仅 planner（codex native_cli, exact）有观测；10 个 worker 无观测、无 missing reason → unassessed，sum 标 partial |
| zcode 会话侧 | 10 个 worker 子会话（各自树） | 78,598,269 | 362,085 | inferred/high 关联（见下）；每会话即整树 |
| zcode 会话侧 | 控制器树（1+10） | 87,000,672 | 426,817 | `sess_64094b77` 树合计，即 87.43M |
| codex 会话侧 | planner thread `01a10710-d575…` | 未知 | 未知 | rollout 文件本机不存在，无法复核；ORX 观测是唯一数字 |

planner 通过 `attempts.run_id` 归属（revision 为 NULL）——legacy 的
`revision_id IN (...)` 口径会漏掉它（attempts=10 vs 11）。

## 会话关联（历史推断，全部带依据）

10 个 worker attempt ↔ 10 个 zcode 子会话，全部 **inferred / high**：
子会话首条 text part 含 `attempt 81…91` 唯一标记 + `directory` == 项目根 +
有父会话（控制器 `sess_64094b77`）。R003 早于 claim 时绑定（G006），
`session_ref` 全空是那个年代的诚实状态。逐 attempt：

| attempt | 任务 | in+out |
|---|---|---|
| 81 | rev1 T001 | 6.776M |
| 82 | rev1 T007 | 5.736M |
| 83 | rev1 T002 | 7.007M |
| 84 | rev1 T003 | 11.985M |
| 86 | rev3 T001 | 1.434M |
| 87 | rev3 T002 | 0.770M |
| 88 | rev3 T003 | 21.464M |
| 89 | rev3 T005 | 9.136M |
| 90 | rev3 T004 | 5.352M |
| 91 | rev3 T006 | 9.301M |

## 83.42M vs 87.43M 差异调查

**已验证**：87.43M = 控制器树 `turn_usage` input+output = **87,427,489**；
`part.step-finish` 逐步累计同为 87,427,489（两独立口径逐位一致）。其中
cache_read 85,507,200（85.5M 是缓存重读）。

**归因尝试（全部数值排除）**：仅子会话 78.96M；子会话+父第一轮 80.33M；
树+planner 观测 87.84M；仅 input 87.00M；cache_read+output 85.94M——
没有一种自然口径等于 83.42M。

**出处检索**：83.42M 在本机全部工件（ORX 仓库、docs、evidence、zcode
消息库）中仅出现在本 Goal 文本自身的引用里；产生该数的原始报告不存在。

**结论**：87.43M 可复算、已双重验证；**83.42M 出处未知，差异保留未知**。
唯一未被排除的假设是"部分树的时点读取或算术错误"，无可验证证据。

## rev1/rev3 T003：同编号不是同一工作

- R003 **无 replan 声明边**（早于 G004/v9 契约）：rev1 T003 与 rev3 T003
  的对应关系在库中**未声明**——按契约即"未知"，不得用编号相似度判定
  重复或浪费。
- 人工上下文（Goal 声明，非库内证据）：rev1 T003 实现交付门禁；rev3 T003
  保留验证历史并修复测试契约；rev3 T001 明确要求**验证 rev1 已交付的门禁
  仍然成立**——即 rev3 的工作包含对 rev1 成果的回归确认，不是重做。
- 因此 `rev1 T003(11.985M) + rev3 T003(21.464M) = 33.4M 是浪费`的说法
  **不成立**；"12M 浪费"更是无中生有（此前复盘已推翻，此处给出可复算
  的数字依据）。

## 交接包

- `var/bundles/r003/`：run 证据包（HANDOFF/数据/复算/完整性清单），
  接收方复算 6/6 MATCH。
- `var/bundles/sess64094b77/`：会话树证据包（87.43M 的独立核算材料），
  接收方复算 2/2 MATCH。
