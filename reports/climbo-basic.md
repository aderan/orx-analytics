# Climbo 基础会话分析（非 ORX 项目）

生成：2026-10-06，orx-analytics（同一分析库，未注册任何 ORX 数据——该
项目无 `.orx/state.db`，自动按基础会话分析）。展示未使用 ORX 的项目同样
可独立分析，且与 ORX 项目的同短编号（如各自的 T001/R001）互不串账。

## 覆盖

- zcode：78 个会话（20 个根会话，全部子会话都在本项目树内），树去重后
  input 1,348.47M / output 4.063M（含大量缓存重读）。
- Codex：8 个 rollout 线程（cwd=Climbo），如 `01a0a56e…`：input 49.28M
  （其中 cached 47.84M）、output 163,778、10 个有 usage 的 turn；部分线程
  无 usage 记录（如 `01a0a9fa-7d0b…`）——如实记为无观测，不推算。
- Cursor：15 个 composer（workspace 映射自 workspaceStorage folder URI）。

## 说明

- 非 ORX 项目没有 goal/run/revision/attempt 维度：报告止于会话级
  （树汇总、逻辑请求 vs 重试、工具活动、无进展间隔），见 docs/metrics.md
  "会话侧基础指标"。
- 与 ORX 项目并存在同一分析库中：所有查询按 project_key（绝对路径）过滤，
  Climbo 的 T001/R001 类短编号永远不会与 ORX 项目的同名实体合并
  （回归测试 test_cross_project_same_short_ids_do_not_bleed）。
