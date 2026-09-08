import CodexSwitcherCore
import Foundation

do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-switcher-group-check-\(UUID().uuidString)")
    let store = AccountGroupStore(url: directory.appendingPathComponent("groups.json"))
    var state = AccountGroupState()
    let group = try state.createGroup(named: " 工作 ")
    precondition((try? state.createGroup(named: "工作")) == nil, "重复分组名称没有被拒绝")
    state.assign(accounts: ["a", "b"], to: group.id)
    try store.save(state)
    var loaded = try store.load(validAccounts: ["a"])
    precondition(loaded.groups.first?.name == "工作", "分组名称没有正确保存")
    precondition(loaded.accountGroupIDs == ["a": group.id], "无效账号关系没有清理")
    loaded.deleteGroup(id: group.id)
    precondition(loaded.accountGroupIDs.isEmpty, "删除分组后账号关系仍然存在")
}

guard ClientAvailability(hasChatGPT: true, hasCodexCLI: true).accountLoginMethod == .chatGPT,
      ClientAvailability(hasChatGPT: true, hasCodexCLI: false).accountLoginMethod == .chatGPT,
      ClientAvailability(hasChatGPT: false, hasCodexCLI: true).accountLoginMethod == .codexCLI,
      !ClientAvailability(hasChatGPT: false, hasCodexCLI: false).canAddAccount else {
    fatalError("客户端安装状态判断失败")
}

let data = """
{
  "current": {"five_hour_remaining": 90, "five_hour_reset": "2030-01-01 09:00", "weekly_remaining": 90, "weekly_reset": "1.2", "reset_cards": 0, "noted_at": "2026-09-05T10:00:00+08:00"},
  "nearest": {"five_hour_remaining": 40, "five_hour_reset": "2030-01-01 10:00", "weekly_remaining": 60, "weekly_reset": "1.2", "reset_cards": 1, "noted_at": "2026-09-05T10:00:00+08:00"},
  "later": {"five_hour_remaining": 50, "five_hour_reset": "2030-01-01 11:00", "weekly_remaining": 70, "weekly_reset": "1.2", "noted_at": "2026-09-05T10:00:00+08:00"},
  "invalid": {"five_hour_remaining": 100, "five_hour_reset": "2030-01-01 08:30", "weekly_remaining": 100, "weekly_reset": "1.2", "auth_invalid": true, "noted_at": "2026-09-05T10:00:00+08:00"},
  "weeklyZero": {"five_hour_remaining": 80, "five_hour_reset": "2030-01-01 09:30", "weekly_remaining": 0, "weekly_reset": "1.2", "noted_at": "2026-09-05T10:00:00+08:00"}
}
""".data(using: .utf8)!

let accounts = try UsageStore.decode(data)
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
guard let now = AccountRecommender.resetDate("2030-01-01 08:00", calendar: calendar) else {
    fatalError("无法构造测试时间")
}
let result = AccountRecommender.next(
    from: accounts,
    currentAccount: "current",
    now: now,
    calendar: calendar
)
precondition(result?.name == "nearest", "没有选中最近的合格账号")
precondition(result?.resetCards == 1, "没有解析重置卡")
let rankedNames = AccountRecommender.ranked(
    from: accounts,
    currentAccount: "current",
    now: now,
    calendar: calendar
).map(\.name)
precondition(rankedNames == ["nearest", "later", "current", "weeklyZero", "invalid"], "登录失效账号没有排在底部")
precondition(accounts.first { $0.name == "invalid" }?.authInvalid == true, "没有解析登录失效状态")
print("账号数据解析与推荐算法检查通过。")

// 使用临时凭据验证恢复，不访问用户的真实账号目录。
func checkLoginCancellation() throws {
    func check(_ condition: Bool, _ message: String = "账号恢复结果不符合预期") { precondition(condition, message) }
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("login-check-\(UUID().uuidString)")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    let old = Data("old-credential".utf8)
    let new = Data("new-credential".utf8)
    let marker = Data("account old\n".utf8)
    func fixture(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        try old.write(to: dir.appendingPathComponent("auth.json"))
        try marker.write(to: dir.appendingPathComponent(".active-auth-profile"))
        return dir
    }
    func read(_ dir: URL, _ name: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(name))
    }
    let plain = try fixture("cancel-before-login")
    let first = try AccountLoginSession(directory: plain, account: "old")
    try first.cancel()
    check(try read(plain, "auth.json") == old)
    check(try read(plain, ".active-auth-profile") == marker)
    precondition(!files.fileExists(atPath: plain.appendingPathComponent("auth.json.old").path))
    try first.cancel()
    check(try read(plain, "auth.json") == old, "重复取消不得移动旧账号")

    let late = try fixture("cancel-after-login-write")
    let second = try AccountLoginSession(directory: late, account: "old")
    try new.write(to: late.appendingPathComponent("auth.json"))
    try second.cancel()
    check(try read(late, "auth.json") == old)
    check(!files.fileExists(atPath: late.appendingPathComponent("cancelled-logins").path), "取消不应保留新凭据")
    check(try read(late, ".active-auth-profile") == marker)

    let success = try fixture("completed-login")
    let third = try AccountLoginSession(directory: success, account: "old")
    try new.write(to: success.appendingPathComponent("auth.json"))
    try third.complete(account: "new")
    try third.cancel()
    check(try read(success, "auth.json") == new, "完成后的取消不得撤销新账号")
    check(try read(success, "auth.json.old") == old)
    check(try read(success, ".active-auth-profile") == Data("account new\n".utf8))

    let conflict = try fixture("existing-backup")
    try new.write(to: conflict.appendingPathComponent("auth.json.old"))
    do {
        _ = try AccountLoginSession(directory: conflict, account: "old")
        fatalError("已有备份时应拒绝覆盖")
    } catch { }
    check(try read(conflict, "auth.json") == old)
    check(try read(conflict, "auth.json.old") == new)

    let missing = try fixture("missing-backup")
    let fourth = try AccountLoginSession(directory: missing, account: "old")
    try files.moveItem(at: missing.appendingPathComponent("auth.json.old"),
                       to: missing.appendingPathComponent("saved-old"))
    try new.write(to: missing.appendingPathComponent("auth.json"))
    do {
        try fourth.cancel()
        fatalError("备份丢失时应停止恢复")
    } catch { }
    check(try read(missing, "auth.json") == new)
    precondition(fourth.isPending)
    try files.moveItem(at: missing.appendingPathComponent("saved-old"),
                       to: missing.appendingPathComponent("auth.json.old"))
    try fourth.cancel()
    check(try read(missing, "auth.json") == old, "恢复失败后应能重试")
    print("添加账号取消检查通过：未登录、丢弃晚到凭据、重复取消、成功登记、备份冲突、恢复重试。")
}
try checkLoginCancellation()

func checkReauthentication() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("reauth-check-\(UUID().uuidString)")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    let active = root.appendingPathComponent("auth.json")
    let target = root.appendingPathComponent("auth.json.expired")
    let marker = root.appendingPathComponent(".active-auth-profile")
    try Data("current".utf8).write(to: active)
    try Data("expired".utf8).write(to: target)
    try Data("account current\n".utf8).write(to: marker)
    let session = try AccountReauthenticationSession(directory: root, currentAccount: "current", targetAccount: "expired")
    try Data("renewed".utf8).write(to: active)
    try session.complete()
    let completedActive = try Data(contentsOf: active)
    let completedMarker = try Data(contentsOf: marker)
    precondition(completedActive == Data("renewed".utf8))
    precondition(!files.fileExists(atPath: target.path))
    precondition(completedMarker == Data("account expired\n".utf8))

    let cancelled = root.appendingPathComponent("cancelled")
    try files.createDirectory(at: cancelled, withIntermediateDirectories: true)
    try Data("current".utf8).write(to: cancelled.appendingPathComponent("auth.json"))
    try Data("expired".utf8).write(to: cancelled.appendingPathComponent("auth.json.expired"))
    try Data("account current\n".utf8).write(to: cancelled.appendingPathComponent(".active-auth-profile"))
    let cancelledSession = try AccountReauthenticationSession(directory: cancelled, currentAccount: "current", targetAccount: "expired")
    try Data("wrong-login".utf8).write(to: cancelled.appendingPathComponent("auth.json"))
    try cancelledSession.cancel()
    let restoredActive = try Data(contentsOf: cancelled.appendingPathComponent("auth.json"))
    let preservedExpired = try Data(contentsOf: cancelled.appendingPathComponent("auth.json.expired"))
    precondition(restoredActive == Data("current".utf8))
    precondition(preservedExpired == Data("expired".utf8))

    let interrupted = root.appendingPathComponent("interrupted")
    try files.createDirectory(at: interrupted, withIntermediateDirectories: true)
    try Data("current".utf8).write(to: interrupted.appendingPathComponent("auth.json"))
    try Data("expired".utf8).write(to: interrupted.appendingPathComponent("auth.json.expired"))
    try Data("account current\n".utf8).write(to: interrupted.appendingPathComponent(".active-auth-profile"))
    _ = try AccountReauthenticationSession(directory: interrupted, currentAccount: "current", targetAccount: "expired")
    try Data("unfinished-login".utf8).write(to: interrupted.appendingPathComponent("auth.json"))
    let recovered = try AccountReauthenticationSession.recoverInterrupted(in: interrupted)
    let recoveredActive = try Data(contentsOf: interrupted.appendingPathComponent("auth.json"))
    let recoveredExpired = try Data(contentsOf: interrupted.appendingPathComponent("auth.json.expired"))
    precondition(recovered)
    precondition(recoveredActive == Data("current".utf8))
    precondition(recoveredExpired == Data("expired".utf8))
    print("重新登录检查通过：成功替换、取消恢复和中断恢复均保留正确账号。")
}
try checkReauthentication()

func checkInterruptedAdditionRecovery() throws {
    func check(_ condition: Bool, _ message: String = "中断恢复结果不符合预期") { precondition(condition, message) }
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("interrupted-addition-\(UUID().uuidString)")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    let old = Data("old-credential".utf8)
    let new = Data("new-credential".utf8)
    let marker = Data("account old\n".utf8)
    func fixture(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try old.write(to: directory.appendingPathComponent("auth.json"))
        try marker.write(to: directory.appendingPathComponent(".active-auth-profile"))
        return directory
    }
    func read(_ directory: URL, _ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    let pendingName = ".codex-switcher-addition-pending.json"

    let beforeArchiveMove = try fixture("before-archive-move")
    try Data("{\"account\":\"old\",\"originalMarker\":\"account old\\n\"}".utf8)
        .write(to: beforeArchiveMove.appendingPathComponent(pendingName))
    guard case .none = try AccountLoginSession.recoverInterrupted(in: beforeArchiveMove) else {
        fatalError("尚未移动旧账号时应只清除进行中记录")
    }
    check(try read(beforeArchiveMove, "auth.json") == old)
    check(!files.fileExists(atPath: beforeArchiveMove.appendingPathComponent(pendingName).path))

    let beforeLogin = try fixture("before-login")
    _ = try AccountLoginSession(directory: beforeLogin, account: "old")
    guard case .restoredOriginal(let account) = try AccountLoginSession.recoverInterrupted(in: beforeLogin) else {
        fatalError("未登录中断应恢复旧账号")
    }
    check(account == "old")
    check(try read(beforeLogin, "auth.json") == old)
    check(try read(beforeLogin, ".active-auth-profile") == marker)
    check(!files.fileExists(atPath: beforeLogin.appendingPathComponent(pendingName).path))

    let afterLogin = try fixture("after-login")
    _ = try AccountLoginSession(directory: afterLogin, account: "old")
    try new.write(to: afterLogin.appendingPathComponent("auth.json"))
    guard case .needsRegistration(let original) = try AccountLoginSession.recoverInterrupted(in: afterLogin) else {
        fatalError("已有新凭据的中断应等待登记")
    }
    check(original == "old")
    try AccountLoginSession.finishPending(directory: afterLogin, account: "new")
    check(try read(afterLogin, "auth.json") == new)
    check(try read(afterLogin, "auth.json.old") == old)
    check(try read(afterLogin, ".active-auth-profile") == Data("account new\n".utf8))
    check(!files.fileExists(atPath: afterLogin.appendingPathComponent(pendingName).path))

    let damaged = try fixture("missing-backup")
    _ = try AccountLoginSession(directory: damaged, account: "old")
    try files.moveItem(at: damaged.appendingPathComponent("auth.json.old"), to: damaged.appendingPathComponent("saved-old"))
    do {
        _ = try AccountLoginSession.recoverInterrupted(in: damaged)
        fatalError("旧账号备份缺失时应停止恢复")
    } catch { }
    check(files.fileExists(atPath: damaged.appendingPathComponent(pendingName).path))
    print("新增账号中断恢复检查通过：未移动、未登录恢复、新登录登记、备份缺失保留现场。")
}
try checkInterruptedAdditionRecovery()

func checkTokenUsageTracking() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("token-usage-check-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    try files.createDirectory(at: sessions, withIntermediateDirectories: true)
    let log = sessions.appendingPathComponent("rollout.jsonl")
    func record(_ input: Int, timestamp: String = "2026-09-06T09:00:01.123Z") -> String {
        """
        {"timestamp":"2026-09-06T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":\(input + 20)}}}}
        """ + "\n"
    }
    func tokenRecord(_ input: Int, timestamp: String = "2026-09-06T09:00:01.123Z") -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":\(input + 20)}}}}
        """ + "\n"
    }
    try record(100).write(to: log, atomically: true, encoding: .utf8)
    let initialTime = ISO8601DateFormatter().date(from: "2026-09-06T09:00:00Z")!
    let tracker = TokenUsageTracker(
        roots: [sessions],
        stateURL: root.appendingPathComponent("state.json"),
        now: { initialTime }
    )
    let initial = try tracker.scan(account: "alpha")
    precondition(initial.isEmpty, "首次启用不应导入历史记录")
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(tokenRecord(240).utf8))
    try handle.close()
    let events = try tracker.scan(account: "alpha")
    precondition(events.count == 1 && events[0].input == 240, "没有只读取新增 Token 记录")
    precondition(events[0].model == "gpt-5.6-sol", "没有从启用位置之前恢复模型名称")
    let repeated = try tracker.scan(account: "alpha")
    precondition(repeated.count == 1, "重复扫描不应重复计数")

    let switchTime = ISO8601DateFormatter().date(from: "2026-09-06T09:10:00Z")!
    try tracker.recordAccountChange(account: "beta", at: switchTime)
    let secondHandle = try FileHandle(forWritingTo: log)
    try secondHandle.seekToEnd()
    try secondHandle.write(contentsOf: Data(tokenRecord(300, timestamp: "2026-09-06T09:09:59Z").utf8))
    try secondHandle.write(contentsOf: Data(tokenRecord(400, timestamp: "2026-09-06T09:10:01Z").utf8))
    try secondHandle.close()
    let switched = try tracker.scan(account: "beta")
    precondition(switched.count == 3, "跨账号扫描遗漏 Token 记录")
    precondition(switched[1].account == "alpha" && switched[1].input == 300, "切换前 Token 没有归入旧账号")
    precondition(switched[2].account == "beta" && switched[2].input == 400, "切换后 Token 没有归入新账号")

    let legacyStateURL = root.appendingPathComponent("legacy-state.json")
    let legacyState = """
    {
      "activeAccount": "alpha",
      "cursors": {},
      "events": [{
        "account": "alpha",
        "cacheWriteInput": 0,
        "cachedInput": 0,
        "id": "legacy:1",
        "input": 999,
        "model": "gpt-5.6-sol",
        "output": 1,
        "reasoningOutput": 0,
        "timestamp": "2026-09-06T09:00:00Z"
      }],
      "models": {}
    }
    """
    try legacyState.write(to: legacyStateURL, atomically: true, encoding: .utf8)
    let legacyTracker = TokenUsageTracker(roots: [sessions], stateURL: legacyStateURL, now: { initialTime })
    let migratedEvents = try legacyTracker.scan(account: "alpha")
    precondition(migratedEvents.isEmpty, "旧版错误统计没有在迁移时清空")
    let legacyBackup = legacyStateURL.deletingPathExtension().appendingPathExtension("pre-timeline-backup.json")
    precondition(files.fileExists(atPath: legacyBackup.path), "旧版统计迁移前没有创建备份")
    let priceEvent = TokenUsageEvent(
        id: "price", account: "alpha", timestamp: Date(), model: "gpt-5.6-sol",
        input: 1_000_000, cachedInput: 500_000, cacheWriteInput: 0,
        output: 100_000, reasoningOutput: 20_000
    )
    precondition(abs((ModelPricing.estimatedUSD(for: priceEvent) ?? 0) - 4.2) < 0.0001, "缓存价格计算错误")
    print("Token 增量统计检查通过：忽略历史、读取新增、避免重复、按切换时间归属账号、备份旧统计、分别计算缓存价格。")
}
try checkTokenUsageTracking()

func checkWeeklyQuotaProjection() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("weekly-projection-check-\(UUID().uuidString)")
    let store = WeeklyQuotaProjectionStore(url: root.appendingPathComponent("projection.json"))
    try store.beginIfNeeded(account: "alpha", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 90, estimatedUSD: 10, unpricedEvents: 0)
    try store.beginIfNeeded(account: "alpha", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 85, estimatedUSD: 15, unpricedEvents: 0)
    let unchanged = try store.observe(account: "alpha", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 90, estimatedUSD: 15, unpricedEvents: 0)
    precondition(unchanged == nil, "额度未下降时不应过早预测")
    let first = try store.observe(account: "alpha", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 80, estimatedUSD: 20, unpricedEvents: 0)
    precondition(first?.estimatedFullUSD == 100)
    precondition(first?.observedUsedPercent == 10)
    let second = try store.observe(account: "alpha", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 75, estimatedUSD: 30, unpricedEvents: 1)
    precondition(second?.observedUsedPercent == 15, "多次查询必须始终使用固定起点")
    precondition(second?.observedUSD == 20)
    precondition(second?.isPartial == true)
    try store.beginIfNeeded(account: "beta", resetAt: "2026-09-12T10:00:01Z", remainingPercent: 98, estimatedUSD: 3, unpricedEvents: 1)
    let jittered = try store.observe(account: "beta", resetAt: "2026-09-12T09:59:59Z", remainingPercent: 96, estimatedUSD: 4, unpricedEvents: 1)
    precondition(jittered?.observedUsedPercent == 2, "同一重置时间的秒级变化不应清空预测")
    precondition(jittered?.observedUSD == 1)
    try store.beginIfNeeded(account: "gamma", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 98, estimatedUSD: 5, unpricedEvents: 0)
    let unpricedDrop = try store.observe(account: "gamma", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 96, estimatedUSD: 4, unpricedEvents: 0)
    precondition(unpricedDrop == nil)
    let pricedDrop = try store.observe(account: "gamma", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 95, estimatedUSD: 6, unpricedEvents: 0)
    precondition(pricedDrop?.observedUsedPercent == 3, "没有对应价格的额度下降也必须计入观察比例")
    precondition(pricedDrop?.observedUSD == 1)
    precondition(pricedDrop?.isPartial == false)
    try store.begin(account: "beta", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 94, estimatedUSD: 8, unpricedEvents: 1)
    let switchedAgain = try store.observe(account: "beta", resetAt: "2026-09-12T10:00:00Z", remainingPercent: 93, estimatedUSD: 10, unpricedEvents: 1)
    precondition(switchedAgain?.observedUsedPercent == 1, "再次切换到账号时必须建立新的固定起点")
    precondition(switchedAgain?.observedUSD == 2)
    try store.begin(account: "alpha", resetAt: "2026-09-19T10:00:00Z", remainingPercent: 100, estimatedUSD: 0, unpricedEvents: 0)
    precondition(store.projections()["alpha"] == nil, "新周期必须清除旧预测")
    print("周额度预测检查通过：固定起点、多次查询、时间抖动、再次切换和跨周期重建。")
}
try checkWeeklyQuotaProjection()

func checkSwitchHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-history-check-\(UUID().uuidString)")
    let store = SwitchHistoryStore(url: root.appendingPathComponent("history.json"))
    precondition(store.load().isEmpty)
    _ = try store.append(SwitchHistoryRecord(fromAccount: "alpha", toAccount: "beta", result: .success))
    _ = try store.append(SwitchHistoryRecord(fromAccount: "beta", toAccount: "gamma", result: .failure, message: "test"))
    _ = try store.append(SwitchHistoryRecord(fromAccount: "gamma", toAccount: "delta", result: .success, action: .addAccount))
    _ = try store.append(SwitchHistoryRecord(fromAccount: "delta", toAccount: "beta", result: .success, action: .reauthenticate))
    let records = store.load()
    precondition(records.count == 4 && records[0].resolvedAction == .reauthenticate && records[1].resolvedAction == .addAccount)
    print("切换记录检查通过：切换、新增和重新登录记录按最新时间排列。")
}
try checkSwitchHistory()

func checkAccountCombinedSorting() {
    func account(_ name: String, five: Int, fiveReset: String, weekly: Int, weeklyResetAt: String?) -> AccountUsage {
        AccountUsage(
            name: name, fiveHourRemaining: five, fiveHourReset: fiveReset,
            weeklyRemaining: weekly, weeklyReset: "", weeklyResetAt: weeklyResetAt,
            resetCards: 0, notedAt: "2026-09-08T00:00:00Z"
        )
    }
    let accounts = [
        account("manual-first", five: 20, fiveReset: "09-08 12:00", weekly: 50, weeklyResetAt: "2026-09-15T10:00:00Z"),
        account("secondary-first", five: 80, fiveReset: "09-08 11:00", weekly: 50, weeklyResetAt: "2026-09-15T10:00:00Z"),
        account("earlier-week", five: 10, fiveReset: "09-08 10:00", weekly: 10, weeklyResetAt: "2026-09-14T10:00:00Z"),
        account("missing", five: 100, fiveReset: "--", weekly: 100, weeklyResetAt: nil)
    ]
    let rules = [
        AccountSortRule(field: .weeklyReset, direction: .ascending),
        AccountSortRule(field: .fiveHourQuota, direction: .descending)
    ]
    let names = AccountSorter.sorted(accounts, by: rules).map(\.name)
    precondition(names == ["earlier-week", "secondary-first", "manual-first", "missing"], "组合排序优先级或缺失时间排序错误")
    let descending = AccountSorter.sorted(accounts, by: [AccountSortRule(field: .weeklyReset, direction: .descending)]).map(\.name)
    precondition(descending.last == "missing", "缺失时间在降序时仍应位于最后")
    precondition(AccountSorter.sorted(accounts, by: []).map(\.name) == accounts.map(\.name), "清空规则后没有恢复手动顺序")
    print("账号组合排序检查通过：优先级、升降序、缺失时间和手动顺序回退正常。")
}
checkAccountCombinedSorting()
