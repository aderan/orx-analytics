import Foundation

/// User-facing runtime preferences (design §8/§9).
///
/// Every default is the conservative choice:
/// - notifications OFF — system permission is requested only after the
///   user opts in (design §4: 通知默认关闭，用户开启后再申请系统权限);
/// - no data-directory override — the app shares the existing analytics
///   data-dir with the CLI instead of keeping a second copy (design §8);
/// - panel-open refresh at ~5s, the design's tier for an open panel.
public struct AppSettings: Equatable {
    public static let defaultPanelRefreshInterval: TimeInterval = 5

    public var notificationsEnabled: Bool
    /// Explicit data-directory choice (设置页显式选择); nil = the shared
    /// default resolution (ORX_ANALYTICS_HOME env, else ~/.orx-analytics).
    /// Applies on the next app launch — changing it never moves data.
    public var dataDirectoryOverride: String?
    /// Panel-open refresh tier in seconds (design §8: 面板或详情打开 ~5s).
    public var panelRefreshInterval: TimeInterval

    public static let `default` = AppSettings(notificationsEnabled: false,
                                              dataDirectoryOverride: nil,
                                              panelRefreshInterval: defaultPanelRefreshInterval)

    public init(notificationsEnabled: Bool = false,
                dataDirectoryOverride: String? = nil,
                panelRefreshInterval: TimeInterval = AppSettings.defaultPanelRefreshInterval) {
        self.notificationsEnabled = notificationsEnabled
        self.dataDirectoryOverride = dataDirectoryOverride
        self.panelRefreshInterval = panelRefreshInterval
    }

    /// The engine socket path honoring the resolution order: explicit
    /// user override > ORX_ANALYTICS_HOME environment > default home.
    public func resolvedSocketPath(environment: [String: String] =
                                    ProcessInfo.processInfo.environment) -> String {
        if let dir = dataDirectoryOverride, !dir.isEmpty {
            return dir + "/engine.sock"
        }
        return EngineSocketClient.defaultSocketPath(environment: environment)
    }

    /// The data directory itself (for display in settings).
    public func resolvedDataDirectory(environment: [String: String] =
                                        ProcessInfo.processInfo.environment) -> String {
        let socket = resolvedSocketPath(environment: environment)
        return (socket as NSString).deletingLastPathComponent
    }
}

/// Persistence surface for settings — injectable so tests (and the
/// smoke self-check) never touch the real user defaults domain.
public protocol AppSettingsStore: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// UserDefaults-backed store. Unreadable/corrupt values fall back to the
/// conservative default rather than crashing or silently enabling
/// anything.
public final class UserDefaultsAppSettingsStore: AppSettingsStore {
    private static let notificationsKey = "notifications.enabled"
    private static let dataDirectoryKey = "data.directory.override"
    private static let intervalKey = "panel.refresh.interval"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        // bool(forKey:) is NO for a missing OR non-boolean value — an
        // unparseable value keeps notifications off, never on.
        let enabled = defaults.bool(forKey: Self.notificationsKey)
        let override = defaults.string(forKey: Self.dataDirectoryKey)
        let interval = defaults.double(forKey: Self.intervalKey)
        return AppSettings(notificationsEnabled: enabled,
                           dataDirectoryOverride: (override?.isEmpty ?? true) ? nil : override,
                           panelRefreshInterval: interval > 0
                               ? interval
                               : AppSettings.defaultPanelRefreshInterval)
    }

    public func save(_ settings: AppSettings) {
        defaults.set(settings.notificationsEnabled, forKey: Self.notificationsKey)
        defaults.set(settings.dataDirectoryOverride ?? "", forKey: Self.dataDirectoryKey)
        defaults.set(settings.panelRefreshInterval, forKey: Self.intervalKey)
    }
}

/// Non-persisting store for tests and the smoke self-check.
public final class InMemoryAppSettingsStore: AppSettingsStore {
    private var settings: AppSettings
    private let lock = NSLock()

    public init(initial: AppSettings = .default) {
        self.settings = initial
    }

    public func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
    }
}
