import AppKit
import CodexSwitch5Core
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    struct AccountIdentity: Equatable {
        let originalName: String
        let email: String
    }

    @Published var accounts: [AccountUsage] = []
    @Published var currentType = ""
    @Published var currentName = ""
    @Published var selectedAccount: String?
    @Published var isRefreshing = false
    @Published var isSwitching = false
    @Published var status = ""
    @Published var lastError: String?
    @Published var showingSwitchConfirmation = false
    @Published var pendingSwitchAccount: String?
    @Published var identities: [String: AccountIdentity] = [:]
    @Published var aliases: [String: String] = [:]
    @Published var refreshingAccounts: Set<String> = []
    @Published var showingAddAccount = false
    @Published var reauthenticatingAccount: String?
    @Published var addAccountStage = ""
    @Published var isWaitingForLogin = false
    @Published var isAddingAccount = false
    @Published var isCancellingLogin = false
    @Published var notice: String?
    @Published var editingAccount: String?
    @Published var editingAlias = ""
    @Published var removingAccount: String?
    @Published var accountGroupState = AccountGroupState()
    @Published var pendingAddAccountGroupID: UUID?
    @Published var pendingReauthenticationReplacementAccount: String?
    @Published var showsReauthenticationGroupOptions = false
    @Published var accountGroupError: String?
    @Published private(set) var tokenEvents: [TokenUsageEvent] = []
    @Published private(set) var weeklyQuotaProjections: [String: WeeklyQuotaProjection] = [:]
    @Published private(set) var switchHistory: [SwitchHistoryRecord] = []
    @Published private(set) var usageLearning = UsageLearningSummary()
    @Published private(set) var usageLearningPeriod: UsageLearningPeriod = .lastThirtyDays
    @Published private(set) var usageHistoryError: String?
    @Published private(set) var isCodexCLIInstalled = false
    @Published private(set) var isDetectingCodexCLI = true
    @Published private(set) var addAccountUsesChatGPT = false
    @Published var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage") }
    }
    @AppStorage("refreshIntervalValue") var refreshIntervalValue = 1
    @AppStorage("refreshIntervalUnit") var refreshIntervalUnit = "minutes"
    @AppStorage("automaticRefresh") var automaticRefresh = false
    @AppStorage("didMigrateEmailDefaultNames") private var didMigrateEmailDefaultNames = false

    private let codexDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private let appDataDirectory: URL
    private var appDataMigrationError: String?
    private var automaticTask: Task<Void, Never>?
    private var loginWatchTask: Task<Void, Never>?
    private var loginSession: AccountLoginSession?
    private var reauthenticationSession: AccountReauthenticationSession?
    private var loginRequiresCLIRestart = false
    private var noticeTask: Task<Void, Never>?
    private var resetRefreshTasks: [String: Task<Void, Never>] = [:]
    private var triggeredResetKeys: Set<String> = []
    private var usageLearningTask: Task<Void, Never>?
    private lazy var usageHistoryStore = UsageHistoryStore(
        url: appDataDirectory.appendingPathComponent("codex_switch5_usage_history.jsonl")
    )
    private lazy var tokenTracker = TokenUsageTracker(
        roots: [codexDirectory.appendingPathComponent("sessions"), codexDirectory.appendingPathComponent("archived_sessions")],
        stateURL: appDataDirectory.appendingPathComponent("codex_switch5_token_usage.json")
    )
    private lazy var switchHistoryStore = SwitchHistoryStore(
        url: appDataDirectory.appendingPathComponent("codex_switch5_switch_history.json")
    )
    private lazy var weeklyQuotaProjectionStore = WeeklyQuotaProjectionStore(
        url: appDataDirectory.appendingPathComponent("codex_switch5_weekly_quota_projection.json")
    )
    private lazy var accountGroupStore = AccountGroupStore(
        url: appDataDirectory.appendingPathComponent("codex_switch5_account_groups.json")
    )
    private var nativeAccountService: NativeAccountService {
        NativeAccountService(
            codexDirectory: codexDirectory,
            usageURL: appDataDirectory.appendingPathComponent("account_usage.json"),
            usageHistoryURL: appDataDirectory.appendingPathComponent("codex_switch5_usage_history.jsonl")
        )
    }

    private enum StartupRecovery {
        case none
        case notice(String)
        case error(String)
    }

    init() {
        AppDataDirectory.migratePreferences()
        appDataDirectory = AppDataDirectory.url()
        do {
            _ = try AppDataDirectory.migrateLegacyFiles(from: codexDirectory, to: appDataDirectory)
        } catch {
            appDataMigrationError = error.localizedDescription
        }
        let stored = UserDefaults.standard.string(forKey: "appLanguage")
        appLanguage = AppLanguage(rawValue: stored ?? "") ?? .system
        status = AppLocalization.text("准备就绪", language: appLanguage)
        addAccountStage = AppLocalization.text("准备添加新账号", language: appLanguage)
    }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        AppLocalization.text(key, language: appLanguage, arguments)
    }

    var isChatGPTInstalled: Bool { chatGPTApplicationURL != nil }

    var clientAvailability: ClientAvailability {
        ClientAvailability(hasChatGPT: isChatGPTInstalled, hasCodexCLI: isCodexCLIInstalled)
    }

    private var chatGPTApplicationURL: URL? {
        let fileManager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app")
        ]
        if let installed = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return installed
        }
        for bundleIdentifier in ["com.openai.chat", "com.openai.codex"] {
            if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return installed
            }
        }
        return nil
    }

    var recommendation: AccountUsage? {
        AccountRecommender.next(
            from: accounts,
            currentAccount: currentType == "account" ? currentName : nil
        )
    }

    var rankedAccounts: [AccountUsage] {
        AccountRecommender.ranked(
            from: accounts,
            currentAccount: currentType == "account" ? currentName : nil
        )
    }

    var selected: AccountUsage? {
        accounts.first { $0.name == selectedAccount } ?? recommendation ?? accounts.first
    }

    func start() {
        detectCodexCLI()
        let recovery = recoverInterruptedLoginOperation()
        loadFromDisk()
        loadAccountGroups()
        switchHistory = switchHistoryStore.load()
        weeklyQuotaProjections = weeklyQuotaProjectionStore.projections()
        refreshTokenUsage()
        updateUsageLearning()
        beginWeeklyQuotaProjectionIfNeeded(for: currentName)
        configureAutomaticRefresh()
        if !accounts.isEmpty, lastError == nil { refresh() }
        if let appDataMigrationError {
            lastError = text("无法迁移应用数据：%@", appDataMigrationError)
        }
        switch recovery {
        case .none:
            break
        case .notice(let message):
            showNotice(message)
        case .error(let message):
            lastError = message
        }
    }

    private func recoverInterruptedLoginOperation() -> StartupRecovery {
        do {
            if try AccountReauthenticationSession.recoverInterrupted(in: codexDirectory, stateDirectory: appDataDirectory) {
                return .notice(text("已恢复上次未完成的重新登录"))
            }
        } catch {
            return .error(text("无法恢复上次未完成的重新登录：%@", error.localizedDescription))
        }
        return recoverInterruptedAddition()
    }

    private func detectCodexCLI() {
        isDetectingCodexCLI = true
        let detection = Task.detached(priority: .utility) { Self.detectCodexCLISynchronously() }
        Task { [weak self] in
            let installed = await detection.value
            guard let self else { return }
            isCodexCLIInstalled = installed
            isDetectingCodexCLI = false
        }
    }

    nonisolated private static func detectCodexCLISynchronously() -> Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var directories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map { URL(fileURLWithPath: String($0)) } ?? []
        directories.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent(".asdf/shims"),
            home.appendingPathComponent(".local/share/mise/shims"),
            home.appendingPathComponent("Library/pnpm"),
            home.appendingPathComponent(".bun/bin")
        ])
        if directories.contains(where: { fileManager.isExecutableFile(atPath: $0.appendingPathComponent("codex").path) }) {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v codex >/dev/null 2>&1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func recoverInterruptedAddition() -> StartupRecovery {
        do {
            switch try AccountLoginSession.recoverInterrupted(in: codexDirectory, stateDirectory: appDataDirectory) {
            case .none:
                return .none
            case .restoredOriginal:
                return .notice(text("已恢复上次未完成的新增账号"))
            case .needsRegistration(let originalAccount):
                let active = codexDirectory.appendingPathComponent("auth.json")
                guard let activeIdentity = identity(from: active) else {
                    return .error(text("发现未完成的新增账号，但无法识别当前账号；现有凭据未修改。"))
                }
                let archived = codexDirectory.appendingPathComponent("auth.json.\(originalAccount)")
                let registeredName: String
                if identity(from: archived) == activeIdentity {
                    registeredName = originalAccount
                } else {
                    registeredName = availableInternalName(for: activeIdentity)
                }
                try AccountLoginSession.finishPending(directory: codexDirectory, stateDirectory: appDataDirectory, account: registeredName)
                return .notice(text("已完成上次中断的新增账号"))
            }
        } catch {
            return .error(text("无法恢复上次未完成的新增账号：%@", error.localizedDescription))
        }
    }

    func loadFromDisk() {
        guard !isAddingAccount else { return }
        do {
            let savedAccount = UserDefaults.standard.string(forKey: "activeSwitch5Account")
            if let resolvedAccount = resolvedActiveAccountName() {
                currentType = "account"
                currentName = resolvedAccount
                setActiveAccountState(resolvedAccount)
                if savedAccount != resolvedAccount { status = text("已恢复当前账号识别") }
            } else {
                currentType = ""
                currentName = ""
            }

            let usageURL = appDataDirectory.appendingPathComponent("account_usage.json")
            try nativeAccountService.restoreInvalidUsageFromHistory()
            let discovered = startupAccounts()
            let knownNames = discovered.names
            let cached = FileManager.default.fileExists(atPath: usageURL.path)
                ? try UsageStore.decode(Data(contentsOf: usageURL)) : []
            accounts = discovered.merging(cached)
            aliases = loadAliases()
            identities = loadIdentities(for: knownNames)
            migrateLegacyAutomaticAliasesIfNeeded()
            if selectedAccount == nil { selectedAccount = recommendation?.name ?? accounts.first?.name }
            configureResetRefreshes()
            if status != text("已恢复当前账号识别") {
                status = text("已载入 %d 个账号", accounts.count)
            }
            lastError = nil
        } catch {
            let discovered = startupAccounts()
            accounts = discovered.merging(accounts)
            aliases = loadAliases()
            identities = loadIdentities(for: discovered.names)
            lastError = text("无法读取账号数据：%@", error.localizedDescription)
        }
    }

    func refresh(automatic: Bool = false) {
        guard !isAddingAccount, !isSwitching else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        beginWeeklyQuotaProjectionIfNeeded(for: currentName)
        status = text("正在查询账号限额…")
        lastError = nil
        Task {
            let result = await runNativeOperation([automatic ? "refresh-auto" : "refresh"])
            isRefreshing = false
            loadFromDisk()
            refreshTokenUsage()
            if result.code == 0 {
                observeWeeklyQuotaProjection(for: currentName)
                status = result.output.isEmpty ? text("刷新完成") : result.output
            } else {
                lastError = result.output
                status = text("刷新未完全成功")
            }
            configureAutomaticRefresh()
        }
    }

    func refresh(account: String) {
        guard !isAddingAccount, !isSwitching else { return }
        guard !refreshingAccounts.contains(account) else { return }
        refreshingAccounts.insert(account)
        beginWeeklyQuotaProjectionIfNeeded(for: account)
        lastError = nil
        Task {
            let result = await runNativeOperation(["refresh", account])
            refreshingAccounts.remove(account)
            loadFromDisk()
            refreshTokenUsage()
            if result.code == 0 {
                observeWeeklyQuotaProjection(for: account)
                status = text("已刷新 %@", displayName(for: account))
            } else {
                lastError = result.output
                status = text("账号查询失败")
            }
        }
    }

    func displayName(for account: String) -> String {
        let alias = aliases[account]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = identities[account]
        let original = identity?.originalName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let alias, !alias.isEmpty { return alias }
        let emailName = identity?.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        if !emailName.isEmpty { return emailName }
        return original.isEmpty ? account : original
    }

    func identityHelp(for account: String) -> String {
        guard let identity = identities[account] else { return text("账号文件名：%@", account) }
        return text("用户名：%@\n邮箱：%@", identity.originalName, identity.email)
    }

    func beginEditingAlias(_ account: String) {
        editingAccount = account
        editingAlias = aliases[account] ?? displayName(for: account)
    }

    func saveAlias() {
        guard let account = editingAccount else { return }
        let value = editingAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { aliases.removeValue(forKey: account) } else { aliases[account] = value }
        saveAliases()
        editingAccount = nil
    }

    func prepareAddAccount() {
        guard !isAddingAccount, !isSwitching, !isRefreshing, refreshingAccounts.isEmpty, pendingSwitchAccount == nil else {
            showNotice(text("请等待当前操作完成。"))
            return
        }
        guard !isDetectingCodexCLI else {
            showNotice(text("正在检测 Codex CLI，请稍候。"))
            return
        }
        guard currentType == "account", !currentName.isEmpty else {
            lastError = text("添加账号前必须先切换到一个普通账号。")
            return
        }
        guard clientAvailability.canAddAccount else {
            lastError = text("新增账号需要先安装 ChatGPT 或 Codex CLI。未修改任何账号文件。")
            return
        }
        lastError = nil
        pendingAddAccountGroupID = nil
        pendingReauthenticationReplacementAccount = nil
        showsReauthenticationGroupOptions = false
        addAccountStage = text("准备添加新账号")
        showingAddAccount = true
    }

    func prepareReauthentication(for account: String) {
        guard accounts.first(where: { $0.name == account })?.authInvalid == true else { return }
        guard !isAddingAccount, !isSwitching, !isRefreshing, refreshingAccounts.isEmpty else {
            showNotice(text("请等待当前操作完成。"))
            return
        }
        guard currentType == "account", !currentName.isEmpty else { return }
        guard !isDetectingCodexCLI else {
            showNotice(text("正在检测 Codex CLI，请稍候。"))
            return
        }
        guard clientAvailability.canAddAccount else {
            lastError = text("重新登录需要先安装 ChatGPT 或 Codex CLI。未修改任何账号文件。")
            return
        }
        guard identities[account] != nil else {
            lastError = text("无法识别该账号原身份，不能安全替换凭据。")
            return
        }
        lastError = nil
        pendingAddAccountGroupID = groupID(for: account)
        pendingReauthenticationReplacementAccount = nil
        showsReauthenticationGroupOptions = false
        reauthenticatingAccount = account
        addAccountStage = text("准备重新登录 %@", displayName(for: account))
        showingAddAccount = true
    }

    func startAddAccount() {
        guard !isAddingAccount, !isRefreshing, refreshingAccounts.isEmpty,
              pendingSwitchAccount == nil, currentType == "account", !currentName.isEmpty else { return }
        guard !isDetectingCodexCLI, clientAvailability.canAddAccount else {
            showingAddAccount = false
            lastError = text("新增账号需要先安装 ChatGPT 或 Codex CLI。未修改任何账号文件。")
            return
        }
        let chatGPTURL = chatGPTApplicationURL
        let archivedName = currentName
        let reauthAccount = reauthenticatingAccount
        isAddingAccount = true
        addAccountUsesChatGPT = chatGPTURL != nil
        loginRequiresCLIRestart = isCodexCLIInstalled
        lastError = nil
        automaticTask?.cancel()
        resetRefreshTasks.values.forEach { $0.cancel() }
        addAccountStage = chatGPTURL == nil ? text("正在准备 Codex CLI 登录…") : text("正在关闭 ChatGPT…")
        loginWatchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await closeChatGPT(at: chatGPTURL)
                try Task.checkCancellation()
                if let reauthAccount {
                    reauthenticationSession = try AccountReauthenticationSession(
                        directory: codexDirectory,
                        stateDirectory: appDataDirectory,
                        currentAccount: archivedName,
                        targetAccount: reauthAccount
                    )
                } else {
                    loginSession = try AccountLoginSession(directory: codexDirectory, stateDirectory: appDataDirectory, account: archivedName)
                }
                isWaitingForLogin = true
                if let chatGPTURL {
                    addAccountStage = reauthAccount.map {
                        text("请在 ChatGPT 中重新登录 %@。登录数据只保存在本机；本应用不会上传或展示登录凭据。", displayName(for: $0))
                    } ?? text("请在 ChatGPT 中登录新账号。登录数据只保存在本机；本应用不会上传或展示登录凭据。")
                    try await NSWorkspace.shared.openApplication(at: chatGPTURL, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    addAccountStage = text("请打开终端运行 codex login，并在浏览器中完成登录。完成后请返回此处等待识别。")
                }
                try Task.checkCancellation()
                try await watchForNewLogin()
            } catch {
                // 取消由 cancelLoginWatch 统一恢复；旧任务不得重新打开检测或显示错误。
                guard !Task.isCancelled else { return }
                await restoreLoginSession(failure: error.localizedDescription)
            }
        }
    }

    func cancelLoginWatch() {
        guard !isCancellingLogin else { return }
        guard isAddingAccount else {
            let wasReauthentication = reauthenticatingAccount != nil
            showingAddAccount = false
            reauthenticatingAccount = nil
            pendingAddAccountGroupID = nil
            pendingReauthenticationReplacementAccount = nil
            showsReauthenticationGroupOptions = false
            showNotice(text(wasReauthentication ? "已取消重新登录" : "已取消添加账号"))
            return
        }
        isCancellingLogin = true
        addAccountStage = text(addAccountUsesChatGPT ? "正在关闭登录窗口并恢复原账号…" : "正在恢复原账号…")
        let previousTask = loginWatchTask
        previousTask?.cancel()
        Task {
            // 等待正在打开应用的操作结束，再关闭它，防止恢复后又弹出登录窗口。
            await previousTask?.value
            await restoreLoginSession(failure: nil)
            isCancellingLogin = false
        }
    }

    func addAccountSheetDidDismiss() {
        guard !isAddingAccount else { return }
        reauthenticatingAccount = nil
        pendingAddAccountGroupID = nil
        pendingReauthenticationReplacementAccount = nil
        showsReauthenticationGroupOptions = false
    }

    private func closeChatGPT(at applicationURL: URL? = nil) async throws {
        guard let applicationURL = applicationURL ?? chatGPTApplicationURL else { return }
        guard let bundleID = Bundle(url: applicationURL)?.bundleIdentifier else { return }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for application in applications { application.terminate() }
        for _ in 0..<50 {
            try Task.checkCancellation()
            if applications.allSatisfy({ $0.isTerminated }) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NSError(domain: "CodexSwitch5", code: 1, userInfo: [
            NSLocalizedDescriptionKey: text("ChatGPT 未能关闭，请手动关闭后重试。账号文件未修改。")
        ])
    }

    private func isChatGPTRunning(at applicationURL: URL?) -> Bool {
        guard let applicationURL,
              let bundleID = Bundle(url: applicationURL)?.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func restoreLoginSession(failure: String?) async {
        do {
            if let session = loginSession {
                try await closeChatGPT()
                try session.cancel()
            }
            if let session = reauthenticationSession {
                try await closeChatGPT()
                try session.cancel()
            }
            loginSession = nil
            reauthenticationSession = nil
            isAddingAccount = false
            isWaitingForLogin = false
            addAccountUsesChatGPT = false
            showingAddAccount = false
            let wasReauthentication = reauthenticatingAccount != nil
            reauthenticatingAccount = nil
            pendingAddAccountGroupID = nil
            pendingReauthenticationReplacementAccount = nil
            showsReauthenticationGroupOptions = false
            loadFromDisk()
            configureAutomaticRefresh()
            let shouldRemindAboutCLI = loginRequiresCLIRestart
            loginRequiresCLIRestart = false
            if let failure {
                lastError = text(wasReauthentication ? "重新登录失败，原账号已保留：%@" : "添加失败，原账号已保留：%@", failure)
            } else {
                lastError = nil
                showNotice(loginOutcomeNotice(
                    text(wasReauthentication ? "已取消重新登录" : "已取消添加账号"),
                    shouldRemindAboutCLI: shouldRemindAboutCLI
                ))
            }
        } catch {
            // 保留恢复对象和备份，允许用户退出登录应用后再次取消。
            addAccountStage = text("恢复未完成：%@", error.localizedDescription)
            lastError = addAccountStage
        }
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func requestRemove(_ account: String) {
        guard !isAddingAccount else { return }
        if currentType == "account" && currentName == account {
            lastError = text("当前正在使用的账号不能移除，请先切换到其他账号。")
            return
        }
        removingAccount = account
    }

    func confirmRemove() {
        guard !isAddingAccount else { return }
        guard let account = removingAccount else { return }
        let credential = codexDirectory.appendingPathComponent("auth.json.\(account)")
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: credential, resultingItemURL: &trashedURL)
            aliases.removeValue(forKey: account)
            saveAliases()
            updateAccountGroups { $0.assign(accounts: [account], to: nil) }
            removingAccount = nil
            loadFromDisk()
            status = text("已将 %@ 的凭据移到废纸篓", account)
        } catch {
            lastError = text("移除失败：%@", error.localizedDescription)
            removingAccount = nil
        }
    }

    func requestSwitch(to account: String) {
        guard !isAddingAccount, !isSwitching, !isRefreshing, refreshingAccounts.isEmpty else { return }
        guard !isDetectingCodexCLI else {
            showNotice(text("正在检测 Codex CLI，请稍候。"))
            return
        }
        pendingSwitchAccount = account
        showingSwitchConfirmation = true
    }

    func confirmSwitch() {
        guard !isAddingAccount, !isSwitching, !isRefreshing, refreshingAccounts.isEmpty else { return }
        guard let account = pendingSwitchAccount else { return }
        let sourceAccount = resolvedActiveAccountName() ?? ""
        guard !sourceAccount.isEmpty || !FileManager.default.fileExists(atPath: codexDirectory.appendingPathComponent("auth.json").path) else {
            showingSwitchConfirmation = false
            pendingSwitchAccount = nil
            lastError = text("无法根据实际凭据确认当前账号，已停止切换以避免覆盖账号文件。")
            return
        }
        if !sourceAccount.isEmpty { setActiveAccountState(sourceAccount) }
        currentType = sourceAccount.isEmpty ? "" : "account"
        currentName = sourceAccount
        guard sourceAccount != account else {
            showingSwitchConfirmation = false
            pendingSwitchAccount = nil
            status = text("该账号已在使用中")
            return
        }
        showingSwitchConfirmation = false
        isSwitching = true
        lastError = nil
        let installedChatGPTURL = chatGPTApplicationURL
        let shouldReopenChatGPT = isChatGPTRunning(at: installedChatGPTURL)
        status = shouldReopenChatGPT ? text("正在关闭 ChatGPT…") : text("正在切换到 %@…", account)
        Task {
            do {
                refreshTokenUsage()
                beginWeeklyQuotaProjectionIfNeeded(for: sourceAccount)
                let sourceRefresh = sourceAccount.isEmpty ? (code: Int32(1), output: "") : await runNativeOperation(["refresh", sourceAccount])
                loadFromDisk()
                refreshTokenUsage()
                if sourceRefresh.code == 0 { finishWeeklyQuotaProjection(for: sourceAccount) }
                if shouldReopenChatGPT {
                    try await closeChatGPT(at: installedChatGPTURL)
                }
                status = text("正在切换到 %@…", account)
                let result = await runNativeOperation(["switch", account])
                loadFromDisk()
                guard result.code == 0 else {
                    if sourceRefresh.code == 0 { beginWeeklyQuotaProjection(for: sourceAccount) }
                    recordSwitch(from: sourceAccount, to: account, result: .failure, message: result.output)
                    lastError = result.output
                    status = text("切换失败")
                    isSwitching = false
                    pendingSwitchAccount = nil
                    return
                }
                let switchedAt = Date()
                currentType = "account"
                currentName = account
                setActiveAccountState(account)
                recordSwitch(from: sourceAccount, to: account, result: .success, timestamp: switchedAt)
                try tokenTracker.recordAccountChange(account: account, at: switchedAt)
                refreshTokenUsage()
                let targetRefresh = await runNativeOperation(["refresh", account])
                loadFromDisk()
                refreshTokenUsage()
                if targetRefresh.code == 0 { beginWeeklyQuotaProjection(for: account) }
                if shouldReopenChatGPT, let installedChatGPTURL {
                    do {
                        try await NSWorkspace.shared.openApplication(at: installedChatGPTURL, configuration: NSWorkspace.OpenConfiguration())
                        status = text("已切换到 %@，已打开 ChatGPT", account)
                        showNotice(switchOutcomeNotice())
                    } catch {
                        status = text("账号已切换")
                        lastError = text("已切换账号，但无法打开 ChatGPT：%@", error.localizedDescription)
                        showNotice(switchOutcomeNotice())
                    }
                } else {
                    status = text("已切换到 %@，ChatGPT 未运行，已保持关闭", account)
                    showNotice(switchOutcomeNotice())
                }
            } catch {
                lastError = error.localizedDescription
                status = text("切换未开始")
            }
            isSwitching = false
            pendingSwitchAccount = nil
        }
    }

    private func recordSwitch(
        from: String,
        to: String,
        result: SwitchResult,
        message: String = "",
        timestamp: Date = Date()
    ) {
        guard from != to else { return }
        saveUsageHistory([.accountChanged(from: from, to: to, timestamp: timestamp, succeeded: result == .success)])
        do {
            switchHistory = try switchHistoryStore.append(SwitchHistoryRecord(
                timestamp: timestamp,
                fromAccount: from,
                toAccount: to,
                result: result,
                message: message
            ))
        } catch {
            lastError = text("无法保存切换记录：%@", error.localizedDescription)
        }
    }

    func refreshTokenUsage() {
        guard currentType == "account", !currentName.isEmpty else { return }
        do { tokenEvents = try tokenTracker.scan(account: currentName) }
        catch { lastError = text("无法读取 Token 统计：%@", error.localizedDescription) }
    }

    func tokenTotals(for account: String, period: TokenUsagePeriod, now: Date = Date()) -> TokenUsageTotals {
        let calendar = Calendar.current
        let start: Date
        switch period {
        case .fiveHours:
            let reset = accounts.first { $0.name == account }
                .flatMap { AccountRecommender.resetDate($0.fiveHourReset) }
            start = reset?.addingTimeInterval(-5 * 60 * 60) ?? now.addingTimeInterval(-5 * 60 * 60)
        case .today:
            start = calendar.startOfDay(for: now)
        case .currentWeek:
            start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
        case .currentMonth:
            start = calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
        case .weeklyQuotaCycle:
            let resetText = accounts.first { $0.name == account }?.weeklyResetAt
            let formatter = ISO8601DateFormatter()
            let reset = resetText.flatMap { formatter.date(from: $0) }
            guard let reset else { return TokenUsageTotals() }
            start = reset.addingTimeInterval(-7 * 24 * 60 * 60)
        }
        return tokenTracker.totals(events: tokenEvents, account: account, from: start, to: now)
    }

    func tokenTotals(from start: Date, to end: Date) -> TokenUsageTotals {
        tokenTracker.totals(events: tokenEvents, from: start, to: end)
    }

    func tokenTotals(period: TokenUsagePeriod, now: Date = Date()) -> TokenUsageTotals {
        accounts.reduce(into: TokenUsageTotals()) { total, account in
            let accountTotal = tokenTotals(for: account.name, period: period, now: now)
            total.input += accountTotal.input
            total.cachedInput += accountTotal.cachedInput
            total.cacheWriteInput += accountTotal.cacheWriteInput
            total.output += accountTotal.output
            total.reasoningOutput += accountTotal.reasoningOutput
            total.autoReviewTokens += accountTotal.autoReviewTokens
            total.estimatedUSD += accountTotal.estimatedUSD
            total.unpricedEvents += accountTotal.unpricedEvents
        }
    }

    func weeklyQuotaPeriodText(for account: String) -> String? {
        guard
            let resetText = accounts.first(where: { $0.name == account })?.weeklyResetAt,
            let reset = ISO8601DateFormatter().date(from: resetText)
        else { return nil }
        let start = reset.addingTimeInterval(-7 * 24 * 60 * 60)
        let format = Date.FormatStyle()
            .month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(appLanguage.locale)
        return text("开始 %@\n重置 %@", start.formatted(format), reset.formatted(format))
    }

    func fiveHourPeriodText(for account: String) -> String? {
        guard
            let resetText = accounts.first(where: { $0.name == account })?.fiveHourReset,
            let reset = AccountRecommender.resetDate(resetText)
        else { return nil }
        let start = reset.addingTimeInterval(-5 * 60 * 60)
        let format = Date.FormatStyle()
            .month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(appLanguage.locale)
        return text("开始 %@\n重置 %@", start.formatted(format), reset.formatted(format))
    }

    private func beginWeeklyQuotaProjection(for account: String) {
        guard let usage = accounts.first(where: { $0.name == account }),
              let resetAt = usage.weeklyResetAt else { return }
        let totals = tokenTotals(for: account, period: .weeklyQuotaCycle)
        try? weeklyQuotaProjectionStore.begin(
            account: account,
            resetAt: resetAt,
            remainingPercent: usage.weeklyRemaining,
            estimatedUSD: totals.estimatedUSD,
            unpricedEvents: totals.unpricedEvents
        )
        weeklyQuotaProjections = weeklyQuotaProjectionStore.projections()
    }

    private func beginWeeklyQuotaProjectionIfNeeded(for account: String) {
        guard currentType == "account", currentName == account,
              let usage = accounts.first(where: { $0.name == account }),
              let resetAt = usage.weeklyResetAt else { return }
        let totals = tokenTotals(for: account, period: .weeklyQuotaCycle)
        try? weeklyQuotaProjectionStore.beginIfNeeded(
            account: account,
            resetAt: resetAt,
            remainingPercent: usage.weeklyRemaining,
            estimatedUSD: totals.estimatedUSD,
            unpricedEvents: totals.unpricedEvents
        )
        weeklyQuotaProjections = weeklyQuotaProjectionStore.projections()
    }

    private func finishWeeklyQuotaProjection(for account: String) {
        guard let usage = accounts.first(where: { $0.name == account }),
              let resetAt = usage.weeklyResetAt else { return }
        let totals = tokenTotals(for: account, period: .weeklyQuotaCycle)
        _ = try? weeklyQuotaProjectionStore.finish(
            account: account,
            resetAt: resetAt,
            remainingPercent: usage.weeklyRemaining,
            estimatedUSD: totals.estimatedUSD,
            unpricedEvents: totals.unpricedEvents
        )
        weeklyQuotaProjections = weeklyQuotaProjectionStore.projections()
    }

    private func observeWeeklyQuotaProjection(for account: String) {
        guard let usage = accounts.first(where: { $0.name == account }),
              let resetAt = usage.weeklyResetAt else { return }
        let totals = tokenTotals(for: account, period: .weeklyQuotaCycle)
        _ = try? weeklyQuotaProjectionStore.observe(
            account: account,
            resetAt: resetAt,
            remainingPercent: usage.weeklyRemaining,
            estimatedUSD: totals.estimatedUSD,
            unpricedEvents: totals.unpricedEvents
        )
        weeklyQuotaProjections = weeklyQuotaProjectionStore.projections()
    }

    func configureAutomaticRefresh() {
        automaticTask?.cancel()
        guard automaticRefresh, !isAddingAccount, !isSwitching else { return }
        let value = max(refreshIntervalValue, 1)
        let seconds = refreshIntervalUnit == "seconds" ? value : value * 60
        automaticTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.refresh(automatic: true)
        }
    }

    private func configureResetRefreshes(now: Date = Date()) {
        resetRefreshTasks.values.forEach { $0.cancel() }
        resetRefreshTasks.removeAll()

        let eligible = accounts.compactMap { account -> (AccountUsage, Date, String)? in
            guard
                account.weeklyRemaining > 0,
                !account.authInvalid,
                let resetDate = AccountRecommender.resetDate(account.fiveHourReset)
            else { return nil }
            return (account, resetDate, "\(account.name)|\(account.fiveHourReset)")
        }
        let activeKeys = Set(eligible.map(\.2))
        triggeredResetKeys.formIntersection(activeKeys)

        for (account, resetDate, key) in eligible {
            if resetDate <= now {
                guard triggeredResetKeys.insert(key).inserted else { continue }
                refresh(account: account.name)
                continue
            }
            resetRefreshTasks[key] = Task { [weak self] in
                let seconds = resetDate.timeIntervalSinceNow
                if seconds > 0 {
                    try? await Task.sleep(for: .seconds(seconds))
                }
                guard !Task.isCancelled, let self else { return }
                guard self.triggeredResetKeys.insert(key).inserted else { return }
                self.resetRefreshTasks.removeValue(forKey: key)
                self.refresh(account: account.name)
            }
        }
    }

    private func runNativeOperation(_ arguments: [String]) async -> (code: Int32, output: String) {
        let isQuotaQuery = arguments.first == "refresh" || arguments.first == "refresh-auto"
        let startedAt = Date()
        let usageURL = appDataDirectory.appendingPathComponent("account_usage.json")
        let before = isQuotaQuery ? ((try? UsageStore.decode(Data(contentsOf: usageURL))) ?? []) : []
        let activeAccount = currentType == "account" ? currentName : nil
        let requested: Set<String>
        if !isQuotaQuery {
            requested = []
        } else if arguments.count > 1 {
            requested = [arguments[1]]
        } else {
            let skipped = arguments.first == "refresh-auto" ? Set(before.filter(\.authInvalid).map(\.name)) : []
            requested = knownAccountNames().subtracting(skipped)
        }
        let result: (code: Int32, output: String)
        do {
            if arguments.first == "switch", let target = arguments.dropFirst().first {
                try nativeAccountService.switchAccount(from: currentName, to: target)
                result = (0, text("账号已切换"))
            } else if isQuotaQuery {
                let skipInvalid = arguments.first == "refresh-auto" ? Set(before.filter(\.authInvalid).map(\.name)) : []
                _ = try await nativeAccountService.refresh(accounts: requested, currentAccount: currentName, skippingInvalid: skipInvalid)
                result = (0, text("额度已更新"))
            } else {
                result = (1, text("不支持的账号操作"))
            }
        } catch {
            result = (1, error.localizedDescription)
        }
        if isQuotaQuery {
            let after = (try? UsageStore.decode(Data(contentsOf: usageURL))) ?? []
            saveUsageHistory(UsageQueryHistory.events(
                before: before, after: after, requested: requested, startedAt: startedAt,
                finishedAt: Date(), activeAccount: activeAccount
            ))
        }
        return result
    }

    private func saveUsageHistory(_ events: [UsageHistoryEvent]) {
        do {
            let records = try usageHistoryStore.append(events)
            usageHistoryError = nil
            updateUsageLearning(records: records)
        } catch {
            usageHistoryError = text("无法保存使用历史，原文件已保留：%@", error.localizedDescription)
        }
    }

    func updateUsageLearning(records: [UsageHistoryEvent]? = nil, period: UsageLearningPeriod? = nil) {
        do {
            let records = try records ?? usageHistoryStore.load()
            if let period { usageLearningPeriod = period }
            let selectedPeriod = usageLearningPeriod
            usageLearningTask?.cancel()
            usageLearningTask = Task { [weak self] in
                let tokenEvents = self?.tokenEvents ?? []
                let summary = await Task.detached(priority: .utility) {
                    UsageLearning.summarize(records, tokenEvents: tokenEvents, period: selectedPeriod)
                }.value
                guard !Task.isCancelled else { return }
                self?.usageLearning = summary
            }
        } catch {
            usageHistoryError = text("无法读取使用历史，原文件已保留：%@", error.localizedDescription)
        }
    }

    func usageLearningPeriodText(now: Date = Date()) -> String {
        var calendar = Calendar.current
        let start: Date
        switch usageLearningPeriod {
        case .currentWeek:
            calendar.firstWeekday = 2
            calendar.minimumDaysInFirstWeek = 4
            start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        case .currentMonth:
            start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        case .lastThirtyDays:
            start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        }
        let format = Date.FormatStyle().month(.twoDigits).day(.twoDigits).locale(appLanguage.locale)
        return text("统计范围：%@ 至 %@", start.formatted(format), now.formatted(format))
    }

    private func watchForNewLogin() async throws {
        let authURL = codexDirectory.appendingPathComponent("auth.json")
        while true {
            try Task.checkCancellation()
            if let identity = identity(from: authURL), let reauthAccount = reauthenticatingAccount,
               let session = reauthenticationSession {
                guard let expected = identities[reauthAccount], identity == expected else {
                    addAccountStage = text("登录的账号与 %@ 不一致，请退出后重新登录正确账号。", displayName(for: reauthAccount))
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                try session.complete()
                let previousAccount = currentName
                let selectedGroupID = pendingAddAccountGroupID
                let changesGroup = showsReauthenticationGroupOptions
                let replacementAccount = changesGroup
                    ? validReauthenticationReplacementAccount(
                        pendingReauthenticationReplacementAccount,
                        targetAccount: reauthAccount,
                        groupID: selectedGroupID
                    )
                    : nil
                // 新凭据已成为 auth.json；必须先更新当前账号，后续加载和刷新才会读取活动凭据，
                // 而不是已清理的 auth.json.<账号> 旧存档。
                currentType = "account"
                currentName = reauthAccount
                setActiveAccountState(reauthAccount)
                try nativeAccountService.markAuthenticated(account: reauthAccount)
                reauthenticationSession = nil
                reauthenticatingAccount = nil
                isAddingAccount = false
                isWaitingForLogin = false
                addAccountUsesChatGPT = false
                showingAddAccount = false
                loadFromDisk()
                let groupAssignmentSaved = changesGroup && applyReauthenticationGroupAssignment(
                    account: reauthAccount,
                    to: selectedGroupID,
                    replacing: replacementAccount
                )
                pendingAddAccountGroupID = nil
                pendingReauthenticationReplacementAccount = nil
                showsReauthenticationGroupOptions = false
                recordAccountOperation(
                    action: .reauthenticate,
                    from: previousAccount,
                    to: reauthAccount,
                    selectedGroupID: selectedGroupID,
                    includesGroupAssignment: groupAssignmentSaved
                )
                configureAutomaticRefresh()
                let shouldRemindAboutCLI = loginRequiresCLIRestart
                loginRequiresCLIRestart = false
                showNotice(loginOutcomeNotice(
                    text("已重新登录 %@", displayName(for: reauthAccount)),
                    shouldRemindAboutCLI: shouldRemindAboutCLI
                ))
                refresh(account: reauthAccount)
                return
            } else if let identity = identity(from: authURL), let session = loginSession {
                let internalName = availableInternalName(for: identity)
                let previousAccount = currentName
                let selectedGroupID = pendingAddAccountGroupID
                let changesGroup = showsReauthenticationGroupOptions
                let replacementAccount = changesGroup
                    ? validReauthenticationReplacementAccount(
                        pendingReauthenticationReplacementAccount,
                        targetAccount: internalName,
                        groupID: selectedGroupID
                    )
                    : nil
                // 此处到登记完成没有等待点，取消不会插入到一半。
                try session.complete(account: internalName)
                currentType = "account"
                currentName = internalName
                setActiveAccountState(internalName)
                loginSession = nil
                isAddingAccount = false
                isWaitingForLogin = false
                addAccountUsesChatGPT = false
                showingAddAccount = false
                loadFromDisk()
                let groupAssignmentSaved = changesGroup && applyReauthenticationGroupAssignment(
                    account: internalName,
                    to: selectedGroupID,
                    replacing: replacementAccount
                )
                pendingAddAccountGroupID = nil
                pendingReauthenticationReplacementAccount = nil
                showsReauthenticationGroupOptions = false
                recordAccountOperation(
                    action: .addAccount,
                    from: previousAccount,
                    to: internalName,
                    selectedGroupID: selectedGroupID,
                    includesGroupAssignment: groupAssignmentSaved
                )
                configureAutomaticRefresh()
                let shouldRemindAboutCLI = loginRequiresCLIRestart
                loginRequiresCLIRestart = false
                showNotice(loginOutcomeNotice(
                    text("已添加 %@", displayName(for: internalName)),
                    shouldRemindAboutCLI: shouldRemindAboutCLI
                ))
                refresh(account: internalName)
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func switchOutcomeNotice() -> String {
        loginOutcomeNotice(text("账号已切换"), shouldRemindAboutCLI: isCodexCLIInstalled)
    }

    private func loginOutcomeNotice(_ outcome: String, shouldRemindAboutCLI: Bool) -> String {
        guard shouldRemindAboutCLI else { return outcome }
        return "\(outcome) \(text("如果你在使用 Codex CLI，请手动重启；否则无需操作。"))"
    }

    private func recordAccountOperation(
        action: AccountHistoryAction,
        from: String,
        to: String,
        selectedGroupID: UUID? = nil,
        includesGroupAssignment: Bool = false
    ) {
        saveUsageHistory([.accountChanged(from: from, to: to, timestamp: Date(), succeeded: true)])
        do {
            switchHistory = try switchHistoryStore.append(SwitchHistoryRecord(
                fromAccount: from,
                toAccount: to,
                result: .success,
                action: action,
                toGroup: groupName(for: selectedGroupID),
                includesGroupAssignment: includesGroupAssignment
            ))
        } catch {
            lastError = text("无法保存切换记录：%@", error.localizedDescription)
        }
    }

    private func startupAccounts() -> StartupAccounts {
        let markerURL = appDataDirectory.appendingPathComponent(".active-auth-profile")
        let marker = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "account ", with: "")
        let saved = UserDefaults.standard.string(forKey: "activeSwitch5Account")
        return StartupAccounts(directory: codexDirectory, preferredNames: [marker, saved].compactMap { $0 })
    }

    private func resolvedActiveAccountName() -> String? { startupAccounts().current }

    private func setActiveAccountState(_ account: String) {
        UserDefaults.standard.set(account, forKey: "activeSwitch5Account")
        do {
            try FileManager.default.createDirectory(at: appDataDirectory, withIntermediateDirectories: true)
            let markerURL = appDataDirectory.appendingPathComponent(".active-auth-profile")
            try Data("account \(account)\n".utf8).write(to: markerURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        } catch {
            // UserDefaults 仍可用于下次识别；写入错误会在实际文件操作时再次暴露。
        }
    }

    private func knownAccountNames() -> Set<String> { startupAccounts().names }

    private func loadAliases() -> [String: String] {
        let url = appDataDirectory.appendingPathComponent("account_aliases.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveAliases() {
        let url = appDataDirectory.appendingPathComponent("account_aliases.json")
        try? FileManager.default.createDirectory(at: appDataDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func groupID(for account: String) -> UUID? { accountGroupState.accountGroupIDs[account] }

    func reauthenticationReplacementCandidates(for groupID: UUID?, excluding account: String? = nil) -> [String] {
        guard let groupID else { return [] }
        return accounts
            .map(\.name)
            .filter { $0 != account && accountGroupState.accountGroupIDs[$0] == groupID }
            .sorted { displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending }
    }

    func clearInvalidReauthenticationReplacement() {
        pendingReauthenticationReplacementAccount = validReauthenticationReplacementAccount(
            pendingReauthenticationReplacementAccount,
            targetAccount: reauthenticatingAccount,
            groupID: pendingAddAccountGroupID
        )
    }

    @discardableResult
    func createAccountGroup(name: String) -> UUID? {
        var createdID: UUID?
        updateAccountGroups { createdID = try $0.createGroup(named: name).id }
        return createdID
    }

    func renameAccountGroup(id: UUID, name: String) {
        updateAccountGroups { try $0.renameGroup(id: id, to: name) }
    }

    func deleteAccountGroup(id: UUID) {
        let affectedAccounts = Set(accountGroupState.accountGroupIDs.compactMap { $0.value == id ? $0.key : nil })
        let previous = accountGroupState
        if updateAccountGroups({ $0.deleteGroup(id: id) }) {
            recordGroupChanges(for: affectedAccounts, from: previous, to: accountGroupState)
        }
    }

    func assignAccounts(_ accounts: Set<String>, to groupID: UUID?) {
        let previous = accountGroupState
        if updateAccountGroups({ $0.assign(accounts: accounts, to: groupID) }) {
            recordGroupChanges(for: accounts, from: previous, to: accountGroupState)
        }
    }

    private func validReauthenticationReplacementAccount(
        _ account: String?,
        targetAccount: String?,
        groupID: UUID?
    ) -> String? {
        guard let account, let targetAccount,
              reauthenticationReplacementCandidates(for: groupID, excluding: targetAccount).contains(account)
        else { return nil }
        return account
    }

    private func applyReauthenticationGroupAssignment(
        account: String,
        to groupID: UUID?,
        replacing replacementAccount: String?
    ) -> Bool {
        let previous = accountGroupState
        let changedAccounts = Set([account, replacementAccount].compactMap { $0 })
        let succeeded = updateAccountGroups { state in
            state.assignReauthenticatedAccount(account, to: groupID, replacing: replacementAccount)
        }
        if succeeded {
            recordGroupChanges(for: changedAccounts, from: previous, to: accountGroupState)
        }
        return succeeded
    }

    @discardableResult
    func replaceAccounts(in groupID: UUID?, with accounts: Set<String>) -> Bool {
        let previous = accountGroupState
        let succeeded = updateAccountGroups { state in
            if let groupID {
                let removedAccounts = Set(state.accountGroupIDs.compactMap { account, assignedGroupID in
                    assignedGroupID == groupID && !accounts.contains(account) ? account : nil
                })
                state.assign(accounts: removedAccounts, to: nil)
                state.assign(accounts: accounts, to: groupID)
            } else {
                state.assign(accounts: accounts, to: nil)
            }
        }
        if succeeded {
            let changedAccounts = Set(previous.accountGroupIDs.keys).union(accountGroupState.accountGroupIDs.keys).union(accounts)
            recordGroupChanges(for: changedAccounts, from: previous, to: accountGroupState)
        }
        return succeeded
    }

    private func groupName(for id: UUID?, in state: AccountGroupState? = nil) -> String? {
        guard let id else { return nil }
        return (state ?? accountGroupState).groups.first(where: { $0.id == id })?.name
    }

    private func recordGroupChanges(
        for accounts: Set<String>,
        from previous: AccountGroupState,
        to current: AccountGroupState
    ) {
        for account in accounts.sorted() {
            let previousID = previous.accountGroupIDs[account]
            let currentID = current.accountGroupIDs[account]
            guard previousID != currentID else { continue }
            do {
                switchHistory = try switchHistoryStore.append(SwitchHistoryRecord(
                    fromAccount: account,
                    toAccount: account,
                    result: .success,
                    action: .changeGroup,
                    fromGroup: groupName(for: previousID, in: previous),
                    toGroup: groupName(for: currentID, in: current),
                    includesGroupAssignment: true
                ))
            } catch {
                lastError = text("无法保存切换记录：%@", error.localizedDescription)
            }
        }
    }

    private func loadAccountGroups() {
        do {
            accountGroupState = try accountGroupStore.load(validAccounts: Set(accounts.map(\.name)))
            accountGroupError = nil
        } catch {
            accountGroupState = AccountGroupState()
            accountGroupError = text("无法读取账号分组：%@", error.localizedDescription)
        }
    }

    @discardableResult
    private func updateAccountGroups(_ change: (inout AccountGroupState) throws -> Void) -> Bool {
        let previous = accountGroupState
        do {
            try change(&accountGroupState)
            try accountGroupStore.save(accountGroupState)
            accountGroupError = nil
            return true
        } catch {
            accountGroupState = previous
            accountGroupError = error.localizedDescription
            return false
        }
    }

    private func migrateLegacyAutomaticAliasesIfNeeded() {
        guard !didMigrateEmailDefaultNames else { return }
        aliases = aliases.filter { account, alias in
            let original = identities[account]?.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
            return alias.trimmingCharacters(in: .whitespacesAndNewlines) != original
        }
        saveAliases()
        didMigrateEmailDefaultNames = true
    }

    private func loadIdentities(for names: Set<String>) -> [String: AccountIdentity] {
        var result: [String: AccountIdentity] = [:]
        for name in names {
            let url = currentType == "account" && currentName == name
                ? codexDirectory.appendingPathComponent("auth.json")
                : codexDirectory.appendingPathComponent("auth.json.\(name)")
            if let value = identity(from: url) { result[name] = value }
        }
        return result
    }

    private func identity(from url: URL) -> AccountIdentity? {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let idToken = tokens["id_token"] as? String,
            let payload = decodeJWTPayload(idToken)
        else { return nil }
        let name = payload["name"] as? String ?? ""
        let email = payload["email"] as? String ?? ""
        guard !name.isEmpty || !email.isEmpty else { return nil }
        return AccountIdentity(originalName: name.isEmpty ? email : name, email: email)
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func availableInternalName(for identity: AccountIdentity) -> String {
        let source = identity.email.split(separator: "@", maxSplits: 1).first.map(String.init)
            ?? (identity.originalName.isEmpty ? "account" : identity.originalName)
        let allowed = source.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "_"
        }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = allowed.isEmpty ? "account" : allowed
        let existing = knownAccountNames()
        if !existing.contains(base) { return base }
        var number = 2
        while existing.contains("\(base)_\(number)") { number += 1 }
        return "\(base)_\(number)"
    }
}
