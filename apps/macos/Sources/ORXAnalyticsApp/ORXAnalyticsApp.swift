import SwiftUI
import ORXAnalyticsCore

/// ORX Analytics menu-bar app (design §3/§7/§9).
///
/// - `MenuBarExtra` is the persistent entry: icon + the in-progress Run
///   count (the number is FIXED to that meaning — never task/session/
///   token counts). An attention marker appears beside it when
///   attention > 0, explained in text inside the panel (not color only).
/// - `LSUIElement` (Resources/Info.plist) makes it a menu-bar-only app:
///   no Dock icon, no main window; closing windows keeps it resident.
/// - All data flows through the engine's socket protocol
///   (`ORXAnalyticsCore`); the Swift layer writes no business SQL and
///   implements no token math of its own.
@main
struct ORXAnalyticsApp: App {
    @StateObject private var model: AppModel

    init() {
        // Xcode-free smoke hook (scripts/smoke_macos_app.sh): verify the
        // protocol client, cache layer and frozen formatting rules
        // against a local simulator, then exit before any UI starts.
        if CommandLine.arguments.contains("--smoke-test") {
            let ok = SmokeRunner.runAndReport()
            exit(ok ? 0 : 1)
        }
        let client = EngineSocketClient(socketPath:
            EngineSocketClient.defaultSocketPath())
        _model = StateObject(wrappedValue: AppModel(client: client,
                                                    cache: OverviewCacheStore.makeDefault()))
    }

    var body: some Scene {
        MenuBarExtra {
            QuickPanelView()
                .environmentObject(model)
                .frame(width: 360)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.attentionCount > 0
                      ? "exclamationmark.octagon.fill"
                      : "circle.grid.2x2")
                // The number is ALWAYS the in-progress Run count (§3).
                if model.activeRunCount > 0 {
                    Text("\(model.activeRunCount)")
                }
            }
        }
        .menuBarExtraStyle(.window)

        // Details live in their own window (T009: the four-zone run/task
        // detail). Keeping it a separate scene preserves "关闭窗口后继续
        // 驻留" — only the panel's 退出 ends the app.
        Window("执行详情", id: "run-detail") {
            RunDetailHostView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
