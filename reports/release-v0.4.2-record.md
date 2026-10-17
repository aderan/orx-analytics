# v0.4.2 发布记录（G011/T008 独立证据提交）

性质：**独立证据提交**——冻结源码提交 `2461a260387caf0e6acb63446d4be3b8d1a43b46`
（即 tag `v0.4.2` 所指提交）之后追加的文档，**不含任何源码变更**；本仓发布
源码自该冻结提交起未再变化。联合验收的权威记录在 ORX 仓
`docs/diagnostics/g011/`（joint-acceptance-report.md、freeze-report.md、
baseline.json、distribution.json、joint-acceptance-runbook.md）；本文件是
Analytics 侧对发布事实的对账记录。

## 发布锚点（2026-10-17，均已远端核实）

| 项 | 值 |
|---|---|
| 兼容组合 | ORX v0.4.0 ＋ ORX Analytics v0.4.2（两仓版本不必同号） |
| 本仓标签 | `v0.4.2` → `2461a260387caf0e6acb63446d4be3b8d1a43b46`（轻量标签，远端 `git ls-remote` 核实一致；本仓此前无任何标签，历史无标签保持无标签） |
| ORX 侧标签 | `v0.4.0` → `f1cc7757c953d3fee5bff5630613a6d2fb380a74`（ORX 历史标签 v0.1.0–v0.3.1 原样，v0.3.0 仍指 `0f2629e6…`） |
| 本仓 Release | https://github.com/aderan/orx-analytics/releases/tag/v0.4.2 （App 归档为内部预览渠道，标记 prerelease；wheel/sdist 为 0.4.2 分发物） |
| ORX 侧 Release | https://github.com/aderan/orx/releases/tag/v0.4.0 |
| 远端 main | `aderan/orx-analytics` main 推至 `2461a26`（+本证据提交后的后续提交）；`aderan/orx` main 推至冻结提交之后的证据提交 |

## 发布资产（字节取自联合受验冻结候选，发布阶段未重建/未重签/未修改）

| 资产 | 所在 Release | SHA256 |
|---|---|---|
| `ORXAnalytics-0.4.2-internal-preview-dev-macos13-arm64.zip` | 本仓 v0.4.2 | `5187029c8ab41a41a8d6100c502061035a322c7d24ad015cfbe2fa76303d7396` |
| `orx_analytics-0.4.2-py3-none-any.whl` | 本仓 v0.4.2 | `284d07741306347630f70f52b9be4a5322efbe2c84e41f05ccffff4cc956584d` |
| `orx_analytics-0.4.2.tar.gz` | 本仓 v0.4.2 | `751a1011ca6e00c351c662c43d6af9a8c49481419b2b946dbaacecf3df4ef924` |
| `orx_agent-0.4.0-py3-none-any.whl` | aderan/orx v0.4.0 | `f71c19aebd2dcd1a09524602be50ad730b194d743f52925ea59fd75c2d2a212f` |
| `SHA256SUMS.txt` / `manifest.json` / 兼容组合说明 | 两仓 Release 同字节随发 | 见各 Release 资产 |

发布后复算：两 Release 全部资产经 `gh release download` 下载并重算
SHA256，与冻结清单（ORX 仓 `dist/g011/candidate.json`／`manifest.json`
绑定）逐项一致；消费者侧核对 `verify-remote` 绿（internal-preview 渠道
根逐字节一致、绑定一致、无 DMG 混入）。

## 渠道结论

- **内部预览（internal-preview）**：App 归档为 ad-hoc 签名、未公证，
  受众仅内部测试，Gatekeeper 拦截首次启动需手动确认（安装文档在案）；
  Release 已标 prerelease 并在标题/正文/包内四维标注渠道身份。
- **正式分发（official）**：保持受阻——无 Developer ID Application
  证书、无 notarytool 存储凭据（2026-10-17 实测）；凭据齐备并真实
  签名/公证/装订/安装评估前，不产出 DMG、不使用正式分发表述。
- **已知缺陷披露**：安装后首次拉起内置引擎向包内写 73 个
  `__pycache__` pyc 使 `codesign --verify` 由 0 变 1（归档字节与安装
  时验签不受影响）；修复＝`EngineProcessManager.makeChild` 设
  `PYTHONDONTWRITEBYTECODE=1`，落在下一个 Analytics 发布。
