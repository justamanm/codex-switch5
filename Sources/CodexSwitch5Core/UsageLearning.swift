import Foundation

public struct AccountLearningSummary: Identifiable, Sendable {
    public let account: String
    public var id: String { account }
    public var samples = 0
    public var intervals = 0
    public var excludedIntervals = 0
    public var observedSeconds: TimeInterval = 0
    public var fiveHourDrop = 0
    public var pairedFiveHourDrop = 0
    public var pairedWeeklyDrop = 0
    public var conversationCount = 0

    /// 包含查询之间的空闲时间，不代表实际工作速度。
    public var observedPercentPerHour: Double? {
        guard intervals >= 3, fiveHourDrop >= 5, observedSeconds > 0 else { return nil }
        return Double(fiveHourDrop) / observedSeconds * 3600
    }

    public var weeklyPercentPerFullWindow: Double? {
        guard pairedFiveHourDrop >= 20, pairedWeeklyDrop >= 2 else { return nil }
        return Double(pairedWeeklyDrop) / Double(pairedFiveHourDrop) * 100
    }
}

public struct UsageLearningSummary: Sendable {
    public var sampleCount = 0
    public var conversationCount = 0
    public var observedDays = 0
    public var consumptionDays = 0
    public var failedQueries = 0
    public var successfulSwitches = 0
    public var hourlyConsumptionDays = Array(repeating: 0, count: 24)
    public var hourlyTokenUsage = Array(repeating: 0, count: 24)
    public var accounts: [AccountLearningSummary] = []
    public var validIntervals = 0
    public var excludedIntervals = 0
    public var observedSeconds: TimeInterval = 0
    public var fiveHourDrop = 0
    public var pairedFiveHourDrop = 0
    public var pairedWeeklyDrop = 0
    public var latestObservation: Date?

    public var observedPercentPerHour: Double? {
        guard validIntervals >= 3, fiveHourDrop >= 5, observedSeconds > 0 else { return nil }
        return Double(fiveHourDrop) / observedSeconds * 3600
    }

    public var weeklyPercentPerFullWindow: Double? {
        guard pairedFiveHourDrop >= 20, pairedWeeklyDrop >= 2 else { return nil }
        return Double(pairedWeeklyDrop) / Double(pairedFiveHourDrop) * 100
    }

    public init() {}
}

public enum UsageLearningPeriod: String, CaseIterable, Sendable {
    case currentWeek
    case currentMonth
    case lastThirtyDays
}

public enum UsageLearning {
    public static let maximumInterval: TimeInterval = 30 * 60

    public static func summarize(
        _ events: [UsageHistoryEvent], tokenEvents: [TokenUsageEvent] = [],
        period: UsageLearningPeriod = .lastThirtyDays,
        now: Date = Date(), calendar: Calendar = .current
    ) -> UsageLearningSummary {
        let start: Date
        switch period {
        case .currentWeek:
            var mondayCalendar = calendar
            mondayCalendar.firstWeekday = 2
            mondayCalendar.minimumDaysInFirstWeek = 4
            start = mondayCalendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
        case .currentMonth:
            start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        case .lastThirtyDays:
            start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        }
        let recent = events.filter { $0.timestamp >= start && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        var result = UsageLearningSummary()
        var last: [String: QuotaObservation] = [:]
        var accounts: [String: AccountLearningSummary] = [:]
        var observedDays: Set<Date> = []
        var consumptionDays: Set<Date> = []
        var hours = Array(repeating: Set<Date>(), count: 24)

        for event in tokenEvents where event.timestamp >= start && event.timestamp <= now {
            guard event.model.caseInsensitiveCompare("codex-auto-review") != .orderedSame else { continue }
            let amount = max(0, event.input) + max(0, event.output)
            guard amount > 0 else { continue }
            let hour = calendar.component(.hour, from: event.timestamp)
            result.hourlyTokenUsage[hour] += amount
            hours[hour].insert(calendar.startOfDay(for: event.timestamp))
            result.conversationCount += 1
            var stats = accounts[event.account] ?? AccountLearningSummary(account: event.account)
            stats.conversationCount += 1
            accounts[event.account] = stats
        }

        for event in recent {
            switch event {
            case .plannedBreak:
                break // 旧版本记录，不属于实际使用情况。
            case .queryFailed(let account, _):
                result.failedQueries += 1
                last.removeValue(forKey: account)
            case .accountChanged(let from, let to, _, let succeeded):
                if succeeded && from != to { result.successfulSwitches += 1 }
            case .observation(let sample):
                var stats = accounts[sample.account] ?? AccountLearningSummary(account: sample.account)
                // 文件内重复或乱序的旧查询记录不能贡献消耗或扩大样本数量。
                if let previous = last[sample.account], sample.timestamp <= previous.timestamp { continue }
                stats.samples += 1
                result.sampleCount += 1
                result.latestObservation = sample.timestamp
                observedDays.insert(calendar.startOfDay(for: sample.timestamp))
                defer {
                    last[sample.account] = sample
                    accounts[sample.account] = stats
                }
                guard let previous = last[sample.account] else { continue }
                let duration = sample.timestamp.timeIntervalSince(previous.timestamp)
                let drop = previous.fiveHourRemaining - sample.fiveHourRemaining
                let weeklyDrop = previous.weeklyRemaining - sample.weeklyRemaining
                guard duration > 0, duration <= maximumInterval,
                      drop >= 0, weeklyDrop >= 0,
                      sample.resetCards >= previous.resetCards,
                      sameWindow(previous.fiveHourReset, sample.fiveHourReset, through: sample.timestamp) else {
                    stats.excludedIntervals += 1
                    continue
                }
                stats.intervals += 1
                stats.observedSeconds += duration
                stats.fiveHourDrop += drop
                if sameWindow(previous.weeklyReset, sample.weeklyReset, through: sample.timestamp) {
                    stats.pairedFiveHourDrop += drop
                    stats.pairedWeeklyDrop += weeklyDrop
                }
                guard drop > 0 else { continue }
                // 只能定位到两个查询之间；跨小时分段标记，不能声称整个时段都在工作。
                var cursor = previous.timestamp
                while cursor < sample.timestamp {
                    let day = calendar.startOfDay(for: cursor)
                    consumptionDays.insert(day)
                    guard let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end,
                          hourEnd > cursor else { break }
                    cursor = min(hourEnd, sample.timestamp)
                }
            }
        }
        result.observedDays = observedDays.count
        result.consumptionDays = consumptionDays.count
        result.hourlyConsumptionDays = hours.map(\.count)
        result.accounts = accounts.values.sorted { $0.account.localizedStandardCompare($1.account) == .orderedAscending }
        for stats in accounts.values {
            result.validIntervals += stats.intervals
            result.excludedIntervals += stats.excludedIntervals
            result.observedSeconds += stats.observedSeconds
            result.fiveHourDrop += stats.fiveHourDrop
            result.pairedFiveHourDrop += stats.pairedFiveHourDrop
            result.pairedWeeklyDrop += stats.pairedWeeklyDrop
        }
        return result
    }

    private static func sameWindow(_ first: Date?, _ second: Date?, through date: Date) -> Bool {
        guard let first, let second else { return false }
        return abs(first.timeIntervalSince(second)) <= 120 && min(first, second) > date
    }
}
