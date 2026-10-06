# 最终报告 — 跨项目、跨 coding agent 的持续执行观测与改进闭环

日期：2026-10-06。执行：ZCode 会话（GLM-5.3），Goal directive 同日。
本报告按 Goal 验收 1–13 逐条给出证据与剩余限制。

## 实现位置与使用入口

- **分析工具**：`~/Sources/Tools/orx-analytics`（本仓库，git 已初始化，
  6 个提交 `29f9190…0e21f79`）。入口 `orx-analytics`（venv 内
  `.venv/bin/orx-analytics`，运行时零第三方依赖）。子命令：`probe /
  projects / collect / report / session / provenance / bundle / findings /
  watch`。
- **ORX 侧配套**：ORX 仓库 commit `852cd0a`（G006 T001）：`orx task
  claim --discover-session`、`orx task session-discover <attempt>`（只读
  查询 zcode 库）、park 不再错盖控制器会话、`complete/fail --session`
  晚绑定、契约文档与 README 的 v7/v8 修正。627 项 ORX 测试全绿。
- **冻结契约**：本仓库 `docs/metrics.md`（指标口径）、
  `docs/correlation.md`（关联规则）、`docs/source-probes.md`（探测基线）。

## 验收对照

1. **三源验证读取路径**：zcode（sqlite 只读+WAL）、Codex（rollout
   JSONL 增量+断行安全）、Cursor（globalStorage composerHeaders+
   composerData）全部真实读取（`collect` 实跑：944 会话/117 codex 线程/
   208 composer）。Cursor 本机 bubbleData 为空→逐消息明细标注为缺口，
   不伪造。
2. **ORX + 非 ORX 项目独立分析**：ORX（`reports/R003-report.md`）与
   Climbo（`reports/climbo-basic.md`）各自独立；跨项目同短编号不串账
   （`test_cross_project_same_short_ids_do_not_bleed`）。
3. **新派发保存真实会话关联**：R005 真实端到端——zcode 子代理执行
   `claim --discover-session`，attempt 101 存入真实会话 id
   `sess_subagent_agent_371a9db1…`（父会话=控制器、首条 part 含
   attempt 101，均已独立复核）；分析侧显示 `stored:1`。历史关联缺失
   （R003 十个 worker NULL）与推断（inferred/high+依据）均可见。
4. **回归测试**：planner 归属（run_id）、首过率（最早行+未验证排除）、
   重复观测去重（双 native_cli / native+host_report）、未知用量保持、
   父子树聚合去重、同会话多 attempt 拆分（含窗口外 unattributed）——
   `tests/test_metrics.py` 12 项；累计 30 项测试全绿。
5. **只读与增量**：源库哈希前后不变的断言（`test_zcode_import_
   idempotent_and_readonly`、`test_discovery_never_writes_zcode_db`）；
   重复运行第二轮零新增；中断恢复（codex 撕裂尾行续读）有测试。
6. **可解释性**：每个指标有 docs/metrics.md 定义+分母+未知语义；报告附
   provenance（`orx-analytics provenance`）；异常发现带触发依据/基线/
   置信度/待补证据。
7. **R003 与指定会话的真实报告+交接包**：`reports/R003-report.md` +
   `var/bundles/r003`（6/6 MATCH）+ `var/bundles/sess64094b77`
   （2/2 MATCH）。**87.43M=87,427,489 已双重口径验证；83.42M 本机无
   原始工件、所有候选口径数值排除→差异保留未知**。
8. **rev1/rev3 T003 不并账**：R003 无 replan 声明边（早于 v9）→按契约
   "未知"；33.4M=浪费 与 12M 浪费的说法均被推翻（见 R003 报告）。
9. **异常规则命中/不命中测试**：`tests/test_anomalies.py`（7 规则各
   有正反断言）；发现按指纹去重合并（重复轮不新增行）。
10. **闭环演示**：`reports/closed-loop-demo.md`——legacy 首过率缺陷
    （22/22 vs 10/10+12 未验证）发现→调查→issue 草案
    （`reports/issue-draft-first-pass.json`）→修复关联（commit b94b432，
    **comparable=true**，同快照同源数据）→回归测试保护。真实数据录制。
11. **接收方仅凭交接包复核**：`recompute.py` 仅读包内 `data/`，全部
    headline MATCH；篡改检测测试证明包被改动即 MISMATCH。
12. **测试与文档**：30 项测试全绿；README 覆盖首次使用/日常运行/异常
    调查/交接/故障处理。
13. **本报告**即第 13 项。

## 剩余限制（未验证/未做，明确列出）

- **Cursor 逐消息用量**：本机 globalStorage bubbleData 为空，composer
  级 usageData 可用、消息级不可得——未完成现场验证的部分仅此。
- **83.42M 归因**：保留未知（原始报告工件不存在于本机）。
- **Codex planner thread `01a10710…`** 的 rollout 缺失：会话侧用量无法
  复核，仅 ORX 观测可用。
- **watch 未做 launchd/systemd 集成**：以本地守护进程（pidfile+状态
  文件）实现；开机自启属后续扩展。
- **ORX 历史 run 的 session_ref 回填**：不做（推断只在分析层，带依据）。
- **费用**：无计费依据，一律不计算。

## 后续扩展边界

- 薄的只读 MCP 入口（仅当确有跨机查询需求再加）；
- ORX Inbox 复用做发现的来源聚合（草案→来源搬运，不自动执行）；
- 更多异常规则（每条仍需命中/不命中测试与阈值配置）。
