# ORX Analytics — macOS 菜单栏应用（apps/macos）

Swift Package（Xcode-free 构建链）承载设计稿 §7/§9 的原生外壳：
SwiftUI `MenuBarExtra` 常驻入口（图标 + 进行中 Run 数徽标）、`LSUIElement`
菜单栏应用形态、引擎 Unix socket 客户端与缓存优先数据层。

## 构建 / 测试 / 冒烟（不打开 Xcode）

```sh
swift build                 # 或 ../../scripts/build_macos_app.sh
swift test                  # 协议客户端、缓存、缓存优先、口径规则单测
../../scripts/smoke_macos_app.sh   # 构建后以 --smoke-test 自检并退出
```

最低 macOS 13（`Package.swift` platforms）；Apple Silicon 优先。

## 结构

| 位置 | 职责 |
|---|---|
| `Sources/ORXAnalyticsCore` | 引擎 socket 客户端（JSON 协议、版本协商、不兼容明确报告）、overview 模型、缓存优先存储、AppModel、口径展示规则 |
| `Sources/ORXAnalyticsApp` | SwiftUI 应用：MenuBarExtra + 快速面板 + 设置（骨架）、`--smoke-test` 自检 |
| `Resources/Info.plist` | `LSUIElement` 等应用元数据；SwiftPM 构建时嵌入 `__TEXT,__info_plist`，Stage 5 打 `.app` 包时复用 |
| `Tests/ORXAnalyticsCoreTests` | 合成来源单测（EngineSimulator，不连真实引擎、不读真实会话） |

## 契约要点（实现必须遵守）

- 徽标数字固定为进行中 Run 数；关注标记附带文字说明（设计 §3）。
- 协议版本不兼容：明确报告 App/引擎两侧版本并停止查询，不强行接管（设计 §7）。
- 打开面板先渲染缓存，再异步刷新；刷新不阻塞主线程（设计 §3/§8）。
- token 数字沿用冻结口径：未知显示 "—"，只有明确记录为零才显示 0；
  ORX 已记录用量与原生会话预览两口径独立展示、不相加（设计 §5，docs/metrics.md）。
- Swift 层不写业务 SQL、不另实现 token 算法，一律经引擎查询接口取数（设计 §7）。
- 引擎 socket 默认 `<data-dir>/engine.sock`，data-dir 沿用 CLI 约定
  （`ORX_ANALYTICS_HOME` 覆盖，默认 `~/.orx-analytics`）。
- 清理显示缓存是设置里单独、明确的操作；退出/卸载不删除 ORX 项目数据（设计 §9）。

引擎协议契约见 `src/orxanalytics/engine.py` 与 `src/orxanalytics/query_model.py`
（本仓 Python 侧，Stage 2 交付）。
