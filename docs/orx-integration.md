# 与 ORX 的可选集成

ORX 负责执行控制，orx-analytics 负责观察和分析。二者独立安装。
安装 analytics 不修改 ORX，也不启动 watcher；ORX 日常执行不依赖它。
组织方式见 [ADR-0001](adr/0001-independent-repository.md)。

## 单向只读连接

登记需要观察的项目，然后采集：

```sh
orx-analytics projects add /absolute/path/to/project
orx-analytics collect --skip-global --json
orx-analytics report /absolute/path/to/project --run R001
```

ORX 项目必须已经由 ORX 初始化并具有受支持的 `.orx/state.db`。
analytics 自己不会初始化或升级它。没有 `.orx` 的项目可以登记为原生
会话项目，但不能凭空生成 ORX Run 报告。

analytics 通过 `mode=ro` 与 `query_only` 读取源库，遵循 WAL 和命名列
契约；只向自己的数据目录写导入、快照和分析结果。不要用 ORX 的
`Store.open` 代替只读读取，因为 ORX 打开自己的旧库可能触发迁移。
工具也不需要依赖 ORX Python 包。

## 向 Controller 声明已安装的工具

当前 ORX Controller skill 只在显式配置时尝试 watchdog：

```sh
export ORX_ANALYTICS_BIN="$(command -v orx-analytics)"
```

确认命令在 PATH 上且已安装后使用上述命令；也可以把变量设为工具的
绝对路径。这里声明的是工具入口，不是仓库目录，不要求相邻 checkout。
数据目录另由 `ORX_ANALYTICS_HOME` 或 `--data-dir` 指定。

未配置、未安装、启动失败或不支持当前来源时，Controller 应说明一次
并继续原有 Goal 流程。analytics 只能提供观察信号，不是调度状态权威。

## watcher 的所有权

推荐由操作者统一启动跨项目的长期 watcher：

```sh
orx-analytics watch start --interval 600
orx-analytics watch status
orx-analytics findings list
```

同一分析数据目录已有运行实例时，`start` 不应再启动第二个。
Controller 只可清理本会话实际启动的 watcher；已经存在的实例属于
操作者或其他会话，单个 Goal 完成时不能停止它。升级工具时由负责该
实例的操作者执行停止、升级和按需重启，后台进程不会自动载入新代码。

## 从发现到执行

`findings draft <id>` 只输出本地草案，`bundle run` 只导出调查证据。
操作者可检查它们，再把明确的目标交给 ORX。当前没有自动创建 Inbox、
自动发布 Issue、自动恢复会话或自动修复的连接；新增这些连接必须
另行定义接纳、授权和幂等规则。
