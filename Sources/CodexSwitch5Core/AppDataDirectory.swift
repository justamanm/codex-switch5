import Foundation

/// Switch5 私有数据的位置；Codex CLI 自己读取的凭据和会话不在此处。
public enum AppDataDirectory {
    public static let legacyFileNames = [
        "codex_switch5_usage_history.jsonl",
        "codex_switch5_token_usage.json",
        "codex_switch5_token_usage.pre-timeline-backup.json",
        "codex_switch5_switch_history.json",
        "codex_switch5_weekly_quota_projection.json",
        "codex_switch5_account_groups.json",
        "account_aliases.json",
        "account_usage.json",
        ".active-auth-profile",
        ".codex-switch5-addition-pending.json",
        ".codex-switch5-reauthentication-pending.json"
    ]

    /// 只补充新偏好域尚未保存的键，保留旧域作为兼容备份。
    public static func migratePreferences(defaults: UserDefaults = .standard) {
        let old = defaults.persistentDomain(forName: "local.justaman.codex-switcher") ?? [:]
        var current = defaults.persistentDomain(forName: "local.justaman.codex-switch5") ?? [:]
        // 一次性迁移，避免用户清除某项新设置后旧值再次出现。
        guard current["didMigrateSwitch5Name"] == nil else { return }
        for (key, value) in old where current[key] == nil { current[key] = value }
        current["didMigrateSwitch5Name"] = true
        defaults.setPersistentDomain(current, forName: "local.justaman.codex-switch5")
    }

    public static func url(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Switch5", isDirectory: true)
    }

    /// 首次启动时只移动尚未迁移的私有文件；目标已存在时保留旧文件，避免覆盖新数据。
    @discardableResult
    public static func migrateLegacyFiles(
        from legacyDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> [String] {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        var moved: [String] = []
        for name in legacyFileNames {
            let oldName = name.replacingOccurrences(of: "codex_switch5", with: "codex_switcher")
                .replacingOccurrences(of: "codex-switch5", with: "codex-switcher")
            let destination = destinationDirectory.appendingPathComponent(name)
            let candidates = [destinationDirectory.appendingPathComponent(oldName),
                              legacyDirectory.appendingPathComponent(name),
                              legacyDirectory.appendingPathComponent(oldName)]
            for source in candidates where source != destination {
                guard fileManager.fileExists(atPath: source.path),
                      !fileManager.fileExists(atPath: destination.path) else { continue }
                try fileManager.moveItem(at: source, to: destination)
                moved.append(name)
            }
        }
        return moved
    }
}
