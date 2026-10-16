import Foundation

/// Pure presentation model for the quick panel's three sections
/// (design §3). Every merge rule lives here so it is unit-testable
/// without a GUI:
///
/// - 同一 Run 只出现一次：a run referenced by attention items is shown
///   ONLY in 需要关注 and is removed from 进行中 / 最近完成.
/// - 异常优先排序：the attention section is the first section
///   (`sectionOrder`); within a section cards keep the engine's stable
///   identity order.
/// - Attention for a run missing from both lists (e.g. a terminal
///   failed run) still gets a synthetic card — attention facts are
///   never dropped, and the synthetic status is 未知状态, never a
///   guessed terminal state (design §4).
/// - Current-plan progress and all-revision consumption ride along as
///   SEPARATE fields (`run.progress` vs `run.consumption`); there is no
///   combined value (`combinedProgressConsumpletion` stays nil) and no
///   percentage is fabricated.
public struct PanelRunCard: Equatable, Identifiable {
    public let run: OverviewRunItem
    public let attention: [AttentionItem]

    public var id: String { run.id }

    /// Always nil. Exists so tests (and readers) can assert that this
    /// model never fabricates a combined progress/consumption number.
    public var combinedProgressConsumption: String? { nil }
}

public enum PanelSection: Equatable {
    case needsAttention
    case active
    case recentCompleted
}

public struct PanelModel: Equatable {
    public let needsAttention: [PanelRunCard]
    public let active: [PanelRunCard]
    public let recentCompleted: [PanelRunCard]
    public let sectionOrder: [PanelSection]
    /// project -> engine-classified data health (third dimension).
    public let healthByProject: [String: DataHealthBlock]

    /// The panel of "nothing known yet" — used before the first cache
    /// load so the three sections render with empty captions.
    public static var empty: PanelModel {
        PanelModel(needsAttention: [], active: [], recentCompleted: [],
                   sectionOrder: [.needsAttention, .active, .recentCompleted],
                   healthByProject: [:])
    }

    public static func build(_ envelope: OverviewEnvelope) -> PanelModel {        var byRun: [String: PanelRunCard] = [:]
        var order: [String] = []
        let activeIds = Set(envelope.active.map(\.id))
        let recentIds = Set(envelope.recentCompleted.map(\.id))

        func add(_ run: OverviewRunItem) {
            guard byRun[run.id] == nil else { return }   // 同一 Run 只出现一次
            byRun[run.id] = PanelRunCard(run: run, attention: [])
            order.append(run.id)
        }
        envelope.active.forEach(add)
        envelope.recentCompleted.forEach(add)

        for item in envelope.attention {
            let key = "\(item.project)#\(item.runID)"
            if let card = byRun[key] {
                byRun[key] = PanelRunCard(run: card.run,
                                          attention: card.attention + [item])
            } else {
                // Run not listed anywhere (terminal but needing
                // attention): synthesize a card instead of dropping the
                // attention fact. Status stays unknown — no guessing.
                byRun[key] = PanelRunCard(run: OverviewRunItem(
                    project: item.project, runID: item.runID, goal: nil,
                    status: DisplayStatus(raw: nil, known: false,
                                          display: "未知状态"),
                    startedAt: nil, progress: nil, consumption: nil,
                    dataAsOf: nil), attention: [item])
                order.append(key)
            }
        }

        let attentionIds = Set(byRun.filter { !$0.value.attention.isEmpty }.map(\.key))
        let attentionCards = order.filter { attentionIds.contains($0) }
            .compactMap { byRun[$0] }
            .sorted { ($0.run.project, $0.run.runID) < ($1.run.project, $1.run.runID) }
        let activeCards = order
            .filter { activeIds.contains($0) && !attentionIds.contains($0) }
            .compactMap { byRun[$0] }
        let recentCards = order
            .filter { recentIds.contains($0) && !attentionIds.contains($0) }
            .compactMap { byRun[$0] }

        var health: [String: DataHealthBlock] = [:]
        for row in envelope.projectHealth {
            health[row.project] = row.dataHealth
        }
        return PanelModel(needsAttention: attentionCards, active: activeCards,
                          recentCompleted: recentCards,
                          sectionOrder: [.needsAttention, .active, .recentCompleted],
                          healthByProject: health)
    }

    /// The engine's own data-health classification for a project, if
    /// the overview carried one.
    public func health(for project: String) -> DataHealthBlock? {
        healthByProject[project]
    }
}
