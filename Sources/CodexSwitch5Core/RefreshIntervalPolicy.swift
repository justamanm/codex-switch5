import Foundation

public enum RefreshIntervalPolicy {
    public static let minimumSeconds = 60

    /// 旧开发版允许秒级查询；首版统一换算为不少于一分钟。
    public static func normalized(value: Int, unit: String) -> (value: Int, unit: String, seconds: Int) {
        if unit == "seconds" {
            let minutes = max(1, Int(ceil(Double(max(1, value)) / 60.0)))
            return (minutes, "minutes", minutes * 60)
        }
        let minutes = max(1, value)
        return (minutes, "minutes", minutes * 60)
    }
}
