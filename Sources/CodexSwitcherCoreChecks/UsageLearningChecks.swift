import CodexSwitcherCore
import Foundation

func checkUsageLearning() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let base = QuotaObservation.date("2026-09-08T12:00:00Z")!
    let formatter = ISO8601DateFormatter()
    func usage(_ name: String = "a", minute: Int, five: Int, weekly: Int = 80,
               reset: String = "2026-09-08 17:00", cards: Int = 1, invalid: Bool = false) -> AccountUsage {
        AccountUsage(name: name, fiveHourRemaining: five, fiveHourReset: reset,
                     weeklyRemaining: weekly, weeklyReset: "9.12", weeklyResetAt: "2026-09-12T12:00:00Z",
                     resetCards: cards, authInvalid: invalid,
                     notedAt: formatter.string(from: base.addingTimeInterval(Double(minute) * 60)))
    }
    func event(_ value: AccountUsage) -> UsageHistoryEvent {
        .observation(QuotaObservation(usage: value, activeAccount: value.name, calendar: calendar)!)
    }
    func summary(_ values: [UsageHistoryEvent]) -> UsageLearningSummary {
        UsageLearning.summarize(values, now: base.addingTimeInterval(8 * 3600), calendar: calendar)
    }
    let samples = [event(usage(minute: 0, five: 100, weekly: 100)),
                   event(usage(minute: 10, five: 90, weekly: 99)),
                   event(usage(minute: 20, five: 90, weekly: 99)),
                   event(usage(minute: 40, five: 80, weekly: 97))]
    let tokenEvents = [
        TokenUsageEvent(id: "1", account: "a", timestamp: base, model: "gpt-5.6-sol", input: 1_000_000, cachedInput: 0, cacheWriteInput: 0, output: 20_000, reasoningOutput: 0),
        TokenUsageEvent(id: "2", account: "a", timestamp: base.addingTimeInterval(3600), model: "gpt-5.6-sol", input: 200_000, cachedInput: 0, cacheWriteInput: 0, output: 10_000, reasoningOutput: 0),
        TokenUsageEvent(id: "3", account: "a", timestamp: base.addingTimeInterval(3600), model: "codex-auto-review", input: 9_000_000, cachedInput: 0, cacheWriteInput: 0, output: 0, reasoningOutput: 0)
    ]
    let learned = UsageLearning.summarize(samples, tokenEvents: tokenEvents, now: base.addingTimeInterval(8 * 3600), calendar: calendar)
    precondition(learned.sampleCount == 4 && learned.consumptionDays == 1)
    precondition(learned.accounts[0].observedPercentPerHour == 30, "应按真实的40分钟计算，不能按固定查询间隔计算")
    precondition(learned.accounts[0].weeklyPercentPerFullWindow == 15, "应由实测下降比例计算")
    precondition(learned.observedPercentPerHour == 30 && learned.weeklyPercentPerFullWindow == 15,
                 "总体比例应合并全部账号的有效下降量后计算")
    precondition(learned.hourlyTokenUsage[12] == 1_020_000 && learned.hourlyTokenUsage[13] == 210_000)
    precondition(learned.hourlyConsumptionDays[12] == 1 && learned.conversationCount == 2)

    let switched = summary([event(usage(minute: 0, five: 100)), event(usage("b", minute: 10, five: 10)),
                            .accountChanged(from: "a", to: "b", timestamp: base, succeeded: true)])
    precondition(switched.accounts.allSatisfy { $0.fiveHourDrop == 0 } && switched.successfulSwitches == 1)
    let unchanged = summary([.accountChanged(from: "a", to: "a", timestamp: base, succeeded: true),
                             .accountChanged(from: "a", to: "b", timestamp: base, succeeded: false)])
    precondition(unchanged.successfulSwitches == 0, "同账号重新登录和失败尝试不能计作成功切换")
    let failed = summary([samples[0], .queryFailed(account: "a", timestamp: base.addingTimeInterval(60)), samples[1]])
    precondition(failed.failedQueries == 1 && failed.accounts[0].intervals == 0, "查询失败应打断连续观察")
    for changed in [usage(minute: 10, five: 80, reset: "2026-09-08 22:00"),
                    usage(minute: 10, five: 100), usage(minute: 10, five: 70, cards: 0),
                    usage(minute: 40, five: 70)] {
        let excluded = summary([event(usage(minute: 0, five: 90)), event(changed)])
        precondition(excluded.accounts[0].intervals == 0, "重置、回升、重置卡与长间隔不得计入消耗")
    }
    let idle = summary([event(usage(minute: 0, five: 90)), event(usage(minute: 10, five: 90))])
    precondition(idle.consumptionDays == 0 && idle.accounts[0].observedPercentPerHour == nil)
    let crossing = summary([event(usage(minute: 50, five: 90)), event(usage(minute: 70, five: 80))])
    precondition(crossing.consumptionDays == 1, "额度下降仍应计入有消耗的日期")
    precondition(summary(Array(samples.reversed()) + [samples[1]]).sampleCount == 4)

    let older = event(usage(minute: -8 * 24 * 60, five: 50))
    let thisWeek = UsageLearning.summarize([older] + samples, period: .currentWeek,
        now: base.addingTimeInterval(8 * 3600), calendar: calendar)
    let lastThirtyDays = UsageLearning.summarize([older] + samples, period: .lastThirtyDays,
        now: base.addingTimeInterval(8 * 3600), calendar: calendar)
    precondition(thisWeek.sampleCount == 4 && lastThirtyDays.sampleCount == 5,
                 "本周与最近30天必须使用不同的时间边界")
    let sunday = event(usage(minute: -2 * 24 * 60, five: 60))
    let mondayWeek = UsageLearning.summarize([sunday] + samples, period: .currentWeek,
        now: base.addingTimeInterval(8 * 3600), calendar: calendar)
    precondition(mondayWeek.sampleCount == 4, "本周必须固定从周一开始，不能受系统地区的周日起始设置影响")

    let fresh = usage(minute: 10, five: 80)
    let batch = UsageQueryHistory.events(before: [usage("b", minute: 0, five: 40)],
        after: [fresh, usage("b", minute: 0, five: 40), usage("c", minute: 10, five: 0, invalid: true)],
        requested: ["a", "b", "c"], startedAt: base.addingTimeInterval(540),
        finishedAt: base.addingTimeInterval(660), activeAccount: "a", calendar: calendar)
    precondition(summary(batch).sampleCount == 1 && summary(batch).failedQueries == 2, "旧缓存和登录失效不可作为成功查询记录")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-learning-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("history.jsonl")
    let store = UsageHistoryStore(url: url)
    let stored = try store.append(samples + samples)
    precondition(stored.count == 4, "重复读取不得制造样本")
    let loaded = try UsageHistoryStore(url: url).load()
    precondition(loaded == samples, "历史应在重启后保留账号和时间")
    let damagedURL = directory.appendingPathComponent("damaged.jsonl")
    let damaged = Data("{broken".utf8)
    try damaged.write(to: damagedURL)
    do {
        _ = try UsageHistoryStore(url: damagedURL).append(samples)
        preconditionFailure("历史损坏时必须停止追加")
    } catch {}
    let preserved = try Data(contentsOf: damagedURL)
    precondition(preserved == damaged, "损坏的原始历史不得覆盖")
    print("使用习惯检查通过：真实间隔、取整、跨账号、重置、失败、长间隔、小时分布、重复记录、部分失败、重启与损坏保护。")
}
