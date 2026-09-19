import CodexSwitch5Core
import Foundation

func checkAppDataMigration() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("app-data-migration-\(UUID().uuidString)")
    let legacy = root.appendingPathComponent(".codex")
    let destination = root.appendingPathComponent("Application Support/Codex Switch5")
    try files.createDirectory(at: legacy, withIntermediateDirectories: true)
    let history = legacy.appendingPathComponent("codex_switch5_usage_history.jsonl")
    try Data("history\n".utf8).write(to: history)
    let auth = legacy.appendingPathComponent("auth.json")
    try Data("credential".utf8).write(to: auth)
    let moved = try AppDataDirectory.migrateLegacyFiles(from: legacy, to: destination)
    precondition(moved == ["codex_switch5_usage_history.jsonl"])
    precondition(!files.fileExists(atPath: history.path))
    let migratedHistory = try Data(contentsOf: destination.appendingPathComponent("codex_switch5_usage_history.jsonl"))
    let unchangedCredential = try Data(contentsOf: auth)
    precondition(migratedHistory == Data("history\n".utf8))
    precondition(unchangedCredential == Data("credential".utf8), "凭据不能迁出 .codex")
    try Data("new history\n".utf8).write(to: destination.appendingPathComponent("codex_switch5_usage_history.jsonl"))
    try Data("old history\n".utf8).write(to: history)
    let skipped = try AppDataDirectory.migrateLegacyFiles(from: legacy, to: destination)
    let preservedLegacyHistory = try Data(contentsOf: history)
    precondition(skipped.isEmpty)
    precondition(preservedLegacyHistory == Data("old history\n".utf8), "目标存在时不能覆盖或删除旧文件")
    print("应用数据迁移检查通过：只迁移私有数据，保留凭据，目标冲突不覆盖。")
}
try checkAppDataMigration()

func checkNativeAccountSwitch() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("native-account-switch-\(UUID().uuidString)")
    let dataDirectory = root.appendingPathComponent("data")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    let current = Data("current-credential".utf8)
    let target = Data("target-credential".utf8)
    try current.write(to: root.appendingPathComponent("auth.json"))
    try target.write(to: root.appendingPathComponent("auth.json.target"))
    let service = NativeAccountService(codexDirectory: root, usageURL: dataDirectory.appendingPathComponent("account_usage.json"))
    try service.switchAccount(from: "current", to: "target")
    let activeAfterSwitch = try Data(contentsOf: root.appendingPathComponent("auth.json"))
    let archivedAfterSwitch = try Data(contentsOf: root.appendingPathComponent("auth.json.current"))
    precondition(activeAfterSwitch == target)
    precondition(archivedAfterSwitch == current)
    precondition(!files.fileExists(atPath: dataDirectory.appendingPathComponent("auth.json").path), "凭据不能写入应用数据目录")
    do {
        try service.switchAccount(from: "target", to: "missing")
        preconditionFailure("缺少目标凭据时必须停止")
    } catch { }
    let activeAfterFailure = try Data(contentsOf: root.appendingPathComponent("auth.json"))
    precondition(activeAfterFailure == target, "失败不得改动活动凭据")

    func credential(accountID: String, value: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tokens": ["account_id": accountID, "access_token": value]
        ])
    }
    let staleRoot = files.temporaryDirectory.appendingPathComponent("native-stale-switch-\(UUID().uuidString)")
    try files.createDirectory(at: staleRoot, withIntermediateDirectories: true)
    let renewed = try credential(accountID: "same-account", value: "renewed")
    let expired = try credential(accountID: "same-account", value: "expired")
    let next = try credential(accountID: "next-account", value: "next")
    try renewed.write(to: staleRoot.appendingPathComponent("auth.json"))
    try expired.write(to: staleRoot.appendingPathComponent("auth.json.current"))
    try next.write(to: staleRoot.appendingPathComponent("auth.json.next"))
    let staleService = NativeAccountService(codexDirectory: staleRoot, usageURL: dataDirectory.appendingPathComponent("stale.json"))
    try staleService.switchAccount(from: "current", to: "next")
    let staleActive = try Data(contentsOf: staleRoot.appendingPathComponent("auth.json"))
    let staleArchived = try Data(contentsOf: staleRoot.appendingPathComponent("auth.json.current"))
    precondition(staleActive == next)
    precondition(staleArchived == renewed)

    let mismatchRoot = files.temporaryDirectory.appendingPathComponent("native-mismatch-switch-\(UUID().uuidString)")
    try files.createDirectory(at: mismatchRoot, withIntermediateDirectories: true)
    let unrelated = try credential(accountID: "other-account", value: "other")
    try renewed.write(to: mismatchRoot.appendingPathComponent("auth.json"))
    try unrelated.write(to: mismatchRoot.appendingPathComponent("auth.json.current"))
    try next.write(to: mismatchRoot.appendingPathComponent("auth.json.next"))
    let mismatchService = NativeAccountService(codexDirectory: mismatchRoot, usageURL: dataDirectory.appendingPathComponent("mismatch.json"))
    do {
        try mismatchService.switchAccount(from: "current", to: "next")
        preconditionFailure("不同身份的同名存档必须拒绝覆盖")
    } catch { }
    let mismatchActive = try Data(contentsOf: mismatchRoot.appendingPathComponent("auth.json"))
    let mismatchArchived = try Data(contentsOf: mismatchRoot.appendingPathComponent("auth.json.current"))
    precondition(mismatchActive == renewed)
    precondition(mismatchArchived == unrelated)
    print("原生账号切换检查通过：正常切换、同身份旧存档替换、不同身份防覆盖均正确。")
}
try checkNativeAccountSwitch()

func checkLoginStateIsolation() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("login-state-isolation-\(UUID().uuidString)")
    let credentials = root.appendingPathComponent(".codex")
    let state = root.appendingPathComponent("Application Support/Codex Switch5")
    try files.createDirectory(at: credentials, withIntermediateDirectories: true)
    try Data("old-credential".utf8).write(to: credentials.appendingPathComponent("auth.json"))
    try files.createDirectory(at: state, withIntermediateDirectories: true)
    try Data("account old\n".utf8).write(to: state.appendingPathComponent(".active-auth-profile"))

    let session = try AccountLoginSession(directory: credentials, stateDirectory: state, account: "old")
    precondition(files.fileExists(atPath: state.appendingPathComponent(".codex-switch5-addition-pending.json").path))
    precondition(!files.fileExists(atPath: credentials.appendingPathComponent(".active-auth-profile").path))
    precondition(!files.fileExists(atPath: credentials.appendingPathComponent(".codex-switch5-addition-pending.json").path))
    try session.cancel()
    let restored = try Data(contentsOf: credentials.appendingPathComponent("auth.json"))
    precondition(restored == Data("old-credential".utf8))
    print("登录状态隔离检查通过：凭据留在 Codex 目录，应用标记和未完成记录留在应用数据目录。")
}
try checkLoginStateIsolation()

func checkAuthenticationStateReset() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("authentication-state-reset-\(UUID().uuidString)")
    let usageURL = root.appendingPathComponent("data/account_usage.json")
    let historyURL = root.appendingPathComponent("data/codex_switch5_usage_history.jsonl")
    try files.createDirectory(at: usageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let oldUsage: [String: Any] = [
        "account": [
            "five_hour_remaining": 0,
            "five_hour_reset": "2026-09-08 07:00",
            "weekly_remaining": 84,
            "weekly_reset": "9.15",
            "reset_cards": 0,
            "auth_invalid": true,
            "noted_at": "2026-09-08T05:09:37+08:00"
        ]
    ]
    try JSONSerialization.data(withJSONObject: oldUsage).write(to: usageURL)
    let service = NativeAccountService(codexDirectory: root, usageURL: usageURL, usageHistoryURL: historyURL)
    try service.markAuthenticated(account: "account")
    let updated = try UsageStore.decode(Data(contentsOf: usageURL)).first
    precondition(updated?.authInvalid == false)
    precondition(updated?.weeklyRemaining == 84 && updated?.notedAt == "2026-09-08T05:09:37+08:00")

    let validUsage = AccountUsage(
        name: "account", fiveHourRemaining: 76, fiveHourReset: "2026-09-11 22:42",
        weeklyRemaining: 64, weeklyReset: "9.15", weeklyResetAt: "2026-09-15T12:00:00Z",
        resetCards: 2, notedAt: "2026-09-11T09:40:00Z"
    )
    let observation = QuotaObservation(usage: validUsage, activeAccount: "account")!
    _ = try UsageHistoryStore(url: historyURL).append([.observation(observation)])
    try JSONSerialization.data(withJSONObject: oldUsage).write(to: usageURL)
    try service.markAuthenticationInvalid(account: "account")
    let restored = try UsageStore.decode(Data(contentsOf: usageURL)).first
    precondition(restored?.authInvalid == true)
    precondition(restored?.authInvalidSince != nil)
    try service.markAuthenticationInvalid(account: "account")
    _ = try service.restoreInvalidUsageFromHistory()
    let repeatedInvalid = try UsageStore.decode(Data(contentsOf: usageURL)).first
    precondition(repeatedInvalid?.authInvalidSince == restored?.authInvalidSince)
    try service.markAuthenticated(account: "account")
    let authenticated = try UsageStore.decode(Data(contentsOf: usageURL)).first
    precondition(authenticated?.authInvalidSince == nil)

    precondition(restored?.fiveHourRemaining == 76 && restored?.fiveHourReset == "2026-09-11 22:42")
    precondition(restored?.weeklyRemaining == 64 && restored?.weeklyReset == "9.15")
    precondition(restored?.weeklyResetAt != nil && restored?.resetCards == 2)
    try JSONSerialization.data(withJSONObject: oldUsage).write(to: usageURL)
    let migratedCount = try service.restoreInvalidUsageFromHistory()
    precondition(migratedCount == 1)
    let migrated = try UsageStore.decode(Data(contentsOf: usageURL)).first
    precondition(migrated?.fiveHourReset == "2026-09-11 22:42" && migrated?.weeklyReset == "9.15")
    let repeatedCount = try service.restoreInvalidUsageFromHistory()
    precondition(repeatedCount == 0, "已经恢复的记录不应反复写入")
    print("重新登录状态检查通过：新凭据验证后清除失效标记，旧额度等待刷新。")
}
try checkAuthenticationStateReset()

if CommandLine.arguments.contains("--usage-learning-only") {
    try checkUsageLearning()
    exit(0)
}

do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-switch5-group-check-\(UUID().uuidString)")
    let store = AccountGroupStore(url: directory.appendingPathComponent("groups.json"))
    var state = AccountGroupState()
    let group = try state.createGroup(named: " 工作 ")
    precondition((try? state.createGroup(named: "工作")) == nil, "重复分组名称没有被拒绝")
    state.assign(accounts: ["a", "b"], to: group.id)
    try store.save(state)
    var loaded = try store.load(validAccounts: ["a"])
    precondition(loaded.groups.first?.name == "工作", "分组名称没有正确保存")
    precondition(loaded.accountGroupIDs == ["a": group.id], "无效账号关系没有清理")
    loaded.assign(accounts: ["z"], to: nil)
    loaded.assignReauthenticatedAccount("z", to: group.id, replacing: "a")
    precondition(loaded.accountGroupIDs["z"] == group.id, "重新登录账号没有加入目标分组")
    precondition(loaded.accountGroupIDs["a"] == nil, "被替换账号没有移到未分组")
    loaded.assignReauthenticatedAccount("b", to: group.id, replacing: nil)
    precondition(loaded.accountGroupIDs["b"] == group.id, "不替换时账号没有正常加入分组")
    loaded.assignReauthenticatedAccount("new", to: group.id, replacing: "b")
    precondition(loaded.accountGroupIDs["new"] == group.id, "新增账号没有加入目标分组")
    precondition(loaded.accountGroupIDs["b"] == nil, "新增账号替换的原成员没有移到未分组")
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
  "nearest": {"five_hour_remaining": 40, "five_hour_reset": "2030-01-01 10:00", "weekly_remaining": 60, "weekly_reset": "1.2", "reset_cards": 1, "reset_card_expirations": ["2030-01-03T10:00:00Z"], "noted_at": "2026-09-05T10:00:00+08:00"},
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
precondition(result?.resetCardExpirations == ["2030-01-03T10:00:00Z"], "没有解析重置卡到期时间")
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
    let first = try AccountLoginSession(directory: plain, stateDirectory: plain, account: "old")
    try first.cancel()
    check(try read(plain, "auth.json") == old)
    check(try read(plain, ".active-auth-profile") == marker)
    precondition(!files.fileExists(atPath: plain.appendingPathComponent("auth.json.old").path))
    try first.cancel()
    check(try read(plain, "auth.json") == old, "重复取消不得移动旧账号")

    let late = try fixture("cancel-after-login-write")
    let second = try AccountLoginSession(directory: late, stateDirectory: late, account: "old")
    try new.write(to: late.appendingPathComponent("auth.json"))
    try second.cancel()
    check(try read(late, "auth.json") == old)
    check(!files.fileExists(atPath: late.appendingPathComponent("cancelled-logins").path), "取消不应保留新凭据")
    check(try read(late, ".active-auth-profile") == marker)

    let success = try fixture("completed-login")
    let third = try AccountLoginSession(directory: success, stateDirectory: success, account: "old")
    try new.write(to: success.appendingPathComponent("auth.json"))
    try third.complete(account: "new")
    try third.cancel()
    check(try read(success, "auth.json") == new, "完成后的取消不得撤销新账号")
    check(try read(success, "auth.json.old") == old)
    check(try read(success, ".active-auth-profile") == Data("account new\n".utf8))

    let conflict = try fixture("existing-backup")
    try new.write(to: conflict.appendingPathComponent("auth.json.old"))
    do {
        _ = try AccountLoginSession(directory: conflict, stateDirectory: conflict, account: "old")
        fatalError("已有备份时应拒绝覆盖")
    } catch { }
    check(try read(conflict, "auth.json") == old)
    check(try read(conflict, "auth.json.old") == new)

    let missing = try fixture("missing-backup")
    let fourth = try AccountLoginSession(directory: missing, stateDirectory: missing, account: "old")
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
    let session = try AccountReauthenticationSession(directory: root, stateDirectory: root, currentAccount: "current", targetAccount: "expired")
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
    let cancelledSession = try AccountReauthenticationSession(directory: cancelled, stateDirectory: cancelled, currentAccount: "current", targetAccount: "expired")
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
    _ = try AccountReauthenticationSession(directory: interrupted, stateDirectory: interrupted, currentAccount: "current", targetAccount: "expired")
    try Data("unfinished-login".utf8).write(to: interrupted.appendingPathComponent("auth.json"))
    let recovered = try AccountReauthenticationSession.recoverInterrupted(in: interrupted, stateDirectory: interrupted)
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
    let pendingName = ".codex-switch5-addition-pending.json"

    let beforeArchiveMove = try fixture("before-archive-move")
    try Data("{\"account\":\"old\",\"originalMarker\":\"account old\\n\"}".utf8)
        .write(to: beforeArchiveMove.appendingPathComponent(pendingName))
    guard case .none = try AccountLoginSession.recoverInterrupted(in: beforeArchiveMove, stateDirectory: beforeArchiveMove) else {
        fatalError("尚未移动旧账号时应只清除进行中记录")
    }
    check(try read(beforeArchiveMove, "auth.json") == old)
    check(!files.fileExists(atPath: beforeArchiveMove.appendingPathComponent(pendingName).path))

    let beforeLogin = try fixture("before-login")
    _ = try AccountLoginSession(directory: beforeLogin, stateDirectory: beforeLogin, account: "old")
    guard case .restoredOriginal(let account) = try AccountLoginSession.recoverInterrupted(in: beforeLogin, stateDirectory: beforeLogin) else {
        fatalError("未登录中断应恢复旧账号")
    }
    check(account == "old")
    check(try read(beforeLogin, "auth.json") == old)
    check(try read(beforeLogin, ".active-auth-profile") == marker)
    check(!files.fileExists(atPath: beforeLogin.appendingPathComponent(pendingName).path))

    let afterLogin = try fixture("after-login")
    _ = try AccountLoginSession(directory: afterLogin, stateDirectory: afterLogin, account: "old")
    try new.write(to: afterLogin.appendingPathComponent("auth.json"))
    guard case .needsRegistration(let original) = try AccountLoginSession.recoverInterrupted(in: afterLogin, stateDirectory: afterLogin) else {
        fatalError("已有新凭据的中断应等待登记")
    }
    check(original == "old")
    try AccountLoginSession.finishPending(directory: afterLogin, stateDirectory: afterLogin, account: "new")
    check(try read(afterLogin, "auth.json") == new)
    check(try read(afterLogin, "auth.json.old") == old)
    check(try read(afterLogin, ".active-auth-profile") == Data("account new\n".utf8))
    check(!files.fileExists(atPath: afterLogin.appendingPathComponent(pendingName).path))

    let damaged = try fixture("missing-backup")
    _ = try AccountLoginSession(directory: damaged, stateDirectory: damaged, account: "old")
    try files.moveItem(at: damaged.appendingPathComponent("auth.json.old"), to: damaged.appendingPathComponent("saved-old"))
    do {
        _ = try AccountLoginSession.recoverInterrupted(in: damaged, stateDirectory: damaged)
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
    let boundary = ISO8601DateFormatter().date(from: "2026-09-07T00:00:00Z")!
    let historyEvents = [
        TokenUsageEvent(
            id: "before", account: "alpha", timestamp: boundary.addingTimeInterval(-1), model: "gpt-5.6-sol",
            input: 100, cachedInput: 0, cacheWriteInput: 0, output: 10, reasoningOutput: 0
        ),
        TokenUsageEvent(
            id: "boundary", account: "beta", timestamp: boundary, model: "gpt-5.6-sol",
            input: 200, cachedInput: 0, cacheWriteInput: 0, output: 20, reasoningOutput: 0
        ),
    ]
    let previousBucket = tracker.totals(
        events: historyEvents,
        from: boundary.addingTimeInterval(-86_400),
        to: boundary
    )
    let nextBucket = tracker.totals(
        events: historyEvents,
        from: boundary,
        to: boundary.addingTimeInterval(86_400)
    )
    precondition(previousBucket.total == 110 && nextBucket.total == 220, "历史分段不应遗漏或重复交界记录")
    let autoReviewEvent = TokenUsageEvent(
        id: "review", account: "alpha", timestamp: boundary, model: "codex-auto-review",
        input: 300, cachedInput: 100, cacheWriteInput: 0, output: 30, reasoningOutput: 10
    )
    let reviewTotals = tracker.totals(
        events: [historyEvents[1], autoReviewEvent],
        from: boundary,
        to: boundary.addingTimeInterval(1)
    )
    precondition(reviewTotals.total == 220, "codex-auto-review 不应计入 Token 总数")
    precondition(reviewTotals.autoReviewTokens == 330, "没有单独统计 codex-auto-review 用量")
    precondition(reviewTotals.unpricedEvents == 0, "codex-auto-review 不应标记成未知价格事件")
    precondition(ModelPricing.estimatedUSD(for: autoReviewEvent) == nil, "codex-auto-review 不应套用公开模型价格")
    print("Token 增量统计检查通过：忽略历史、读取新增、避免重复、按切换时间归属账号、备份旧统计、分别计算缓存价格，历史分段交界不重复。")
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
    _ = try store.append(SwitchHistoryRecord(
        fromAccount: "beta", toAccount: "beta", result: .success, action: .changeGroup,
        fromGroup: "team1", toGroup: "team2", includesGroupAssignment: true
    ))
    _ = try store.append(SwitchHistoryRecord(fromAccount: "same", toAccount: "same", result: .failure))
    let records = store.load()
    precondition(records.count == 5 && records[0].resolvedAction == .changeGroup && records[1].resolvedAction == .reauthenticate)
    precondition(records[0].fromGroup == "team1" && records[0].toGroup == "team2")
    precondition(!records.contains { $0.resolvedAction == .switchAccount && $0.fromAccount == $0.toAccount })

    let legacy = """
    [{"id":"00000000-0000-0000-0000-000000000001","timestamp":"2026-09-11T00:00:00Z","fromAccount":"old","toAccount":"new","result":"success","message":"","action":"addAccount"}]
    """
    try Data(legacy.utf8).write(to: root.appendingPathComponent("history.json"), options: .atomic)
    let legacyRecords = store.load()
    precondition(legacyRecords.count == 1 && legacyRecords[0].includesGroupAssignment == nil)
    print("切换记录检查通过：分组变更可保存，旧记录仍可读取，同账号切换不会保存。")
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
try checkUsageLearning()

func checkStartupAccounts() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("startup-accounts-\(UUID().uuidString)")
    let directory = root.appendingPathComponent(".codex")
    precondition(StartupAccounts(directory: directory).names.isEmpty)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    func credential(_ file: String, _ id: String, _ email: String) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": email, "sub": id]).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "test-\(id)", "account_id": id, "id_token": "x.\(payload).x"]])
        try data.write(to: directory.appendingPathComponent(file))
    }
    try credential("auth.json", "a", "alice@example.test")
    let original = try Data(contentsOf: directory.appendingPathComponent("auth.json"))
    let fresh = StartupAccounts(directory: directory)
    precondition(fresh.current == "alice" && fresh.names == ["alice"])
    precondition(fresh.merging([]).first?.fiveHourRemaining == -1)
    precondition(StartupAccounts(directory: directory, preferredNames: ["my_alias"]).current == "my_alias")
    try original.write(to: directory.appendingPathComponent("auth.json.backup_account"))
    try credential("auth.json.other", "b", "bob@example.test")
    try credential("auth.json.bak", "c", "ignored@example.test")
    try Data("broken".utf8).write(to: directory.appendingPathComponent("auth.json.broken"))
    let reinstalled = StartupAccounts(directory: directory, preferredNames: ["other"])
    precondition(reinstalled.current == "backup_account")
    precondition(reinstalled.names == ["backup_account", "other"])
    let cached = AccountUsage(name: "other", fiveHourRemaining: 42, fiveHourReset: "", weeklyRemaining: 20, weeklyReset: "", resetCards: 0, notedAt: "saved")
    precondition(reinstalled.merging([cached]).first(where: { $0.name == "other" }) == cached)
    try credential("auth.json", "c", "other@example.test")
    precondition(StartupAccounts(directory: directory).current == "other_2")
    // 仅剩存档时允许恢复；已有未知活动文件时禁止覆盖。
    try files.moveItem(at: directory.appendingPathComponent("auth.json"), to: root.appendingPathComponent("preserved-auth"))
    precondition(StartupAccounts(directory: directory, preferredNames: ["other"]).current == nil)
    let service = NativeAccountService(codexDirectory: directory, usageURL: root.appendingPathComponent("usage.json"))
    try service.switchAccount(from: "", to: "other")
    precondition(StartupAccounts(directory: directory).current == "other")
    do { try service.switchAccount(from: "", to: "backup_account"); preconditionFailure("不能覆盖活动凭据") } catch { }
    let backup = try Data(contentsOf: directory.appendingPathComponent("auth.json.backup_account"))
    precondition(backup == original, "读取及恢复过程必须保留其他账号凭据")
    print("启动检查通过：空目录、首次登录、重装、缓存缺失、旧名称、同名账号、无效存档、仅剩存档及防覆盖。")
}
try checkStartupAccounts()

func checkOldProductNameMigration() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("switch5-name-\(UUID().uuidString)")
    let legacy = root.appendingPathComponent("codex")
    let destination = root.appendingPathComponent("data")
    try files.createDirectory(at: legacy, withIntermediateDirectories: true)
    try files.createDirectory(at: destination, withIntermediateDirectories: true)
    let old = destination.appendingPathComponent("codex_switcher_account_groups.json")
    try Data("preserved-groups".utf8).write(to: old)
    let pending = legacy.appendingPathComponent(".codex-switcher-addition-pending.json")
    try Data("pending".utf8).write(to: pending)
    let moved = try AppDataDirectory.migrateLegacyFiles(from: legacy, to: destination)
    precondition(moved.contains("codex_switch5_account_groups.json"))
    precondition(moved.contains(".codex-switch5-addition-pending.json"))
    let content = try Data(contentsOf: destination.appendingPathComponent("codex_switch5_account_groups.json"))
    precondition(content == Data("preserved-groups".utf8))
    try Data("conflict".utf8).write(to: old)
    _ = try AppDataDirectory.migrateLegacyFiles(from: legacy, to: destination)
    precondition(files.fileExists(atPath: old.path), "名称冲突必须保留旧文件")
    print("旧名称迁移检查通过：数据目录、旧目录、待恢复操作和冲突保留。")
}
try checkOldProductNameMigration()
