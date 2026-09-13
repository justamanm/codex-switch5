import Foundation

/// Switch5 私有数据的位置；Codex CLI 自己读取的凭据和会话不在此处。
public enum AppDataDirectory {
    public static let legacyFileNames = [
        "codex_switcher_usage_history.jsonl",
        "codex_switcher_token_usage.json",
        "codex_switcher_token_usage.pre-timeline-backup.json",
        "codex_switcher_switch_history.json",
        "codex_switcher_weekly_quota_projection.json",
        "codex_switcher_account_groups.json",
        "account_aliases.json",
        "account_usage.json",
        ".active-auth-profile",
        ".codex-switcher-addition-pending.json",
        ".codex-switcher-reauthentication-pending.json"
    ]

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
            let source = legacyDirectory.appendingPathComponent(name)
            let destination = destinationDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.moveItem(at: source, to: destination)
            moved.append(name)
        }
        return moved
    }
}
