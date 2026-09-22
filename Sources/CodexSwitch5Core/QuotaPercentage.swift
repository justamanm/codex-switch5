import Foundation

public enum QuotaPercentage {
    public static func remaining(fromUsedPercent usedPercent: Double) -> Int {
        max(0, min(100, Int((100 - usedPercent).rounded(.down))))
    }
}
