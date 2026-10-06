# 关联规则（冻结）

状态：Phase 1 冻结。ORX attempt 与原生工具会话的关联只有两类：

## 权威（authoritative）

ORX 自己写入的 `attempts.session_ref`（host 路径在 claim/complete/fail 时由
worker 传递；CLI 路径由适配器从工具输出捕获）。这是唯一可写成事实的关联。
读取时原样取出，不解析、不归一。

## 推断（inferred）

历史回填或补全用，必须逐条记录依据与置信度，绝不写成确定关系。可用证据
从强到弱：

| 置信度 | 依据（全部满足才给该级） |
|---|---|
| high | 子会话首条用户 part 含该 attempt 的唯一标记（如 "attempt 88"）且 `session.directory` == 项目根 且父会话链在项目内（controller→subagent 结构成立）且**会话创建时间落在 attempt 跨度 ± 300s 松弛内**且提示词角色声明与 attempt 角色一致（修订 2026-10-06，见下） |
| medium | `session.directory` == 项目根 且会话时间窗覆盖 attempt 跨度（±松弛）且角色/标题语义与 attempt 一致，但无 attempt 唯一标记 |
| low | 仅时间邻近或仅标题相似——**默认不落库**，仅供人工线索输出 |

规则：
- 标题、时间邻近、短编号本身永远不构成确定关系；`(run, revision, task)`
  身份必须全链携带。
- 同一会话匹配多个 attempt（或反之）时降级为 ambiguous，列出候选与冲突
  证据，不择一。
- 推断结果可被后续权威值推翻：权威值出现后推断行标记 superseded，保留历史。
- 每条关联行包含：`basis`（命中规则原文）、`evidence`（命中的 part 片段/
  时间窗数字）、`confidence`、`computed_at`。

## 修订（2026-10-06，R006 复盘）

- **high 增加角色文本否决**：派发提示词首行自我声明角色（"You are an
  ORX worker/verifier…"）。声明存留时，与其他角色 attempt 的标记命中降为
  ambiguous。依据：R006 的 a108 验证会话提示词引用其核验的 worker attempt
  编号（"attempt 107" 证据血缘）且创建时间落在 worker 跨度 + 松弛内——时间
  窗拦不住，只有角色声明能区分。无声明则不否决（ORX 侧 nonce 落地前的
  best-effort 防线）。
- **high 增加时间窗交叉校验**：唯一标记命中之外，还要求会话创建时间落在
  该 attempt 跨度 ± 300s 松弛内（实现常量 `WINDOW_SLACK_MS`）。依据：R006
  实测一个 rev-2 worker 会话首提示携带 rev-1 证据血缘 "attempt 103"（a103
  早已关闭），仅凭标记会误链；而真实 worker 会话创建时间先于 claim 4–11 秒
  （R006 六个 host worker 样本）。时间只作否决证据（veto），绝不单独构成
  关联。
- **无跨度 attempt 的标记命中至多 ambiguous**：未 claim（无 started/ended）
  的 attempt 无法交叉校验创建时间，标记命中只保留为线索。
- 降级行的 `basis` 记录具体原因（跨度外/无跨度/多候选），`evidence` 保留
  命中片段、attempt 跨度、会话创建时间与窗口边界，可复核。

## 项目与会话的映射

- 注册项目以绝对路径为 `project_key`。zcode 会话按 `session.directory`
  精确相等映射；`proj_*` id 与 workspace 哈希仅作辅助校验，不单独决定归属。
- 未匹配任何注册目录的会话属于 `unassigned`，可随后注册项目后重新归属；
  不按标题猜测项目。
- Cursor composer 按 `workspaceId` → `workspaceStorage/<id>/workspace.json`
  的 folder URI 映射；无法解析的列为未归属。
- Codex 会话按 rollout `session_meta.cwd` / `turn_context.cwd` 映射。

## 同编号不并账

`T003` 在 rev1 与 rev3 是两个任务行；跨 revision 的对比只通过
`replan_*` 声明边（v9）进行，没有声明边就保持"未知"，不得用编号相似度
推断重复或浪费。
