import SwiftUI
import ORXAnalyticsCore

/// The menu-bar quick panel (design §3): header with status + manual
/// refresh, then 需要关注 / 进行中 / 最近完成, then footer actions.
///
/// Cache-first: the panel renders whatever `model.cachedOverview` holds
/// the moment it opens (cache is published synchronously at bootstrap)
/// and refreshes asynchronously — the open path never waits for a
/// collection round to finish.
struct QuickPanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if let cached = model.cachedOverview {
                attentionSection(cached.envelope)
                activeSection(cached.envelope)
                recentSection(cached.envelope)
            } else {
                emptyState
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(12)
        .onAppear { model.startAutoRefresh() }
        .onDisappear { model.stopAutoRefresh() }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("ORX Analytics").font(.headline)
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .help("正在异步刷新（不阻塞显示）")
                    }
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新状态")
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        if let cached = model.cachedOverview {
            parts.append("进行中 \(cached.envelope.summary.activeRuns)")
            parts.append("需要关注 \(cached.envelope.summary.attention)")
        }
        switch model.connection {
        case .idle: parts.append("未连接")
        case .connecting: parts.append("连接中")
        case let .ready(version): parts.append("引擎协议 v\(version)")
        case let .incompatible(requested, supported):
            parts.append("协议不兼容：App v\(requested) / 引擎 v\(supported)")
        case .notRunning(let why): parts.append(why)
        }
        if let cached = model.cachedOverview {
            parts.append("缓存于 \(Self.shortTime(cached.cachedAt))")
        }
        return parts.joined(separator: " · ")
    }

    private static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
    }

    // MARK: sections

    @ViewBuilder
    private func attentionSection(_ envelope: OverviewEnvelope) -> some View {
        if !envelope.attention.isEmpty {
            section(title: "需要关注 \(envelope.summary.attention)") {
                ForEach(envelope.attention) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Self.projectName(item.project)) / \(item.runID)")
                            .font(.callout)
                        Text("\(Self.kindLabel(item.kind))：\(item.detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func activeSection(_ envelope: OverviewEnvelope) -> some View {
        section(title: "进行中 \(envelope.summary.activeRuns)") {
            if envelope.active.isEmpty {
                Text("当前没有进行中的执行").font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(envelope.active) { run in
                    runCard(run)
                }
            }
        }
    }

    @ViewBuilder
    private func recentSection(_ envelope: OverviewEnvelope) -> some View {
        if !envelope.recentCompleted.isEmpty {
            section(title: "最近完成") {
                ForEach(envelope.recentCompleted) { run in
                    Text("\(Self.projectName(run.project)) / \(run.runID) — \(run.status.display)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runCard(_ run: OverviewRunItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("\(Self.projectName(run.project)) / \(run.goal?.objective ?? run.runID)")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(run.status.display).font(.caption)
                    .foregroundStyle(run.status.known ? .primary : .secondary)
            }
            HStack(spacing: 8) {
                Text("任务 \(MetricsFormat.progressText(run.progress))")
                Text(MetricsFormat.consumptionText(run.consumption))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.connection {
            case let .incompatible(requested, supported):
                Text("引擎协议版本不兼容")
                    .font(.subheadline.weight(.semibold))
                Text("本应用使用协议 v\(requested)，引擎支持 v\(supported)。已停止查询，不强行接管引擎。请升级应用或引擎后重试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .notRunning(let why):
                Text(why).font(.caption).foregroundStyle(.secondary)
                Text("首次使用请先在终端启动引擎（python -m orxanalytics.engine）。当前没有可显示的缓存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                Text("暂无缓存数据，正在异步刷新…").font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure = model.lastFailureText {
                Text(failure).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button("查看全部执行…") {
                openWindow(id: "run-detail")
            }
            Spacer()
            Button("设置…") {
                Self.openSettingsWindow()
            }
            Button("退出") {
                model.shutdown()
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    /// macOS renamed the settings action across versions; try both.
    static func openSettingsWindow() {
        for selector in [Selector(("showSettingsWindow:")),
                         Selector(("showPreferencesWindow:"))] {
            if NSApp.sendAction(selector, to: nil, from: nil) { return }
        }
    }

    // MARK: helpers

    static func projectName(_ key: String) -> String {
        (key as NSString).lastPathComponent
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "failed_task": return "任务失败"
        case "blocked_run": return "执行阻塞"
        default: return kind
        }
    }
}

/// Placeholder detail window (T008 skeleton; T009 delivers the four-zone
/// 执行概况/任务列表/消耗分析/尝试与证据 detail).
struct RunDetailStubView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.largeTitle)
            Text("执行详情").font(.title2)
            Text("详情四区（执行概况 / 任务列表 / 消耗分析 / 尝试与证据）在 T009 交付。")
                .foregroundStyle(.secondary)
            if let cached = model.cachedOverview {
                Text("进行中 \(cached.envelope.summary.activeRuns) · 需要关注 \(cached.envelope.summary.attention)")
                    .font(.callout)
            }
        }
        .padding(30)
        .frame(minWidth: 420, minHeight: 280)
    }
}
