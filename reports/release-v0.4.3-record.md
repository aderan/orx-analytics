# v0.4.3 发布记录（G012/T008 独立证据提交）

性质：**独立证据提交**——冻结源码提交 `d0867103a447e94ca1fd01731a60be62aeb2823a`
（即 tag `v0.4.3` 所指提交）之后追加的文档，**不含任何源码变更**；本仓发布
源码自该冻结提交起未再变化。联合验收的权威记录在 ORX 仓
`docs/diagnostics/g012/`（joint-acceptance-report.md、baseline.json、
distribution.json、joint-acceptance-runbook.md）；Analytics 侧冻结候选
验收对账见本仓 `reports/release-v0.4.3-acceptance.md`（提交 `253dd93`）；
本文件是 Analytics 侧对发布事实的对账记录。

## 发布锚点（2026-10-19 10:21 UTC，均已远端核实）

| 项 | 值 |
|---|---|
| 兼容组合 | ORX v0.4.0 ＋ ORX Analytics v0.4.3（两仓版本不必同号；ORX schema 8–15，本版 store v4） |
| 本仓标签 | `v0.4.3` → `d0867103a447e94ca1fd01731a60be62aeb2823a`（**轻量标签**，远端 `git ls-remote` 核实一致、无 `^{}` 解引用；推送前远端无同名标签，普通 push 非强推） |
| 历史标签 | 本仓 `v0.4.2` → `2461a260387caf0e6acb63446d4be3b8d1a43b46` 原样；ORX v0.1.0–v0.4.0 全部标签对象映射原样（含 annotated 对象与 peeled commit） |
| 本仓 Release | https://github.com/aderan/orx-analytics/releases/tag/v0.4.3 （App 归档为内部预览渠道，**标记 prerelease**；wheel/sdist 为 0.4.3 分发物；published 2026-10-19T10:21:27Z） |
| ORX 侧动作 | **零**：v0.4.0 产品、标签与既有 Release 资产原样（不重发不重传不打标）；ORX wheel 不随本 Release 重传 |
| 远端 main | `aderan/orx-analytics` main 推至 `253dd93`（冻结提交＋验收对账记录）＋本证据提交；`aderan/orx` main 推至 G012 验收驱动/文档提交（driver/docs-only，无产品源码） |

## 发布资产（字节取自联合受验冻结候选，发布阶段未重建/未重签/未修改）

| 资产 | 所在 Release | SHA256 |
|---|---|---|
| `ORXAnalytics-0.4.3-internal-preview-dev-macos13-arm64.zip` | 本仓 v0.4.3 | `461a2f037f9e94125d559ad57def4166383ba6f06a50d55c7014813909d63824` |
| `orx_analytics-0.4.3-py3-none-any.whl` | 本仓 v0.4.3 | `7f7c6692a1559e5c736d732a3db780f5588500f505245b2b0dd2bf01aba73ef9` |
| `orx_analytics-0.4.3.tar.gz` | 本仓 v0.4.3 | `b25327a8f8d456eaba912282d83043ee858d24822d1cc76b3be60161ed989a2b` |
| `orx_agent-0.4.0-py3-none-any.whl` | aderan/orx v0.4.0（不重传） | `f71c19aebd2dcd1a09524602be50ad730b194d743f52925ea59fd75c2d2a212f` |
| `SHA256SUMS.txt` / `manifest.json` / `compatibility-orx-0.4.0-analytics-0.4.3.md` | 本仓 v0.4.3 | 见各 Release 资产（SHA256SUMS 为上述四项逐行清单） |

发布后复算：本 Release 全部资产经 `gh release download` 下载并重算
SHA256，与冻结清单（ORX 仓 `dist/g012/candidate.json`／`manifest.json`
绑定）逐项一致；ORX wheel 自其 v0.4.0 Release 下载核验同哈希；
`SHA256SUMS.txt` 逐行吻合；消费者侧核对 `joint_release.py verify-remote
--work-dir dist/g012 --channel-root dist/g012/channels/internal-preview`
绿（internal-preview 渠道根由下载资产填充，逐字节一致、绑定一致、
无 DMG 混入）。

## Release 说明要点（随 Release 正文公开）

五项反馈修复摘要；controller 数据口径与不可关联边界（逐 run 判定、
共享会话绝不摊分、仅 native_session_preview 口径）；新默认节律
（面板/详情 30s、引擎 30/60/300s、显式选择保留）；首启 seal 缺陷
**本归档已修复**（两轮真实启动、codesign 0→0，取代 0.4.2 披露）；
内部预览渠道标注（ad-hoc、prerelease、Gatekeeper、Finder/ditto
安装）；解锁后约 10 秒像素复核移交（五项清单）；兼容组合 ORX
v0.4.0（schema 8–15）＋ store v4 升级链；受保护报告排除披露。

## 渠道结论

- **内部预览（internal-preview）**：App 归档为 ad-hoc 签名、未公证，
  受众仅内部测试，Gatekeeper 拦截首次启动需手动确认（安装文档在案，
  Finder/ditto 解压、禁 unzip）；Release 已标 prerelease 并在标题/
  正文/Info.plist/包内 distribution.json 四维标注渠道身份。
- **正式分发（official）**：保持受阻（无 Developer ID Application、
  无 notarytool 凭据，2026-10-17 实测，见 ORX 仓
  `docs/diagnostics/g012/distribution.json`）；不产出 DMG。
- Analytics Python 分发物（wheel/sdist）：随本 Release 正常分发。

## 遗留移交（如实）

- 解锁后约 10 秒像素级人工复核（五项清单：千位分隔/点击前置/已完成
  普通文字/默认 30 秒/controller 归属）随 Release 说明移交，结果
  无论通过与否需如实记入后续发布说明。
