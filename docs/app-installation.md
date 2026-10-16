# ORX Analytics.app 安装、升级与回退（设计 §9）

App 交付物是自带 Python 运行时的 `ORX Analytics.app`：干净、无开发环境的
Mac（最低 macOS 13，Apple Silicon）无需预装 Python、uv 或 Homebrew，复制到
「应用程序」后双击即出现菜单栏图标。本文是安装、升级、回退、卸载与缓存的
唯一操作说明；CLI 安装见 [installation.md](installation.md)。

## 交付物与构建

| 构建命令 | 产物 | 应用名 / Bundle ID | 用途 |
|---|---|---|---|
| `scripts/build_app.sh dev` | `ORX Analytics (Dev).app` ＋ zip | `ORX Analytics (Dev)` / `org.orxanalytics.macos.dev` | 本机开发自测；独立 defaults 域，不污染正式版设置 |
| `scripts/build_app.sh dist` | `ORX Analytics.app` ＋ DMG | `ORX Analytics` / `org.orxanalytics.macos` | 正式分发 |

两者从 `Contents/Info.plist`（`CFBundleIdentifier`、名称、版本、
`ORXAnalyticsBuildFlavor`）与安装包命名上都可区分。版本号唯一来源是
`src/orxanalytics/__init__.py` 的 `__version__`，构建时写入 App 版本与
`Contents/Resources/orxanalytics-version.txt`。

构建脚本固定内置运行时（版本与 SHA256 写死在 `scripts/build_app.sh`）：

- python-build-standalone `cpython-3.12.8+20250115`（aarch64-apple-darwin，
  install_only），SHA256
  `e29003b69465c33692830032d9d237d84ea43a2e8461db9134641640fb49f040`。
- 首次构建下载到 `var/runtime-cache/`，之后离线复用；**每次构建都重新
  校验 SHA256**，不匹配即中止。
- App 的分析代码（`src/orxanalytics`，stdlib-only）随包复制进
  `Contents/Resources/orxanalytics`；引擎入口是包内
  `orx_engine_serve.py`（见下「引擎与进程」）。
- 构建末尾自测：用内置运行时在临时目录拉起引擎并确认 socket 监听后
  才产出归档（自测使用空的 `ORX_DATA_DIR`，不读任何真实会话）。

## 安装

1. 下载 DMG（或 dev zip），打开并把 `ORX Analytics.app` 拖入「应用程序」。
2. 首次双击。当前分发包只有 ad-hoc 签名且未经公证（见「已知限制」）：
   Gatekeeper 可能拦截，右键点 App 选「打开」确认一次；若仍被拦截，
   在终端执行 `xattr -dr com.apple.quarantine "/Applications/ORX Analytics.app"`。
3. 菜单栏出现 ORX 图标即安装成功。首次打开面板展示已发现项目、数据
   健康与添加入口；登录启动默认关闭，可在设置中开启（经
   `SMAppService.mainApp`，并显示系统实际状态）。

## 引擎与进程

- App 是引擎的生命周期管理者：socket 无应答时，用内置 Python 运行时
  启动 `orx_engine_serve.py <data-dir>`（获取单实例文件锁 → 绑定用户
  私有 Unix socket → 有界崩溃重启地运行调度器），等 socket 就绪后重试
  连接。协议版本不兼容时明确报告、不强行接管。
- 引擎入口说明：`python -m orxanalytics.engine`（engine.main）目前只
  加锁并跑调度器、不绑定 socket，无法服务 App 客户端；包内
  `orx_engine_serve.py` 用同样的公开引擎 API（acquire + start_server +
  EngineSupervisor）正确组合出服务行为。该 src/ 入口修复后两者可无
  行为差异地切换。
- 退出 App 只释放自己的采集需求；引擎若仍被 CLI watcher 需要，会继续
  运行（设计 §7 App/CLI 共存）。注销或重启后引擎不自动恢复，下次启动
  App 时自动重新拉起。
- 引擎日志在 `<data-dir>/logs/engine-launch.log`（容量有上限）；默认
  data-dir 是 `~/.orx-analytics`，可在设置中显式选择其他目录。

## 升级（保留数据）

1. 退出旧版 App（菜单栏图标 → 退出）。
2. 用新版 `.app` 覆盖替换「应用程序」里的旧版，双击启动。
3. **备份先于迁移**：App 每次启动引擎前检查
   `<data-dir>/app/last-launched-engine-version`。当已存在
   `analytics.db` 且即将运行的分析代码版本与上次不同，先把数据库复制到
   `<data-dir>/backups/analytics-pre-<版本>-<时间戳>.db`（只保留最新
   3 份），备份成功后才允许新版本引擎打开数据库；备份失败则拒绝启动并
   在面板给出原因——绝不带着未备份的数据库跑迁移。
4. 同版本重启不产生新备份。升级后旧数据与历史全部保留（导入天然幂等，
   重复采集不重复计数）。

## 回退（明确拒绝读取，不损坏数据）

- 降级安装到不认识现有 `analytics.db` 的 `store_version` 的旧版时，该版
  会明确报错拒绝打开（`store_version … != …; this reader cannot open
  it`），不会改写或损坏数据库。App 表现为引擎启动失败、面板提示原因，
  缓存数据继续展示。
- 处置顺序：① 重新装回能读取该版本的新版即可恢复使用；② 如需真正回退
  数据，先停止 App 与引擎，再从 `<data-dir>/backups/` 复制目标备份为
  `analytics.db`（覆盖前再手动留一份当前文件）。
- 回退永远只动 analytics 自己的数据库与备份目录，不触碰任何 ORX 项目
  数据（各项目 `.orx/state.db` 全程只读，见 ORX 仓
  `docs/observability-contract.md`）。

## 退出、卸载与缓存清理（各是独立操作）

- **退出**：菜单栏 → 退出，只结束 App 自身（见上「引擎与进程」）。
- **卸载**：把 `.app` 拖入废纸篓即可。卸载不会删除 `~/.orx-analytics`
  （analytics 数据）、任何 ORX 项目数据或用户级项目索引；想连数据一起
  清理需手动删除 `~/.orx-analytics` 目录。
- **清缓存**：设置里的「清理显示缓存」是单独、明确的操作，只清面板的
  展示缓存并回到空状态；它不删除 analytics 数据库，也不可能在退出或
  卸载时自动触发。

## 开发运行（非安装包）

- `swift run`（apps/macos，无内置运行时）下引擎自动拉起不可用，面板会
  提示缺运行时。开发替代方案：
  - 用 `scripts/build_app.sh dev` 产出 Dev 版 App 再运行；
  - 或设 `ORX_ANALYTICS_ENGINE_PYTHON`（Python 解释器路径）＋可选
    `ORX_ANALYTICS_ENGINE_SERVE`（默认在解释器同目录或上级目录找
    `orx_engine_serve.py`，如仓库根的 `apps/macos/Resources/` 下）＋
    `ORX_ANALYTICS_ENGINE_PYTHONPATH`（指向仓库 `src/`）。
- 冒烟：`scripts/smoke_macos_app.sh`（--smoke-test，合成引擎，无 GUI）。

## 已知限制（如实声明）

- **签名与公证未完成**：当前包为 ad-hoc 签名，无 Developer ID 签名、
  未做公证；首次打开需上述 Gatekeeper 确认。对外分发前需补正式签名
  与公证流程。
- 仅 Apple Silicon（arm64）构建；未做 Intel 通用二进制。
- 无自动更新框架：升级是手动替换安装包（设计允许）。
- `python -m orxanalytics.engine` 入口不绑定 socket（见「引擎与进程」），
  App 通过包内 `orx_engine_serve.py` 绕开；src/ 修复列入后续任务。
