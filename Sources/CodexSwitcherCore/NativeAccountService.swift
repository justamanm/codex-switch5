import Foundation

/// 原生账号切换与额度查询。凭据始终留在 Codex 目录，服务不返回或持久化凭据内容。
public struct NativeAccountService: Sendable {
    public let codexDirectory: URL
    public let usageURL: URL
    public let usageHistoryURL: URL?
    private let session: URLSession

    public init(codexDirectory: URL, usageURL: URL, usageHistoryURL: URL? = nil, session: URLSession = .shared) {
        self.codexDirectory = codexDirectory
        self.usageURL = usageURL
        self.usageHistoryURL = usageHistoryURL
        self.session = session
    }

    public func refresh(accounts: Set<String>, currentAccount: String?, skippingInvalid: Set<String> = []) async throws -> [AccountUsage] {
        var records = try loadUsage()
        for account in accounts.sorted() where !skippingInvalid.contains(account) {
            do {
                records[account] = try await query(account: account, currentAccount: currentAccount)
            } catch let error as NativeAccountServiceError where error.isAuthenticationFailure {
                records[account] = invalidUsage(account: account, previous: records[account])
            }
        }
        try saveUsage(records)
        return records.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 新凭据已经过账号身份核对后，立即清除旧凭据留下的失效标记。
    /// 额度数值及记录时间保持不变，等待随后的额度查询更新。
    public func markAuthenticated(account: String) throws {
        try validateName(account)
        var records = try loadUsage()
        guard let old = records[account], old.authInvalid else { return }
        records[account] = AccountUsage(
            name: old.name,
            fiveHourRemaining: old.fiveHourRemaining,
            fiveHourReset: old.fiveHourReset,
            weeklyRemaining: old.weeklyRemaining,
            weeklyReset: old.weeklyReset,
            weeklyResetAt: old.weeklyResetAt,
            resetCards: old.resetCards,
            creditBalance: old.creditBalance,
            authInvalid: false,
            notedAt: old.notedAt
        )
        try saveUsage(records)
    }

    /// 登录失效只改变状态，不丢弃最后一次成功查询到的额度和重置时间。
    /// 若旧版本已经写入错误占位值，则尝试从额度查询历史恢复。
    public func markAuthenticationInvalid(account: String) throws {
        try validateName(account)
        var records = try loadUsage()
        records[account] = invalidUsage(account: account, previous: records[account])
        try saveUsage(records)
    }

    /// 修复旧版本为失效账号写入的当前时间占位值。没有历史记录时保持原样。
    @discardableResult
    public func restoreInvalidUsageFromHistory() throws -> Int {
        var records = try loadUsage()
        var restoredCount = 0
        for (account, old) in records where old.authInvalid {
            guard let retained = latestSuccessfulUsage(account: account) else { continue }
            let restored = invalidUsage(account: account, previous: retained)
            guard restored != old else { continue }
            records[account] = restored
            restoredCount += 1
        }
        if restoredCount > 0 { try saveUsage(records) }
        return restoredCount
    }

    public func switchAccount(from current: String, to target: String) throws {
        guard current != target else { return }
        try validateName(current); try validateName(target)
        let files = FileManager.default
        let active = codexDirectory.appendingPathComponent("auth.json")
        let targetArchive = codexDirectory.appendingPathComponent("auth.json.\(target)")
        let currentArchive = codexDirectory.appendingPathComponent("auth.json.\(current)")
        guard files.fileExists(atPath: active.path), files.fileExists(atPath: targetArchive.path) else {
            throw NativeAccountServiceError.invalidCredentials("找不到当前或目标账号凭据")
        }
        let hasStaleCurrentArchive = files.fileExists(atPath: currentArchive.path)
        if hasStaleCurrentArchive {
            guard credentialIdentity(at: active) == credentialIdentity(at: currentArchive),
                  credentialIdentity(at: active) != nil else {
                throw NativeAccountServiceError.invalidCredentials("活动凭据与当前账号存档不一致，已停止以避免覆盖")
            }
        }
        let temporary = codexDirectory.appendingPathComponent(".codex-switch5-auth-\(UUID().uuidString)")
        let staleArchive = codexDirectory.appendingPathComponent(".codex-switch5-stale-\(UUID().uuidString)")
        var targetInstalled = false
        var sourceArchived = false
        do {
            if hasStaleCurrentArchive {
                try files.moveItem(at: currentArchive, to: staleArchive)
            }
            try files.moveItem(at: active, to: temporary)
            try files.moveItem(at: targetArchive, to: active)
            targetInstalled = true
            try files.moveItem(at: temporary, to: currentArchive)
            sourceArchived = true
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: active.path)
            if hasStaleCurrentArchive { try files.removeItem(at: staleArchive) }
        } catch {
            // 依次还原目标和原账号；不覆盖任何意外出现的文件。
            if targetInstalled,
               files.fileExists(atPath: active.path),
               !files.fileExists(atPath: targetArchive.path) {
                try? files.moveItem(at: active, to: targetArchive)
            }
            if sourceArchived,
               files.fileExists(atPath: currentArchive.path),
               !files.fileExists(atPath: temporary.path) {
                try? files.moveItem(at: currentArchive, to: temporary)
            }
            if files.fileExists(atPath: temporary.path), !files.fileExists(atPath: active.path) {
                try? files.moveItem(at: temporary, to: active)
            }
            if files.fileExists(atPath: staleArchive.path), !files.fileExists(atPath: currentArchive.path) {
                try? files.moveItem(at: staleArchive, to: currentArchive)
            }
            throw error
        }
    }

    private func credentialIdentity(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else { return nil }
        if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
            return "account:\(accountID)"
        }
        guard let idToken = tokens["id_token"] as? String else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let payloadData = Data(base64Encoded: value),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }
        if let subject = payload["sub"] as? String, !subject.isEmpty { return "subject:\(subject)" }
        if let email = payload["email"] as? String, !email.isEmpty { return "email:\(email.lowercased())" }
        return nil
    }

    private func query(account: String, currentAccount: String?) async throws -> AccountUsage {
        try validateName(account)
        let path = account == currentAccount ? codexDirectory.appendingPathComponent("auth.json") : codexDirectory.appendingPathComponent("auth.json.\(account)")
        let data = try Data(contentsOf: path)
        guard var auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw NativeAccountServiceError.invalidCredentials("账号凭据缺少 access_token")
        }
        do {
            return try await requestUsage(account: account, accessToken: access, accountID: tokens["account_id"] as? String)
        } catch NativeAccountServiceError.http(401) {
            guard let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else { throw NativeAccountServiceError.authenticationExpired }
            let refreshed = try await refreshToken(refresh)
            for key in ["id_token", "access_token", "refresh_token"] {
                if let value = refreshed[key] as? String, !value.isEmpty { tokens[key] = value }
            }
            guard let newAccess = tokens["access_token"] as? String, !newAccess.isEmpty else { throw NativeAccountServiceError.authenticationExpired }
            auth["tokens"] = tokens
            auth["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            try atomicJSON(auth, to: path, permissions: 0o600)
            return try await requestUsage(account: account, accessToken: newAccess, accountID: tokens["account_id"] as? String)
        }
    }

    private func requestUsage(account: String, accessToken: String, accountID: String?) async throws -> AccountUsage {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Switch5", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeAccountServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NativeAccountServiceError.http(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limit = object["rate_limit"] as? [String: Any],
              let primary = limit["primary_window"] as? [String: Any],
              let secondary = limit["secondary_window"] as? [String: Any] else { throw NativeAccountServiceError.invalidResponse }
        func remaining(_ value: [String: Any]) throws -> Int {
            guard let used = value["used_percent"] as? Double else { throw NativeAccountServiceError.invalidResponse }
            return max(0, min(100, Int((100 - used).rounded())))
        }
        func reset(_ value: [String: Any]) throws -> Date {
            guard let seconds = value["reset_at"] as? Double else { throw NativeAccountServiceError.invalidResponse }
            return Date(timeIntervalSince1970: seconds)
        }
        let five = try reset(primary), weekly = try reset(secondary)
        let credits = object["rate_limit_reset_credits"] as? [String: Any]
        let balance = (object["credits"] as? [String: Any])?["balance"] as? Double
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return AccountUsage(name: account, fiveHourRemaining: try remaining(primary), fiveHourReset: formatter.string(from: five), weeklyRemaining: try remaining(secondary), weeklyReset: "\(Calendar.current.component(.month, from: weekly)).\(Calendar.current.component(.day, from: weekly))", weeklyResetAt: ISO8601DateFormatter().string(from: weekly), resetCards: credits?["available_count"] as? Int ?? 0, creditBalance: balance, authInvalid: false, notedAt: ISO8601DateFormatter().string(from: Date()))
    }

    private func refreshToken(_ token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "grant_type": "refresh_token", "refresh_token": token])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NativeAccountServiceError.authenticationExpired }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeAccountServiceError.invalidResponse }
        return object
    }

    private func loadUsage() throws -> [String: AccountUsage] {
        guard FileManager.default.fileExists(atPath: usageURL.path) else { return [:] }
        return Dictionary(uniqueKeysWithValues: try UsageStore.decode(Data(contentsOf: usageURL)).map { ($0.name, $0) })
    }
    private func saveUsage(_ values: [String: AccountUsage]) throws {
        let object = try Dictionary(uniqueKeysWithValues: values.map { key, value in
            let data = try JSONEncoder().encode(value); return (key, try JSONSerialization.jsonObject(with: data))
        })
        try atomicJSON(object, to: usageURL, permissions: 0o600)
    }
    private func invalidUsage(account: String, previous: AccountUsage?) -> AccountUsage {
        let retained = previous.flatMap { $0.authInvalid ? latestSuccessfulUsage(account: account) : $0 }
            ?? latestSuccessfulUsage(account: account)
        if let retained {
            return AccountUsage(
                name: account,
                fiveHourRemaining: retained.fiveHourRemaining,
                fiveHourReset: retained.fiveHourReset,
                weeklyRemaining: retained.weeklyRemaining,
                weeklyReset: retained.weeklyReset,
                weeklyResetAt: retained.weeklyResetAt,
                resetCards: retained.resetCards,
                creditBalance: retained.creditBalance,
                authInvalid: true,
                notedAt: retained.notedAt
            )
        }
        let now = Date(); let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return AccountUsage(name: account, fiveHourRemaining: 0, fiveHourReset: formatter.string(from: now), weeklyRemaining: 0, weeklyReset: "\(Calendar.current.component(.month, from: now)).\(Calendar.current.component(.day, from: now))", resetCards: 0, authInvalid: true, notedAt: ISO8601DateFormatter().string(from: now))
    }

    private func latestSuccessfulUsage(account: String) -> AccountUsage? {
        guard let usageHistoryURL,
              let events = try? UsageHistoryStore(url: usageHistoryURL).load(),
              let observation = events.reversed().compactMap({ event -> QuotaObservation? in
                  guard case .observation(let value) = event, value.account == account else { return nil }
                  return value
              }).first else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let weeklyReset = observation.weeklyReset.map {
            "\(Calendar.current.component(.month, from: $0)).\(Calendar.current.component(.day, from: $0))"
        } ?? ""
        return AccountUsage(
            name: account,
            fiveHourRemaining: observation.fiveHourRemaining,
            fiveHourReset: observation.fiveHourReset.map(dateFormatter.string) ?? "",
            weeklyRemaining: observation.weeklyRemaining,
            weeklyReset: weeklyReset,
            weeklyResetAt: observation.weeklyReset.map(ISO8601DateFormatter().string),
            resetCards: observation.resetCards,
            authInvalid: false,
            notedAt: ISO8601DateFormatter().string(from: observation.timestamp)
        )
    }
    private func atomicJSON(_ object: Any, to url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
    private func validateName(_ name: String) throws { guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { throw NativeAccountServiceError.invalidCredentials("账号名称无效") } }
}

public enum NativeAccountServiceError: LocalizedError, Sendable { case http(Int), authenticationExpired, invalidCredentials(String), invalidResponse
    public var errorDescription: String? { switch self { case .http(let code): "查询用量失败（HTTP \(code)）"; case .authenticationExpired: "登录令牌已失效，请重新登录账号。"; case .invalidCredentials(let message): message; case .invalidResponse: "用量服务返回了无法识别的数据。" } }
    var isAuthenticationFailure: Bool { if case .authenticationExpired = self { true } else { false } }
}
