import SwiftUI
import ORXAnalyticsCore

/// Minimal settings for the skeleton: shows where data lives and offers
/// the SEPARATE, explicit display-cache cleanup. Quitting or uninstalling
/// the app never deletes ORX project data (design §9); cache clearing is
/// its own deliberate action.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmedClear = false

    var body: some View {
        Form {
            Section("引擎") {
                LabeledContent("Socket") {
                    Text(EngineSocketClient.defaultSocketPath())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("状态") {
                    Text(connectionText)
                }
            }
            Section("显示缓存") {
                Text("缓存只影响面板显示速度。清理它不会触碰 ORX 项目数据，也不会删除 analytics 采集数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if confirmedClear {
                    Button("确认清理显示缓存", role: .destructive) {
                        model.clearDisplayCache()
                        confirmedClear = false
                    }
                } else {
                    Button("清理显示缓存…") { confirmedClear = true }
                }
            }
            Section("通知") {
                Text("通知默认关闭（T011 交付开启流程与系统权限申请）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
    }

    private var connectionText: String {
        switch model.connection {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case let .ready(version): return "已连接（协议 v\(version)）"
        case let .incompatible(requested, supported):
            return "协议不兼容：App v\(requested) / 引擎 v\(supported)"
        case .notRunning(let why): return why
        }
    }
}
