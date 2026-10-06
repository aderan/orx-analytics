# orx-analytics

跨项目、跨 coding agent 的只读执行观测：ORX（zcode/Codex/Cursor 派发）
与非 ORX 项目（zcode/Codex/Cursor 原生会话）的用量、耗时、交付质量、
数据覆盖、异常信号、证据交接与改进闭环。

设计不变量（docs/metrics.md、docs/correlation.md 为冻结契约）：

- 源库只读（`mode=ro` + `query_only`），永不迁移/检查点/改写；
- 未知保持未知：缺失不补零、不插值、不升级；部分覆盖发布分母；
- 关联只有权威（ORX 写入的 `session_ref`）与推断（带依据+置信度）两类；
- 无计费依据，不算费用；
- 发现只生成本地草案，不自动发布、不自动修复。

## 安装

```sh
cd ~/Sources/Tools/orx-analytics
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/orx-analytics --version
```

运行时零第三方依赖（标准库）。数据目录默认 `~/.orx-analytics/`，可用
`--data-dir` 或环境变量 `ORX_ANALYTICS_HOME` 覆盖。

## 首次使用

```sh
# 1) 探测本机数据源（诚实报告能力与缺口，不伪造）
orx-analytics probe --project /path/to/orx-project

# 2) 登记项目（绝对路径为身份；无 .orx 的项目自动按基础会话分析）
orx-analytics projects add /path/to/project
orx-analytics projects add /path/to/another --name Climbo

# 3) 采集一轮（全局源 + 各 ORX 项目快照；可重复，天然键幂等不重复计数）
orx-analytics collect

# 4) 看报告
orx-analytics report /path/to/orx-project --run R003      # 六读数+会话侧
orx-analytics session sess_xxxx                            # 原生会话报告
orx-analytics provenance                                   # 数据从哪来
```

## 日常持续运行

```sh
orx-analytics watch start --interval 600   # 后台守护：采集→关联→异常→发现
orx-analytics watch status                 # 轮次/最后错误/发现数
orx-analytics watch stop
orx-analytics watch once                   # 手动单轮（不驻留）
```

- 增量：zcode 按行号游标、Codex 按文件字节游标（断行安全：撕开的尾行
  下轮续读）、Cursor 按 composer 更新时间；ORX 每轮追加一个快照。
- 恢复：单轮失败记录在 `watch.state.json` 的 `last_error` 并继续；游标
  保证恢复后不漏算不重算（回归测试覆盖）。
- 有界开销：每轮只处理增量；异常规则只查当前快照与已导入行。

## 异常调查

```sh
orx-analytics findings list [--project /path]
orx-analytics findings draft <id>     # 结构化 issue 草案（本地）
orx-analytics findings dismiss <id> --note "..."
```

规则（可配置阈值，命中与不命中都有测试）：用量离群（同 role/profile
基线，样本不足不判定）、重复失败、短窗重规划、长无进展、覆盖缺口
（未评估用量/未关联会话）、同 attempt 检查轮超限、声明边上的疑似重复
交付（仅 rev1 已 passed 的声明 redo 触发，且提示需核对范围）。
每条发现带触发依据、比较基线、置信度、待补证据——是信号，不是结论。

## 交接（把疑点交给任意 agent）

```sh
orx-analytics bundle run /path/to/project --run R003 --dest mybundle \
  --title "..." --objective "..." \
  --fact "..." --hypothesis "..." --excluded "..." --next "..."
orx-analytics bundle session sess_xxxx --dest mysessbundle ...
```

包内容：`HANDOFF.md`（一页：目标/已确认事实/假设/反例/已排除/下一步）、
`OPERATOR.md`（继续调查指引）、`data/*.json`（结论所依赖的全部行）、
`recompute.py`（仅凭包内数据重算全部 headline，篡改即 MISMATCH）、
`integrity.json`（SHA-256 清单）、`bundle.json`（指标/定义/覆盖/provenance）。
接收方不需要本机任何路径。

## 故障处理

| 症状 | 处理 |
|---|---|
| `probe` 报 GAP | 按输出补齐（如 Cursor bubbleData 为空是本机事实，报告会标注） |
| collect 报 `schema gate refuses` | ORX 库版本不是 8/9；先升级 ORX 再采集，绝不代为迁移 |
| watch `last_error` 非 null | 读 `provenance` 看哪个源；单源失败不阻塞其他源 |
| 关联 `ambiguous` | 多个会话命中同一 attempt 标记；查看 links.evidence 候选，人工裁决 |
| 想重算历史 | 每轮 ORX 快照 append-only：`report` 永远用最新快照，旧快照数据仍在库中 |

## 仓库布局

```
src/orxanalytics/   probe/dbutil/store/registry/importers/correlate/
                    metrics/bundle/findings/anomalies/watch/collect/cli
docs/               metrics.md correlation.md source-probes.md（冻结契约与探测基线）
reports/            R003-report.md climbo-basic.md closed-loop-demo.md final-report.md
tests/              30 项回归（含接收方复算与篡改检测）
legacy 对应物        orx_analytics.py（起点脚本，保留为对照口径）
```

ORX 侧配套（G006，ORX 仓库 commit 852cd0a）：`orx task claim
--discover-session`、`orx task session-discover`、park 不再错盖控制器
会话、complete/fail 晚绑定 `--session`。真实端到端证据：R005
（attempt 101 ↔ `sess_subagent_agent_371a9db1…`，stored 权威关联）。
