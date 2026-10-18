# v0.4.3 验收记录（G012/T007，冻结候选验收）

性质：**冻结后独立证据文档**——Analytics 冻结提交
`d0867103a447e94ca1fd01731a60be62aeb2823a`（0.4.3）与 ORX 侧验收驱动提交
`043eecbd…` 之后追加，**不含任何源码变更**；联合验收的权威驱动与完整
证据在 ORX 仓 `scripts/joint_release.py`（`dist/g012/`）。本文件是
Analytics 侧对冻结候选验收事实的对账记录。发布（打标 v0.4.3、上传
Release）属 T008，不在本记录范围。

## 冻结候选锚点（joint_release.py，goal g012，工作目录 dist/g012）

| 项 | 值 |
|---|---|
| 兼容组合 | ORX v0.4.0（固定 pin）＋ orx-analytics 0.4.3（冻结提交 d0867103…） |
| ORX 产品输入 | 发布标签 `v0.4.0` → `f1cc7757…`（本地＋远端一致；`orx-pin-moved` 失败关闭在位） |
| ORX 发布动作 | **零**：不重建、不打标签、不重传 Release；演练用 ORX wheel 自 pin 溯源重建（sha256 `f71c19ae…` 与已发布 v0.4.0 资产一致） |
| 验收驱动提交 | `043eecbdeed6f88108fd9ed126fbd40991c1f872`（binding.acceptance_driver，仅溯源非输入） |
| 渠道决定 | `docs/diagnostics/g012/distribution.json` sha256 `a94df4c5…` 绑定：internal-preview（ad-hoc dev zip）允许；official 仍受阻（无 Developer ID Application、无 notarytool 凭据，2026-10-17 实测） |
| 历史标签 | 快照冻结于候选：analytics `v0.4.2` → `2461a260…` 原样；ORX v0.1.0–v0.4.0 全部原样（`historical_tags_unchanged: true`） |
| 受保护报告 | `docs/m1.2-report.md` 全程未暂存未提交；发布物取提交态（候选记录披露排除决定） |

## 电池（五项，全部一次性干净克隆，exit 0）

- ORX 全量 pytest＋check_release：自 **v0.4.0 pin** 克隆（非 HEAD）；其
  自带 joint 测试按其自身发布对环境断言——联合布局携带已发布 analytics
  `v0.4.2`（tag 移动即 `analytics-v042-pin-moved` 失败关闭，与 orx-pin
  同纪律）。
- Analytics 全量 pytest＋swift test＋check_install：自 **0.4.3 冻结提交**
  独立干净克隆 `battery/analytics`（不跳过、不替代）。
- 冻结前工作树实测：Python 279 passed；swift test 163 executed /
  0 failures（5 项既有跳过）。

## 产物（候选冻结，发布阶段不重建不重签不修改）

| 资产 | SHA256 |
|---|---|
| `ORXAnalytics-0.4.3-internal-preview-dev-macos13-arm64.zip` | `461a2f037f9e94125d559ad57def4166383ba6f06a50d55c7014813909d63824` |
| `orx_analytics-0.4.3-py3-none-any.whl` | `7f7c6692a1559e5c736d732a3db780f5588500f505245b2b0dd2bf01aba73ef9` |
| `orx_analytics-0.4.3.tar.gz` | `b25327a8f8d456eaba912282d83043ee858d24822d1cc76b3be60161ed989a2b` |
| orx_agent-0.4.0 wheel（溯源重建，非发布动作） | `f71c19aebd2dcd1a09524602be50ad730b194d743f52925ea59fd75c2d2a212f` |

版本一致性（候选只读复验绿）：wheel/sdist/App `CFBundleShortVersionString`
/包内引擎版本/发布说明全部 0.4.3；ORX wheel 0.4.0。App 元数据：
channel=internal-preview、source_commit=d0867103…、内置运行时
cpython-3.12.8+20250115（sha256 校验）；ad-hoc 签名 `codesign --verify`
exit 0。

## 隔离演练（exercise，passed）

冻结 ORX wheel 装入一次性 venv 驱动隔离项目全生命周期（暂停→继续期间
完成不冒充 done、回执重放零变更、cancelling→cancelled、恢复与未确认
执行者列出、历史可查），最终 App 内置引擎 socket 两次采集只读断言
（bundled_analytics_version 0.4.3、read_only_source、无真实会话镜像、
stand_in_app_delivery false）。

## 安装副本与首启/重启封条（v0.4.2 已披露缺陷的落地验收）

- 归档 sha256 复核与候选一致后 **ditto** 解压安装到
  `dist/g012/installed/ORXAnalytics.app`（通道名 bundle 就位为受检路径，
  字节未动）；`codesign --verify --deep --strict` 安装后仍 exit 0。
- `check_runtime_seal.py`（规定命令）两轮真实启动——**first-launch** 与
  **engine-restart** 均取得真实启动证据：引擎进程为所启动 App 的子进程
  （经生产 `makeChild` 路径、命令行指向包内运行时）、socket 可连接、
  启动日志落盘（顺带修复的首装缺陷在真包上生效）；启动前后 bundle 各
  2000 条目逐字节比对 added/removed/changed **全空**（零新增
  `__pycache__`）；检查对 App 施加对抗值 `PYTHONDONTWRITEBYTECODE=0`
  （内置 CPython 3.12.8 下该值仍写码），封条完好只可能来自 App 自身的
  强制。verdict **pass**（两轮规定复跑同绿）。
- 对照：v0.4.2 同路径首启写 73 个 pyc、验签 0→1（G011 记录）；本版修复
  在真实安装副本上验证闭环。

## 用户五项反馈的验收事实（安装后实际 App）

1. **token 千位分隔**：安装后二进制 `--smoke-test` PASS
   （metrics-freeze-rules 含 `tokenText(1200)=="1,200"`、
   `tokenText(1234567)=="1,234,567"`）；App 自身引擎（面板数据源）实测
   大数：R012 input 82,573,883、R011 input 184,766,456、controller 会话
   自身 input 109,266,766——面板/详情经同一 `MetricsFormat` 入口渲染。
   未知 `—`、显式 0、两口径并列契约由冻结电池 swift 全量钉死。
2. **点击项目卡片窗口前置**：实现于冻结树（`DetailWindowRouting`
   activate→openWindow→makeKeyAndOrderFront；面板卡片/查看全部执行/
   通知深链三接线＋宿主双保险），battery swift 套件含选中路由与前置
   遍历测试。像素级前置观察因环境权限边界不可行（见下），移交清单在
   ORX 侧 gui-evidence 边界记录。
3. **目标已完成降为普通文字**：引擎实测最近完成区 goal 终态 done 原文
   （R011/R010/R009/R005/R003），面板经 `controlPlainText`（caption2+
   secondary）渲染；非终态（已暂停/取消中/已取消）徽标保留、控制/执行
   双维度分层由 PanelSectionsTests 钉死（互斥完备）。
4. **刷新节律下调**：安装后 App 面板打开状态下 95 秒实测——引擎状态轮
   每 **~30.3 秒**（3 轮；0.4.2 的 5 秒缺省同窗口约 19 轮），与新
   TIER_INTERVALS ui=30s 及面板缺省 30s 一致；显式选择过的旧偏好保留
   （升级标记语义）由 AppSettingsTests 钉死。
5. **controller token 归属**：引擎实测——R005/R003
   `controller_for_run=attributed`（会话 own_usage：281 请求 input
   66,837,410 / 59 请求 input 8,403,221，model_usage_requests 口径、
   processed=input+output、错误零占位显式标记）；R012/R011
   `unattributed` 附真实原因「子会话 attempt 分属 R011/R012 两 run」并
   显示带强制不摊分标注的会话累计（353 请求 input 109,266,766）。判定
   全部路径在真实数据各出现一次；只读（源库采集前后无 -wal/-shm 残留）。

## GUI 观察边界（如实记录）

会话按 CGSession 探针为解锁（onConsole=1/loginDone=1，且操作者自有
窗口同屏渲染），但本进程无 Screen Recording 权限——`screencapture`
全黑帧（实测 max 亮度 0）；SwiftUI 状态面板不暴露 AX 内容（0.4.3 与
用户在用 0.4.2 两实例同证）；合成鼠标事件同样受 TCC 限制。已取得的
真实 UI 级事实：菜单栏徽标实时读数（2→1，真实数据）、AXPress 打开
真实面板（窗口服务器在屏 360×559 证据）。像素级五项复核以解锁后/授权
后人工清单移交（G011 §9.1 同式，ORX 侧 `dist/g012/gui-acceptance/
screencapture-boundary.txt`）。

## 数据边界

演练与验收全部在 `dist/g012/` 一次性目录：演练 venv、隔离项目、安装
副本、封条/引擎沙箱数据目录；GUI 验收引擎数据目录为
`dist/g012/gui-acceptance/runtime-data`（隔离注册，只读采集
`~/.zcode`/本仓 `.orx/state.db`）。用户 `/Applications` 在用 0.4.2
预览、`~/.orx-analytics`、`~/.zcode` 零触碰（全程只读打开源库）。
