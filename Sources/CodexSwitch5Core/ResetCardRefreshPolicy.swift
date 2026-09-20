import Foundation

public struct ResetCardRefreshState: Equatable, Sendable {
    public let count: Int
    public let expirations: [String]

    public init(count: Int, expirations: [String]) {
        self.count = count
        self.expirations = expirations
    }
}

/// 只有成功取得的重置卡详情或明确的零数量，才能覆盖已经保存的到期时间。
public enum ResetCardRefreshPolicy {
    public static func resolve(
        fallbackCount: Int,
        refreshedCount: Int?,
        refreshedExpirations: [String]?,
        previousExpirations: [String]
    ) -> ResetCardRefreshState {
        let fallbackCount = max(0, fallbackCount)
        guard fallbackCount > 0 else {
            return ResetCardRefreshState(count: 0, expirations: [])
        }
        if let refreshedCount {
            let count = max(0, refreshedCount)
            let expirations = Array((refreshedExpirations ?? []).prefix(count))
            return ResetCardRefreshState(count: count, expirations: expirations)
        }
        return ResetCardRefreshState(
            count: fallbackCount,
            expirations: Array(previousExpirations.prefix(fallbackCount))
        )
    }
}
