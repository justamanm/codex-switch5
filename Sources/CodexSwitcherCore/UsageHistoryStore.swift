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

/// 由应用主线程使用；只追加，不覆盖已有历史，也不保存认证信息或命令输出。
public final class UsageHistoryStore {
    private let url: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var cached: [UsageHistoryEvent]?
    private var observedKeys: Set<String> = []

    public init(url: URL) {
        self.url = url
        decoder.dateDecodingStrategy = .millisecondsSince1970
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
    }

    public func load() throws -> [UsageHistoryEvent] {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cached = []
            return []
        }
        let data = try Data(contentsOf: url)
        // 中断写入或损坏时停止追加，保留原文件供恢复；不静默丢失历史。
        if !data.isEmpty && data.last != 10 { throw CocoaError(.fileReadCorruptFile) }
        let records = try data.split(separator: 10).map { try decoder.decode(UsageHistoryEvent.self, from: Data($0)) }
        observedKeys = Set(records.compactMap(Self.observationKey))
        cached = records
        return records
    }

    @discardableResult
    public func append(_ events: [UsageHistoryEvent]) throws -> [UsageHistoryEvent] {
        var records = try load()
        var keys = observedKeys
        let additions = events.filter { event in
            guard let key = Self.observationKey(event) else { return true }
            return keys.insert(key).inserted
        }
        guard !additions.isEmpty else { return records }
        var data = Data()
        for event in additions {
            data.append(try encoder.encode(event))
            data.append(10)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                cached = nil
                throw error
            }
        }
        records.append(contentsOf: additions)
        observedKeys = keys
        cached = records
        return records
    }

    private static func observationKey(_ event: UsageHistoryEvent) -> String? {
        guard case .observation(let sample) = event else { return nil }
        return "\(sample.account.utf8.count):\(sample.account):\(sample.timestamp.timeIntervalSince1970)"
    }
}
