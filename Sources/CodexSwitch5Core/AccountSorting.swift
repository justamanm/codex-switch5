import Foundation

public enum AccountSortField: String, Codable, CaseIterable, Sendable { case weeklyReset, weeklyQuota, fiveHourReset, fiveHourQuota }
public enum AccountSortDirection: String, Codable, CaseIterable, Sendable { case ascending, descending }

public struct AccountSortRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var field: AccountSortField
    public var direction: AccountSortDirection
    public init(id: UUID = UUID(), field: AccountSortField, direction: AccountSortDirection = .ascending) {
        self.id = id; self.field = field; self.direction = direction
    }
}

public enum AccountSorter {
    public static func sorted(_ accounts: [AccountUsage], by rules: [AccountSortRule]) -> [AccountUsage] {
        guard !rules.isEmpty else { return accounts }
        let original = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($0.element.name, $0.offset) })
        return accounts.sorted { left, right in
            for rule in rules {
                let result = compare(left, right, field: rule.field)
                if result == 0 { continue }
                if result == 2 { return false }
                if result == -2 { return true }
                return rule.direction == .ascending ? result < 0 : result > 0
            }
            return original[left.name, default: .max] < original[right.name, default: .max]
        }
    }

    private static func compare(_ left: AccountUsage, _ right: AccountUsage, field: AccountSortField) -> Int {
        switch field {
        case .weeklyQuota: return compareNumbers(left.weeklyRemaining, right.weeklyRemaining)
        case .fiveHourQuota: return compareNumbers(left.fiveHourRemaining, right.fiveHourRemaining)
        case .weeklyReset: return compareDates(weeklyResetDate(left), weeklyResetDate(right))
        case .fiveHourReset: return compareDates(AccountRecommender.resetDate(left.fiveHourReset), AccountRecommender.resetDate(right.fiveHourReset))
        }
    }

    private static func compareNumbers(_ left: Int, _ right: Int) -> Int { left == right ? 0 : (left < right ? -1 : 1) }

    // 2/-2 represent missing values and keep them last regardless of direction.
    private static func compareDates(_ left: Date?, _ right: Date?) -> Int {
        switch (left, right) {
        case (nil, nil): return 0
        case (nil, _): return 2
        case (_, nil): return -2
        case let (left?, right?): return left == right ? 0 : (left < right ? -1 : 1)
        }
    }

    private static func weeklyResetDate(_ account: AccountUsage) -> Date? {
        if let value = account.weeklyResetAt, let date = ISO8601DateFormatter().date(from: value) { return date }
        return AccountRecommender.resetDate(account.weeklyReset)
    }
}
