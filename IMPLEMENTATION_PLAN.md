# ORX Analytics 菜单栏应用实施计划

目标：按 `docs/menubar-app-design.md`（2026-10-16 已接受设计）交付常驻 macOS
菜单栏的本地任务观察工具首版。ORX Goal G002 / 计划 rev1（13 任务）。
全部完成后移除本文件。

## Stage 1 契约与查询模型（T001–T003）

- 目标：状态映射（未知值显示"未知状态"）、五层身份键（短编号不作跨项目/
  跨 revision 键）、token 归属与覆盖率读取模型、跨项目六接口查询层。
- 可验证结果：跨项目/版本同编号不串账；缺失不补零；重试与验证归属正确；
  Run 汇总含全部 revision；消耗排序携带覆盖程度。
- 测试：tests/test_display_contract.py、tests/test_usage_readmodel.py、
  tests/test_query_model.py + 全量回归。
- 状态：已完成（T001 c400e8d / T002 18a922b / T003 9cf671d；全量 138
  passed）。

## Stage 2 发现与协调引擎（T004–T007）

- 目标：ORX 主仓用户级项目索引（写侧，失败不阻塞执行）＋本仓发现层
  （索引/registry/有界扫描合并）＋单实例协调引擎（fcntl 文件锁、Unix
  socket JSON 协议、5/15/60s 分级调度、旧 watcher 迁移指引）＋watch
  协调改造。
- 可验证结果：并发登记不丢项目；App/CLI 共存；未知 schema 隔离；
  源库零写操作；重复采集/刷新/重启不重复计数。
- 测试：ORX 仓 tests/test_project_index.py + 全量（基线 1043）；
  本仓 tests/test_discovery.py、tests/test_engine.py、
  tests/test_watch_engine.py + 全量回归。
- 状态：已完成（T004 ORX 仓 c96ed8b＋本仓 0bdd02b 消费契约；T005
  4af1b10；T006 0b4b992；T007 2acf0aa；全量 201 passed。现网旧
  watcher pid 98698 仍在跑——迁移为用户确认步骤，见
  docs/watch-migration.md）。

## Stage 3 原生菜单栏闭环（T008–T009）

- 目标：apps/macos SwiftUI 应用（MenuBarExtra＋LSUIElement＋引擎 socket
  客户端、缓存优先），快速面板三区与执行/任务详情四区。
- 可验证结果：从进行中执行进入任务消耗明细；刷新不阻塞界面；关闭窗口
  仍驻留；未知值显示"—"；两口径不相加。
- 测试：swift build / swift test + agent[vision] 界面走查。
- 状态：已完成（T008 d878e5b 骨架/31 XCTest；T009 c146432 面板与详情/
  58 XCTest＋跨语言线契约测试；vision 走查 pass——锁屏下经活体 AX 树
  核对 §3/§4 结构，像素截图留 T012 安装包演示补）。

## Stage 4 历史与运行完善（T010–T011）

- 目标：历史查询/搜索/排序带覆盖程度；通知（默认关、去重、合并、点击
  跳转）；设置；SMAppService 登录启动；睡眠唤醒重同步；错误与诊断视图。
- 可验证结果：旧计划消耗保留；异常去重不反复报警；单源失败不拖垮整体。
- 测试：swift test + agent[vision] 走查。
- 状态：已完成（T010 5cf8326 历史查询/74 XCTest＋线契约；T011 2fbac94
  通知/设置/登录启动/诊断/睡眠唤醒/112 XCTest；两任务 vision 走查 pass）。

## Stage 5 安装与发布验证（T012–T013）

- 目标：内置固定版 Python 运行时的可安装 .app 与归档、构建脚本、安装
  升级文档；终审按设计 §11 十条演示＋性能基准实测（20 项目/1 万任务：
  缓存面板 P95<300ms、历史分页 P95<1s、空闲无持续 CPU）。
- 可验证结果：干净 Mac 双击可用；升级保留数据；全部验收证据与已知限制
  一并交付；IMPLEMENTATION_PLAN.md 收口移除。
- 测试：build_app.sh、两仓全量、agent 独立终审。
- 状态：未开始。
