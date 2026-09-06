import Foundation

public struct WeeklyQuotaProjection: Codable, Equatable, Sendable {
    public let estimatedFullUSD: Double
    public let observedUsedPercent: Int
    public let observedUSD: Double
    public let isPartial: Bool
    public let updatedAt: Date
}

public final class WeeklyQuotaProjectionStore: @unchecked Sendable {
    private struct Sample: Codable {
        let remainingPercent: Int
        let estimatedUSD: Double
        let unpricedEvents: Int
    }

    private struct AccountState: Codable {
        var resetAt: String
        var start: Sample?
        /// 兼容旧版文件；旧字段只用于成功解码，不再参与计算。
        var sample: Sample?
        var observedUsedPercent: Int
        var observedUSD: Double
        var isPartial: Bool
        var projection: WeeklyQuotaProjection?
    }

    private let url: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(url: URL) {
        self.url = url
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func begin(
        account: String,
        resetAt: String,
        remainingPercent: Int,
        estimatedUSD: Double,
        unpricedEvents: Int
    ) throws {
        var states = loadStates()
        states[account] = AccountState(
            resetAt: resetAt,
            start: Sample(
                remainingPercent: remainingPercent,
                estimatedUSD: estimatedUSD,
                unpricedEvents: unpricedEvents
            ),
            sample: nil,
            observedUsedPercent: 0,
            observedUSD: 0,
            isPartial: false,
            projection: nil
        )
        try save(states)
    }

    public func beginIfNeeded(
        account: String,
        resetAt: String,
        remainingPercent: Int,
        estimatedUSD: Double,
        unpricedEvents: Int
    ) throws {
        let state = loadStates()[account]
        guard (state.map { !Self.sameQuotaCycle($0.resetAt, resetAt) } ?? true) || state?.start == nil else { return }
        try begin(
            account: account,
            resetAt: resetAt,
            remainingPercent: remainingPercent,
            estimatedUSD: estimatedUSD,
            unpricedEvents: unpricedEvents
        )
    }

    @discardableResult
    public func finish(
        account: String,
        resetAt: String,
        remainingPercent: Int,
        estimatedUSD: Double,
        unpricedEvents: Int,
        at date: Date = Date()
    ) throws -> WeeklyQuotaProjection? {
        try observe(account: account, resetAt: resetAt, remainingPercent: remainingPercent,
                    estimatedUSD: estimatedUSD, unpricedEvents: unpricedEvents, at: date)
    }

    @discardableResult
    public func observe(
        account: String,
        resetAt: String,
        remainingPercent: Int,
        estimatedUSD: Double,
        unpricedEvents: Int,
        at date: Date = Date()
    ) throws -> WeeklyQuotaProjection? {
        var states = loadStates()
        guard var state = states[account], Self.sameQuotaCycle(state.resetAt, resetAt), let start = state.start else {
            return nil
        }
        let usedPercent = start.remainingPercent - remainingPercent
        let usedUSD = estimatedUSD - start.estimatedUSD
        if usedPercent > 0 {
            state.observedUsedPercent = usedPercent
            state.observedUSD = max(0, usedUSD)
            state.isPartial = usedUSD <= 0 || unpricedEvents > start.unpricedEvents
            if usedUSD > 0 {
                state.projection = WeeklyQuotaProjection(
                    estimatedFullUSD: usedUSD / Double(usedPercent) * 100,
                    observedUsedPercent: usedPercent,
                    observedUSD: usedUSD,
                    isPartial: state.isPartial,
                    updatedAt: date
                )
            } else {
                state.projection = nil
            }
        } else if usedPercent < 0 {
            state.start = Sample(
                remainingPercent: remainingPercent,
                estimatedUSD: estimatedUSD,
                unpricedEvents: unpricedEvents
            )
            state.observedUsedPercent = 0
            state.observedUSD = 0
            state.isPartial = false
            state.projection = nil
        }
        states[account] = state
        try save(states)
        return state.projection
    }

    public func projections() -> [String: WeeklyQuotaProjection] {
        loadStates().compactMapValues(\.projection)
    }

    /// 服务端偶尔会让同一重置时间前后相差数秒；五分钟内仍视为同一周期。
    private static func sameQuotaCycle(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let formatter = ISO8601DateFormatter()
        guard let leftDate = formatter.date(from: left), let rightDate = formatter.date(from: right) else { return false }
        return abs(leftDate.timeIntervalSince(rightDate)) <= 5 * 60
    }

    private func loadStates() -> [String: AccountState] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? decoder.decode([String: AccountState].self, from: data)) ?? [:]
    }

    private func save(_ states: [String: AccountState]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(states).write(to: url, options: .atomic)
    }
}
