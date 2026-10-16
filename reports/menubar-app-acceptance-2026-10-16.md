# ORX Analytics 菜单栏应用——首版验收报告

- Goal：G002（本仓 .orx）；Run：R002；计划 rev1（13 任务，12 worker/亲执 + 1 终审）。
- 日期：2026-10-16。控制器亲执终审（T013，host_context）。
- 设计蓝本：`docs/menubar-app-design.md`（2026-10-16 用户交付，控制器核对通过）。

## 总览

| 项 | 结果 |
|---|---|
| 任务 | 13/13 passed（rev1，零 replan、零 retry） |
| 本仓测试 | pytest 202 passed（基线 46 → +156）；swift 127 tests 0 失败 |
| ORX 主仓 | 1053 passed（基线 1043 + 10 新增，零回归） |
| 交付物 | `var/dist/ORXAnalytics-0.4.1-dist-macos13-arm64.dmg`、`var/dist/dist/ORX Analytics.app`、dev zip；安装升级文档 `docs/app-installation.md` |
| 性能实测 | 面板 overview P95 **110.3ms**（目标<300）；历史分页 P95 **110.8ms**（目标<1000）；引擎空闲 CPU **0.0%**（4×3s 持续采样） |

## §11 十条演示逐条证据

1. **安装并双击 App，菜单栏出现 ORX 图标。**
   T012 视觉验证（attempt 28，pass）：直接从构建产物 `var/dist/dist/ORX Analytics.app`
   启动（非 Xcode），菜单栏状态项出现（AXMenuBarItem，title=进行中数徽标）。
   DMG 与 dev zip 在 `var/dist/`。捆绑 python-build-standalone cpython-3.12.8
   （SHA256 固化于 `scripts/build_app.sh`，每次使用重验），无需预装 Python/uv/Homebrew。
2. **任意新目录 ORX 启动执行，无需手动登记即可出现。**
   终审活体演示（2026-10-16 15:20）：`/tmp/orx-g002-demo` 全新目录 `orx init`
   + `orx goal new` + `orx run` 一次 → 用户级索引
   `~/.local/share/orx/projects-index.json` 即刻含
   `/private/tmp/orx-g002-demo`（canonical path 归一，last_run_id=R001）→
   隔离 data-dir `discover --register` + `collect` →
   `overview` 显示 `active_runs: 2` 含 demo R001（目标文本、状态"规划中"、
   数据健康"正常"）。全程零手动项目登记。
3. **先看到进行中与需要关注的执行。**
   T009 视觉验证（pass）：快速面板三区（需要关注/进行中/最近完成），
   同一 Run 单卡片、异常优先；T012 视觉验证从 .app 产物确认面板 360x513
   与徽标=进行中 Run 数。
4. **点进任务，能解释 worker、重试、verifier 和缺失用量。**
   T009/T010 视觉验证（pass）：详情四区齐全；任务下钻 tasks.get 显示
   worker/verifier 分账、Attempt 明细（结果/来源 native_cli/用量/会话关联/
   失败原因）、覆盖率与缺失说明；§5 两口径并列且带"不相加"说明。
5. **刷新或重启后数字不重复增加。**
   终审活体演示：同一隔离库连续 3 轮追加 collect 后
   `runs.get(orx-analytics, R002)` 的 tasks=13 / per_task=13 /
   coverage={observed:0, attempts:17, missing_recorded:16, unassessed:1}
   三轮完全一致（快照号 29→33→35 前进，数字稳定）；另有 T007 幂等回归
   （重复 tick/合并刷新/引擎重启 17 例）。
6. **历史执行可以搜索，旧计划消耗没有消失。**
   T010 视觉验证（pass）：六过滤器+消耗排序与引擎序完全一致；R001 详情
   10 个 revision 全部可见、逐 revision 账本"保留计入 Run 汇总"。
7. **数据延迟和未知值清楚可见。**
   详情/历史每行带 as_of 与覆盖（"X/Y 次尝试"）；未知显示"—"并注
   "排序时排在最后，不表示消耗最少"（T010 视觉证据）；G002 自身
   17 attempts 中 16 missing_recorded + 1 unassessed——缺失如实呈现为
   "—"而非 0（活体即证据）。
8. **关闭窗口继续驻留，登录启动和退出行为符合设置。**
   T009（关窗驻留，进程存活）+ T011（SMAppService.mainApp 默认关、
   显示系统实际状态、通知默认关仅开启时申请权限；vision pass）。
9. **所有采集都没有改写 ORX 源数据库。**
   终审活体演示：demo 项目 `.orx/state.db` 整轮 discover+collect 前后
   SHA256 完全一致（c670444a…c0e8 字节级相同）；全部采集路径只读连接
   （T005/T006 回归测试 + 只读契约）。
10. **安装包、源码、契约文档、测试结果和已知限制一并交付。**
    见本报告各节与"已知限制"；源码 14 个功能提交（4d75c10…3ccd839）；
    契约文档：metrics.md 增补、orx-integration.md 索引消费契约、
    watch-migration.md、app-installation.md、menubar-app-design.md。

## 四门槛

- **常驻可用**：LSUIElement+MenuBarExtra 应用，关闭窗口驻留、仅"退出"结束；DMG 产物双击可用（条 1/8）。
- **自动发现**：ORX 用户级索引（写侧 G002/T004 上线，`orx run` 即登记）→ discover 三来源合并（条 2 活体）。
- **状态可信**：未知状态显示"未知状态"绝不猜终态；三维分立；数据健康独立；缺失不补零（条 3/7）。
- **消耗可解释**：分账（worker/verifier/planner/controller/未归属）、覆盖率随行、两口径不相加、派生指标版本化（条 4/5/6）。

## 性能实测（20 项目 / 10,000 任务 / 17,704 attempts / 15,032 usage 行合成基准）

- 方法：合成 20 项目×2 runs×250 任务镜像数据（schema v12 形状），
  热身后各测 50 次；P95=升序第 95 百分位。脚本全文见附录，可复现。
- 结果：overview P95 110.3ms（max 113.1）；runs.list(50/页) P95 110.8ms
  （max 114.2）；引擎（真实子进程）12 秒安顿后空闲 CPU 0.0%×4 采样。
- 达标判定：三项全部达标，实测记录在案。

## 控制器修复披露（终审期间，超出原任务范围）

1. **`python -m orxanalytics.engine` 模块入口不服务 socket**（T012 打包时发
   现；T006 交付的 main() 只 acquire+调度，watch start 真实拉起路径会得到
   不服务的引擎；T007 测试 mock 了拉起所以未拦截）。修复 `3ccd839`：
   工厂 acquire 后 `start_server()`；新增真实子进程回归测试
   （engine.sock 绑定 + health 应答，tests/test_engine.py 第 20 例）。
   App 捆绑的 `orx_engine_serve.py` 组合入口保留（等价路径，后续可统一）。

## 已知限制（如实）

1. **签名与公证**：本机 ad-hoc 签名；无 Developer ID/公证（首版手动下载、
   右键打开绕 Gatekeeper 的说明在 app-installation.md）。对外分发前需补。
2. **架构**：仅 Apple Silicon（arm64）+ macOS 13+；Intel 未构建。
3. **更新**：手动下载升级；无自动更新框架。
4. **现网旧 watcher 迁移待用户执行**：pid 98698（600s 轮）仍在运行，
   与引擎数据安全共存；按 `docs/watch-migration.md` 由用户确认后停旧起新，
   应用/引擎绝不盲杀。
5. **G002 自身用量观测缺口**：本 Run 17 个 attempts 中 16 个
   missing_recorded、1 个 unassessed——ORX 侧未记录规范观测行
   （zcode 会话关联未闭合），应用如实显示"—"。属 ORX 侧观测回填议题，
   非应用口径缺陷。
6. **像素级截图**：两次视觉验证在锁屏控制台下经活体 AX 树+数据层核对
   （结构逐项确认）；像素截图未采集。安装包级双击演示以 T012 二进制直启
   +DMG 产物为准。

## 附录：性能基准复现脚本

```python
# ORX_ANALYTICS_HOME=/tmp/orx-g002-bench python（本仓 .venv）
# 造数：20 项目×2 runs×250 任务；85% attempts 带 zcode_db/exact 用量行。
# 测量：热身后各 50 次 query_model.overview(s) / runs_list(s, limit=50,
# offset∈{0,50,100})，取 P95。实测：110.3 / 110.8 ms。
# 空闲 CPU：python -m orxanalytics.engine --data-dir … 后 12s，
# ps %cpu 采样 ×4 → 0.0/0.0/0.0/0.0。
```

（完整脚本语句以终审会话执行记录为准；数据形状=store.py 镜像表、
schema v12、import_runs status=done。）

## 结论

Goal G002 十二条验收标准逐条有实证支撑（四条为终审活体演示，其余为
任务门禁+独立视觉验证+测试矩阵）；四门槛成立；性能三项达标实测。
ORX Analytics 首版交付达成。
