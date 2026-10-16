import CodexSwitch5Core
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class QuotaRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequest: URLRequest?

    func record(_ request: URLRequest) {
        lock.lock()
        recordedRequest = request
        lock.unlock()
    }

    func request() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest
    }
}

private final class QuotaMockURLProtocol: URLProtocol {
    static let recorder = QuotaRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "chatgpt.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder.record(request)
        let body: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 100.0, "reset_at": 2_000_000_000.0],
                "secondary_window": ["used_percent": 47.0, "reset_at": 2_000_604_800.0],
            ],
            "rate_limit_reset_credits": ["available_count": 0],
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class QuotaPauseResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode = 402
    private var requestCount = 0

    func response() -> (statusCode: Int, requestCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        return (statusCode, requestCount)
    }

    func succeed() {
        lock.lock()
        statusCode = 200
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }
}

private final class QuotaPauseMockURLProtocol: URLProtocol {
    static let state = QuotaPauseResponseState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "chatgpt.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let responseState = Self.state.response()
        let body: [String: Any] = responseState.statusCode == 200 ? [
            "rate_limit": [
                "primary_window": ["used_percent": 25.0, "reset_at": 2_000_000_000.0],
                "secondary_window": ["used_percent": 50.0, "reset_at": 2_000_604_800.0],
            ],
            "rate_limit_reset_credits": ["available_count": 0],
        ] : [:]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responseState.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func checkQuotaRequestIsolation() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("quota-request-isolation-\(UUID().uuidString)")
    let codexDirectory = root.appendingPathComponent(".codex")
    try files.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let credential = try JSONSerialization.data(withJSONObject: [
        "tokens": [
            "access_token": "test-access-token",
            "account_id": "test-account-id",
        ],
    ])
    try credential.write(to: codexDirectory.appendingPathComponent("auth.json.account"))

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QuotaMockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer {
        session.invalidateAndCancel()
        try? files.removeItem(at: root)
    }

    let service = NativeAccountService(
        codexDirectory: codexDirectory,
        usageURL: root.appendingPathComponent("account_usage.json"),
        session: session
    )
    let results = try await service.refresh(accounts: ["account"], currentAccount: nil)
    guard let usage = results.first(where: { $0.name == "account" }) else {
        preconditionFailure("额度刷新结果缺少测试账号")
    }
    precondition(usage.fiveHourRemaining == 0, "接口返回已用 100% 时必须保存剩余 0%")
    precondition(usage.weeklyRemaining == 53, "周额度换算结果错误")

    guard let request = QuotaMockURLProtocol.recorder.request() else {
        preconditionFailure("没有捕获到额度请求")
    }
    precondition(request.cachePolicy == .reloadIgnoringLocalCacheData, "额度请求必须跳过本地网络缓存")
    precondition(request.httpShouldHandleCookies == false, "额度请求必须禁用 Cookie")
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
    precondition(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "test-account-id")
    precondition(request.value(forHTTPHeaderField: "User-Agent") == "Codex Switch5")
    print("额度请求隔离检查通过：忽略本地缓存、禁用 Cookie，并保留身份请求头。")
}

func checkQuotaAutomaticRefreshPause() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("quota-pause-\(UUID().uuidString)")
    let codexDirectory = root.appendingPathComponent(".codex")
    let usageURL = root.appendingPathComponent("account_usage.json")
    try files.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }

    let credential = try JSONSerialization.data(withJSONObject: [
        "tokens": ["access_token": "test-access-token", "account_id": "test-account-id"],
    ])
    try credential.write(to: codexDirectory.appendingPathComponent("auth.json.account"))
    let oldUsage: [String: Any] = [
        "account": [
            "five_hour_remaining": 88,
            "five_hour_reset": "2026-10-16 20:00",
            "weekly_remaining": 77,
            "weekly_reset": "10.22",
            "reset_cards": 2,
            "auth_invalid": false,
            "noted_at": "2026-10-16T08:00:00Z",
        ],
    ]
    try JSONSerialization.data(withJSONObject: oldUsage).write(to: usageURL)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QuotaPauseMockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let service = NativeAccountService(codexDirectory: codexDirectory, usageURL: usageURL, session: session)

    do {
        _ = try await service.refresh(accounts: ["account"], currentAccount: nil)
        preconditionFailure("HTTP 402 应报告本次查询失败")
    } catch NativeAccountServiceError.partialFailure(let accounts) {
        precondition(accounts == ["account"])
    }
    let paused = try UsageStore.decode(Data(contentsOf: usageURL)).first!
    precondition(paused.automaticRefreshPaused, "HTTP 402 后没有暂停自动查询")
    precondition(paused.fiveHourRemaining == 88 && paused.weeklyRemaining == 77, "暂停后没有保留最后有效额度")
    precondition(AccountRecommender.next(from: [paused], currentAccount: nil) == nil, "暂停账号不应成为推荐账号")
    let countAfterFailure = QuotaPauseMockURLProtocol.state.count()

    _ = try await service.refresh(
        accounts: ["account"],
        currentAccount: nil,
        skippingAccounts: ["account"]
    )
    precondition(QuotaPauseMockURLProtocol.state.count() == countAfterFailure, "自动刷新没有跳过暂停账号")

    QuotaPauseMockURLProtocol.state.succeed()
    let recovered = try await service.refresh(accounts: ["account"], currentAccount: nil).first!
    precondition(!recovered.automaticRefreshPaused, "手动查询成功后没有解除暂停")
    precondition(recovered.fiveHourRemaining == 75 && recovered.weeklyRemaining == 50)
    print("不可查询账号检查通过：HTTP 402 暂停自动查询、保留旧额度，手动成功后恢复。")
}
