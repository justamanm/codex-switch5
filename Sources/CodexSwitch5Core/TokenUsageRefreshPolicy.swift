import Foundation

/// Token 统计与网络额度刷新互斥：网络自动刷新关闭时，才启用低频本地扫描。
public enum TokenUsageRefreshPolicy {
    public static func localScanInterval(automaticRefreshEnabled: Bool) -> TimeInterval? {
        automaticRefreshEnabled ? nil : 5 * 60
    }
}
