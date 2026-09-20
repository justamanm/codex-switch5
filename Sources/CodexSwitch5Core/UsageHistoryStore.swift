import Foundation

public struct QuotaObservation: Codable, Equatable, Sendable {
    public let account: String
    public let timestamp: Date
    public let fiveHourRemaining: Int
    public let fiveHourReset: Date?
    public let weeklyRemaining: Int
    public let weeklyReset: Date?
    public let resetCards: Int
    public let activeAccount: String?

    public init?(usage: AccountUsage, activeAccount: String?, calendar: Calendar = .current) {
        guard !usage.authInvalid,
              (0...100).contains(usage.fiveHourRemaining),
              (0...100).contains(usage.weeklyRemaining),
              let timestamp = Self.date(usage.notedAt) else { return nil }
        account = usage.name
        self.timestamp = timestamp
        fiveHourRemaining = usage.fiveHourRemaining
        fiveHourReset = AccountRecommender.resetDate(usage.fiveHourReset, calendar: calendar)
        weeklyRemaining = usage.weeklyRemaining
        weeklyReset = usage.weeklyResetAt.flatMap(Self.date)
        resetCards = usage.resetCards
        self.activeAccount = activeAccount
    }

    public static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
}

public enum UsageHistoryEvent: Codable, Equatable, Sendable {
    case observation(QuotaObservation)
    case queryFailed(account: String, timestamp: Date)
    case accountChanged(from: String, to: String, timestamp: Date, succeeded: Bool)
    case plannedBreak(start: Date, end: Date) // 仅用于兼容读取旧版本已经保存的记录。

    public var timestamp: Date {
        switch self {
        case .observation(let sample): sample.timestamp
        case .queryFailed(_, let timestamp): timestamp
        case .accountChanged(_, _, let timestamp, _): timestamp
        case .plannedBreak(let start, _): start
        }
    }
}

public enum UsageQueryHistory {
    /// 旧缓存或失败后的占位额度不能伪装成一次成功观察。
    public static func events(
        before: [AccountUsage], after: [AccountUsage], requested: Set<String>,
        startedAt: Date, finishedAt: Date, activeAccount: String?, calendar: Calendar = .current
    ) -> [UsageHistoryEvent] {
        let old = Dictionary(before.map { ($0.name, $0.notedAt) }, uniquingKeysWith: { _, last in last })
        let updated = Dictionary(after.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        return requested.sorted().map { name in
            if let usage = updated[name], usage.notedAt != old[name],
               let sample = QuotaObservation(usage: usage, activeAccount: activeAccount, calendar: calendar),
               sample.timestamp.timeIntervalSince1970 >= floor(startedAt.timeIntervalSince1970),
               sample.timestamp <= finishedAt {
                return .observation(sample)
            }
            return .queryFailed(account: name, timestamp: finishedAt)
        }
    }
}

/// 由应用主线程使用；历史保存在 SQLite，旧 JSONL 只导入一次。
public final class UsageHistoryStore: @unchecked Sendable {
    public let database: UsageDatabase
    private let legacyURL: URL?
    private let decoder = JSONDecoder()

    public init(url: URL) {
        database = UsageDatabase(url: url.deletingLastPathComponent().appendingPathComponent("codex_switch5.sqlite3"))
        legacyURL = url
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public init(database: UsageDatabase, legacyURL: URL? = nil) {
        self.database = database
        self.legacyURL = legacyURL
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func load() throws -> [UsageHistoryEvent] {
        try importLegacyIfNeeded()
        try performDailyRetentionIfNeeded()
        return try database.usageHistory()
    }

    public func load(from start: Date) throws -> [UsageHistoryEvent] {
        try importLegacyIfNeeded()
        try performDailyRetentionIfNeeded()
        return try database.usageHistory(from: start)
    }

    @discardableResult
    public func append(_ events: [UsageHistoryEvent]) throws -> [UsageHistoryEvent] {
        try save(events)
        let recentStart = Calendar.current.date(byAdding: .day, value: -32, to: Date()) ?? .distantPast
        return try database.usageHistory(from: recentStart)
    }

    public func save(_ events: [UsageHistoryEvent]) throws {
        try importLegacyIfNeeded()
        try database.appendUsageHistory(events)
        try performDailyRetentionIfNeeded()
    }

    public func latestObservation(account: String) throws -> QuotaObservation? {
        try importLegacyIfNeeded()
        return try database.latestObservation(account: account)
    }

    private func importLegacyIfNeeded() throws {
        try database.prepare()
        guard try database.metadataValue(for: "legacy_usage_history_imported") == nil else { return }
        guard let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) else {
            try database.setMetadataValue("1", for: "legacy_usage_history_imported")
            return
        }
        let data = try Data(contentsOf: legacyURL)
        // 本机导入失败时保留原文件，不写入导入完成标志。
        if !data.isEmpty && data.last != 10 { throw CocoaError(.fileReadCorruptFile) }
        let records = try data.split(separator: 10).map {
            try decoder.decode(UsageHistoryEvent.self, from: Data($0))
        }
        try database.importLegacyUsageHistory(records)
    }

    private func performDailyRetentionIfNeeded(now: Date = Date()) throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let key = String(Int64(today.timeIntervalSince1970))
        guard try database.metadataValue(for: "last_usage_retention_day") != key else { return }
        guard let cutoff = calendar.date(byAdding: .day, value: -90, to: today) else { return }
        try database.performUsageHistoryRetention(before: cutoff, calendar: calendar)
        try database.setMetadataValue(key, for: "last_usage_retention_day")
    }
}
