# R006 六读数正式报告（G006/R006 host 进展报告）

- 采集时间：2026-10-06（gate 扩 {8,9,10,11} 后首次正式入库；此前 R006 库被
  契约 gate 正确拒读）
- 快照：snapshot_id 1，源 `.orx/state.db` schema v11（读时版本；R006 产生于
  v10，nonce 列为后向迁移的 NULL——按契约不回填）
- 复算口径：`orx-analytics report /Users/flb/Sources/Products/ORX --run R006`

## 六读数

| 读数 | 值 | 备注 |
|---|---|---|
| 交付质量 | 7 passed / 10 terminal（0.70） | rev1 T003/T004/T005 被 replan 取消（rev2 重编号重做）；非缺陷 |
| 消耗 | 12 attempts；仅 1 条有观测（codex planner a106：128,277 in / 6,531 out，exact） | 11 个 host attempt 无 usage 观测（unassessed，非缺失谎报）；host 侧消耗走会话口径 |
| 首过率 | 5/7 = 71.4% | 不过：rev2 T003（schema 适配）、T004（契约冻结后的分层重构）；同 attempt 修复回环内过，无跨 attempt 重试 |
| 完成时间 | 执行跨度合计 4,766s（11 个完整跨度）；等待 14,945s | spans_incomplete=1 即 a105 孤儿行（未 claim，无跨度——诚实保留 NULL，不合成） |
| 覆盖 | worker：8 attempts / 0 observed / 8 unassessed；会话关联 stored 0 / high 0 / ambiguous 2 / none 6 | 全部 11 个 host attempt session_ref 为 NULL——R006 的核心缺口（见复盘） |
| 返工 | failed transitions 0；14 条同 attempt 检查回环（最多 4 轮）；R006 两次修订内无跨 attempt 重试 | 跨修订重做 0 条声明边（rev1→rev2 的重做在 replan 表中，5 条 superseded 处置） |

## 会话侧

linked 3（a100/a101 为 R004/R005 遗留高置信；R006 内 a103/a104 降级为
ambiguous——见下）。union 口径因 zcode 侧 R006 无 high 关联而不合并，
按契约保留为空。

## R006 复盘实证（本报告的数据来源之一）

对 `.orx/state.db` + `~/.zcode/cli/db/db.sqlite` 的逐行核验：

1. **会话身份传递失败**：11 个 host attempt session_ref 全 NULL。根因比
   "controller 改写"更深——ORX 派发提示词从不嵌身份标记，"attempt N" 只是
   隐式约定；7 个 worker 子代理首提示 5 个零标记、2 个只含过期证据血缘
   （02:17 会话写 attempt 103，实为 a107）。
2. **关联误链风险已被本工具修复**：时间窗（±300s）+ 角色文本否决上线后，
   a103（双候选）与 a104（创建时间出窗）均降 ambiguous，R006 全量零 high
   误链。
3. **a105 孤儿行**：rev1 T003 的 parked attempt 在 02:16:37 superseded 后无
   result 无跨度。G007 起 replan 激活事务同步关闭（result='superseded'）；
   历史行不回写。
4. **a113 verifier 0 秒跨度**：started_at==ended_at（结构性：两端同刻打点），
   其会话实际 ~3 分钟 / 0.50M input。G007 起 verifier 派发即打 started_at。
5. **controller 停摆 2.48h**：03:16:52 GLM 414ms 快速失败（5 小时限额）至
   05:45，靠人恢复。no_progress 规则实际命中（8,857s 间隔）但 watch 未常开，
   事后才见。对策：watch 常开（已纳入 orx-controller 技能）。
6. **勘误**：复盘初稿"verifier 会话 11.87M input"归因错误——11.87M 属
   a112（T005 worker，全量测试套件的合法开销）；verifier 实际 0.50M。

## G007 修复（与 R006 缺口一一对应）

- ORX v11：attempts.nonce（orx-assignment:<uuid4>）+ 派发提示词首部
  ORX_ASSIGNMENT 身份头（worker/verifier 同构）；nonce 优先发现，legacy 行
  保留 marker 回退；verify submit --discover-session；replan 关闭孤儿
  attempt。观测契约第五修正案（gate {8,9,10,11}）。
- orx-analytics：gate 扩 {8,9,10}→{8,9,10,11}；修复 v10 静默丢 replan 表
  陷阱（=="9" → in (9,10)）；correlate 时间窗 ±300s + 角色否决 + nonce
  档（token 命中直接 high，无窗口/角色要求）；attempt_progress 镜像
  （R006 为 0 行——heartbeat 是 R006 交付的功能，R006 自身未使用）。
- 待 R007 实战验收：host attempt session_ref 绑定率、verifier 跨度 > 0、
  replan 后无孤儿行、nonce high 关联率。
