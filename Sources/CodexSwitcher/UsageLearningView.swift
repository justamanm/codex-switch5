import CodexSwitcherCore
import SwiftUI

struct UsageLearningView: View {
    @EnvironmentObject private var model: AppModel
    private let accent = Color(red: 0.31, green: 0.57, blue: 0.39)

    private var summary: UsageLearningSummary { model.usageLearning }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.text("使用习惯")).font(.title2.bold())
                        Text(model.text("Token 来自本机 Codex 记录，额度来自本应用刷新"))
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(model.text("统计范围"), selection: Binding(
                        get: { model.usageLearningPeriod },
                        set: { model.updateUsageLearning(period: $0) }
                    )) {
                        Text(model.text("本周")).tag(UsageLearningPeriod.currentWeek)
                        Text(model.text("本月")).tag(UsageLearningPeriod.currentMonth)
                        Text(model.text("最近 30 天")).tag(UsageLearningPeriod.lastThirtyDays)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                }
                if let error = model.usageHistoryError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
                overview
                if summary.sampleCount == 0 && summary.conversationCount == 0 {
                    ContentUnavailableView {
                        Label(model.text("等待首次查询"), systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text(model.text("刷新账号额度后开始积累记录。启用自动查询可以持续采样，旧缓存不会补算成历史。"))
                    }
                } else {
                    hourlyDistribution
                    overallSummary
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.text("这些记录能说明什么")).font(.headline)
                    Text(model.text("柱高表示所选时间内该小时使用的 Token 总量；柱顶数字表示其中有用量的天数。"))
                    Text(model.text("速度包含查询之间的空闲时间，不能直接当作实际工作速度；其他设备的消耗也可能计入。"))
                    Text(model.text("超过 30 分钟的查询间隔、查询失败、跨窗口和额度回升不用于估算。百分比取整会使短期估计波动。"))
                    Text(model.text("实际等待时间尚无法确定，不会把没有消耗自动记成休息，也不会据此改变账号切换。"))
                }
                .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .tint(accent)
        .onAppear { model.updateUsageLearning() }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.text(summary.consumptionDays < 3 ? "正在积累观察记录" : "已有使用观察，仍需持续校准"))
                .font(.headline)
            HStack(spacing: 16) {
                metric("对话次数", value: summary.conversationCount)
                metric("采样天数", value: summary.observedDays)
                metric("额度下降天数", value: summary.consumptionDays)
                metric("额度刷新失败次数", value: summary.failedQueries)
            }
            HStack {
                Text(model.text("已记录 %d 次成功切换", summary.successfulSwitches))
                Spacer()
                if let latest = summary.latestObservation {
                    Text(model.text("最近采样：%@", latest.formatted(date: .abbreviated, time: .shortened)))
                }
            }
            .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value.formatted()).font(.title2.monospacedDigit().bold())
            Text(model.text(title)).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hourlyDistribution: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.text("各时段 Token 用量")).font(.headline)
            let peak = max(summary.hourlyTokenUsage.max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = summary.hourlyConsumptionDays[hour]
                    let tokens = summary.hourlyTokenUsage[hour]
                    VStack(spacing: 5) {
                        Text(count == 0 ? "" : "\(count)")
                            .font(.system(size: 13).monospacedDigit())
                        RoundedRectangle(cornerRadius: 3)
                            .fill(tokens > 0 ? accent : Color.secondary.opacity(0.12))
                            .frame(height: max(3, 86 * Double(tokens) / Double(peak)))
                        Text(hour.isMultiple(of: 3) ? String(format: "%02d", hour) : " ")
                            .font(.system(size: 13).monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    .help(model.text("%d 点：%d 天有用量，共 %@ Token", hour, count, formattedTokens(tokens)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.text("%d 点：%d 天有用量，共 %@ Token", hour, count, formattedTokens(tokens)))
                }
            }
            .frame(height: 125, alignment: .bottom)
            Text(model.text("按本机时区汇总所选时间内的对话用量，单位为百万 Token。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Text(model.usageLearningPeriodText())
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private var overallSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.text("总体额度观察")).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.text("合并所有账号的数据"))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(model.text("额度记录 %d 次", summary.sampleCount))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                LabeledContent(model.text("每小时平均使用的 5h 额度")) {
                    if let rate = summary.observedPercentPerHour {
                        Text(model.text("约 %.1f%%", rate))
                    } else { Text(model.text("数据不足")) }
                }
                LabeledContent(model.text("5h 额度对应周额度")) {
                    if let ratio = summary.weeklyPercentPerFullWindow {
                        Text(model.text("约 %.1f%%", ratio))
                    } else { Text(model.text("数据不足")) }
                }
                if summary.excludedIntervals > 0 {
                    Text(model.text("另有 %d 组额度记录因重置、回升或相隔过久，未用于计算", summary.excludedIntervals))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 15))
            .padding(14)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func formattedTokens(_ value: Int) -> String {
        String(format: "%.2fM", Double(value) / 1_000_000)
    }
}
