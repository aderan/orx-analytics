# IMPLEMENTATION_PLAN — 跨项目、跨 coding agent 的持续执行观测与改进闭环

Goal directive: 2026-10-06. Owner session: ZCode (GLM). 起点事实已于执行前重新核实
（见 `docs/source-probes.md`）。完成后本文件按项目要求移除，内容并入最终报告。

仓库：本工具仓库（分析层）+ ORX 仓库（执行控制层的会话身份修复）。

## 已核实的起点事实（2026-10-06 复核）

1. R003 十个 worker attempt `session_ref` 全空（planner attempt 85 有 codex thread id）。
2. `sess_64094b77-…` 树 = 1 父 + 10 个 zcode 子会话；子会话首条 part 含
   "attempt 81…91" 字样、`directory` 均为 ORX 根目录。
3. 树汇总 input+output = 87,427,489（turn_usage 与 step-finish 两种口径逐位一致）≈ 87.43M。
   83.42M 在本机所有工件中仅出现于 Goal 文本自身；候选口径（仅子会话 78.96M、
   +父第一轮 80.33M、+planner 87.84M、仅 input 87.00M、cache+output 85.94M）全部
   数值排除 → 归因保留未知。
4. 现有脚本缺陷确认：首过率按 attempt≤1 计；消耗经 revision_id 归属漏 planner；
   README v7/v8 表述不一致（契约 gate 实收 {8,9}）。
5. 数据源：zcode sqlite（WAL）、Codex rollout JSONL（token_usage_record）、
   Cursor globalStorage state.vscdb（composerHeaders/composerData.usageData）。

## Phase 1 — 探测固化 + 契约冻结 + 骨架（本仓库）
- [x] git init，原脚本保存为 legacy 基线提交
- [x] 包骨架（src/orxanalytics，仅标准库运行时依赖）
- [x] `docs/metrics.md` 指标口径冻结；`docs/correlation.md` 关联规则冻结
- [x] `docs/source-probes.md` 数据源探测结果（含能力矩阵与缺口）
- [x] probe 命令 + 测试

## Phase 2 — 采集、关联、指标修正
- [ ] 2a registry/own-store/增量幂等导入（游标 + 天然键 upsert）
- [ ] 2b 四源适配器（zcode/codex/cursor/orx）+ WAL 只读快照与来源记录
- [ ] 2c 关联引擎：attempt↔session（basis+confidence；历史 R003 规则）
- [ ] 2d 指标修正（六读数 + planner 归属 + 首过率 + 覆盖率）+ 回归测试
- [ ] 2e ORX 侧（ORX 仓库, G005）：`orx session discover`、park 时段不再错盖
      controller 会话、claim/complete/fail 晚绑定 --session、协议与契约文档、
      README v7/v8 修正
- 验收对应：Goal 验收 1/2/3/4/5 的实现面

## Phase 3 — 证据包与跨 agent 交接
- [ ] bundle 导出（HANDOFF 一页纸 + 指标/定义/覆盖 + 原文片段 + 可复算 SQL +
      完整性清单 + 继续调查说明）
- [ ] 接收方仅凭 bundle 复算头部数字的测试
- 验收对应：Goal 验收 7(部分)/11

## Phase 4 — 持续运行、异常规则、发现管理
- [ ] watch 守护（start/stop/status、故障恢复、轮内开销有界）
- [ ] 异常规则（命中+不命中测试；输出触发依据/基线/置信度/待补证据）
- [ ] 发现去重合并、issue 草案、修复关联与同口径前后比较
- 验收对应：Goal 验收 9/10

## Phase 5 — 真实案例与闭环验收
- [ ] R003 真实报告 + 83.42M/87.43M 调查 + rev1/rev3 T003 不并账
- [ ] Climbo（非 ORX）基础报告；跨项目同短编号不串联
- [ ] ORX 微型真实 run：host worker claim --session（真 zcode 子会话）
- [ ] 闭环演示：首过率缺陷 发现→调查→草案→修复→前后对比
- [ ] README 使用文档（首次/日常/调查/交接/故障）+ 最终报告；移除本文件

## 边界
只读源库；不伪造缺失；无计费依据不算钱；发现不自动发布；默认验收不调用付费模型。
