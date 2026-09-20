import Foundation

public enum TokenUsagePeriod: CaseIterable, Sendable { case fiveHours, today, currentWeek, currentMonth, weeklyQuotaCycle }

public struct TokenUsageTotals: Equatable, Sendable {
    public var input = 0
    public var cachedInput = 0
    public var cacheWriteInput = 0
    public var output = 0
    public var reasoningOutput = 0
    public var autoReviewTokens = 0
    public var estimatedUSD = 0.0
    public var unpricedEvents = 0
    public init() {}
    public var total: Int { input + output }
}

public struct TokenUsageEvent: Codable, Equatable, Sendable {
    public let id: String
    public let account: String
    public let timestamp: Date
    public let model: String
    public let input: Int
    public let cachedInput: Int
    public let cacheWriteInput: Int
    public let output: Int
    public let reasoningOutput: Int

    public init(id: String, account: String, timestamp: Date, model: String, input: Int, cachedInput: Int, cacheWriteInput: Int, output: Int, reasoningOutput: Int) {
        self.id = id
        self.account = account
        self.timestamp = timestamp
        self.model = model
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoningOutput = reasoningOutput
    }
}

public enum ModelPricing {
    private struct Rate { let input: Double; let cached: Double; let output: Double }
    private static let rates: [String: Rate] = [
        "gpt-6-astra": .init(input: 10, cached: 1, output: 50),
        "gpt-5.6-sol": .init(input: 4, cached: 0.4, output: 20),
        "gpt-5.6": .init(input: 4, cached: 0.4, output: 20),
        "gpt-5.6-terra": .init(input: 2, cached: 0.2, output: 12),
        "gpt-5.6-luna": .init(input: 0.2, cached: 0.02, output: 1.2),
    ]

    public static func estimatedUSD(for event: TokenUsageEvent) -> Double? {
        guard let rate = rates[event.model] else { return nil }
        let uncached = max(0, event.input - event.cachedInput - event.cacheWriteInput)
        let amount = Double(uncached) * rate.input
            + Double(event.cachedInput) * rate.cached
            + Double(event.cacheWriteInput) * rate.input * 1.25
            + Double(event.output) * rate.output
        return amount / 1_000_000
    }
}

public final class TokenUsageTracker: @unchecked Sendable {
    private struct LegacyActivation: Codable {
        let account: String
        let timestamp: Date
    }

    private struct LegacyState: Codable {
        let activeAccount: String
        let cursors: [String: UInt64]
        let models: [String: String]
        let events: [TokenUsageEvent]
        let timeline: [LegacyActivation]?
    }

    private struct SessionFile {
        let url: URL
        let sourceID: String
        let fileIdentifier: String
        let size: UInt64
    }

    private let roots: [URL]
    public let database: UsageDatabase
    private let legacyStateURL: URL?
    private let now: @Sendable () -> Date
    private let decoder = JSONDecoder()

    public init(
        roots: [URL],
        database: UsageDatabase,
        legacyStateURL: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.roots = roots
        self.database = database
        self.legacyStateURL = legacyStateURL
        self.now = now
        decoder.dateDecodingStrategy = .iso8601
    }

    public convenience init(
        roots: [URL], stateURL: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            roots: roots,
            database: UsageDatabase(url: stateURL.deletingLastPathComponent().appendingPathComponent("codex_switch5.sqlite3")),
            legacyStateURL: stateURL,
            now: now
        )
    }

    /// 扫描新增会话行，并返回最近 30 天记录供使用习惯页计算。
    @discardableResult
    public func scan(account: String) throws -> [TokenUsageEvent] {
        try database.prepare()
        let files = sessionFiles()
        if try database.metadataValue(for: "token_tracking_initialized") == nil {
            if try !importLegacyStateIfNeeded(files: files) {
                try database.initializeTokenTracking(
                    account: account,
                    at: now(),
                    cursors: files.map {
                        SessionCursor(
                            sourceID: $0.sourceID, path: $0.url.path, offset: $0.size,
                            fileSize: $0.size, fileIdentifier: $0.fileIdentifier
                        )
                    }
                )
                return []
            }
        }

        var activations = try database.accountActivations()
        if activations.isEmpty {
            let activation = AccountActivationRecord(account: account, timestamp: now())
            try database.appendAccountActivation(account: activation.account, timestamp: activation.timestamp)
            activations = [activation]
        }

        var additions: [TokenUsageEvent] = []
        var changedCursors: [SessionCursor] = []
        for file in files {
            var cursor = try database.cursor(for: file.sourceID)
                ?? database.cursor(matchingPath: file.url.path)
                ?? SessionCursor(
                    sourceID: file.sourceID, path: file.url.path, offset: 0,
                    fileSize: file.size, fileIdentifier: file.fileIdentifier
                )
            if cursor.sourceID != file.sourceID {
                cursor = SessionCursor(
                    sourceID: file.sourceID, path: file.url.path, offset: cursor.offset,
                    fileSize: cursor.fileSize, fileIdentifier: file.fileIdentifier,
                    generation: cursor.generation, model: cursor.model
                )
            }
            if file.size == cursor.fileSize, cursor.offset == file.size, cursor.path == file.url.path,
               cursor.fileIdentifier == file.fileIdentifier { continue }

            var start = cursor.offset
            var generation = cursor.generation
            var model = cursor.model
            if file.size < start || cursor.fileIdentifier != file.fileIdentifier {
                start = 0
                generation += 1
                model = nil
            }
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else {
                changedCursors.append(SessionCursor(
                    sourceID: file.sourceID, path: file.url.path, offset: start,
                    fileSize: file.size, fileIdentifier: file.fileIdentifier,
                    generation: generation, model: model
                ))
                continue
            }
            if model == nil, start > 0 { model = modelBeforeOffset(in: file.url, offset: start) }
            guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let complete = data.prefix(through: lastNewline)
            var lineStart = complete.startIndex
            while lineStart < complete.endIndex {
                guard let newline = complete[lineStart...].firstIndex(of: 0x0A) else { break }
                process(
                    line: Data(complete[lineStart..<newline]), sourceID: file.sourceID,
                    generation: generation, offset: start + UInt64(lineStart),
                    activations: activations, model: &model, records: &additions
                )
                lineStart = complete.index(after: newline)
            }
            changedCursors.append(SessionCursor(
                sourceID: file.sourceID, path: file.url.path,
                offset: start + UInt64(complete.count), fileSize: file.size,
                fileIdentifier: file.fileIdentifier, generation: generation, model: model
            ))
        }
        try database.saveScan(records: additions, cursors: changedCursors)
        if activations.last?.account != account {
            try database.appendAccountActivation(account: account, timestamp: now())
        }
        try performDailyRetentionIfNeeded()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now()) ?? .distantPast
        return try database.tokenUsageRecords(from: start, to: .distantFuture)
    }

    public func recordAccountChange(account: String, at timestamp: Date = Date()) throws {
        try database.prepare()
        if try database.metadataValue(for: "token_tracking_initialized") == nil {
            let files = sessionFiles()
            try database.initializeTokenTracking(
                account: account, at: timestamp,
                cursors: files.map {
                    SessionCursor(
                        sourceID: $0.sourceID, path: $0.url.path, offset: $0.size,
                        fileSize: $0.size, fileIdentifier: $0.fileIdentifier
                    )
                }
            )
            return
        }
        guard try database.accountActivations().last?.account != account else { return }
        try database.appendAccountActivation(account: account, timestamp: timestamp)
    }

    public func totals(account: String? = nil, from start: Date, to end: Date = Date()) throws -> TokenUsageTotals {
        try database.tokenTotals(account: account, from: start, to: end)
    }

    public func totals(events: [TokenUsageEvent], account: String, from start: Date, to end: Date = Date()) -> TokenUsageTotals {
        events.lazy.filter { $0.account == account && $0.timestamp >= start && $0.timestamp <= end }
            .reduce(into: TokenUsageTotals(), addEvent)
    }

    public func totals(events: [TokenUsageEvent], from start: Date, to end: Date = Date()) -> TokenUsageTotals {
        events.lazy.filter { $0.timestamp >= start && $0.timestamp < end }
            .reduce(into: TokenUsageTotals(), addEvent)
    }

    private func addEvent(_ totals: inout TokenUsageTotals, _ event: TokenUsageEvent) {
        if event.model.caseInsensitiveCompare("codex-auto-review") == .orderedSame {
            totals.autoReviewTokens += event.input + event.output
            return
        }
        totals.input += event.input
        totals.cachedInput += event.cachedInput
        totals.cacheWriteInput += event.cacheWriteInput
        totals.output += event.output
        totals.reasoningOutput += event.reasoningOutput
        if let price = ModelPricing.estimatedUSD(for: event) { totals.estimatedUSD += price }
        else { totals.unpricedEvents += 1 }
    }

    private func importLegacyStateIfNeeded(files: [SessionFile]) throws -> Bool {
        guard let legacyStateURL,
              FileManager.default.fileExists(atPath: legacyStateURL.path) else { return false }
        let state = try decoder.decode(LegacyState.self, from: Data(contentsOf: legacyStateURL))
        guard let timeline = state.timeline else { return false }
        let byName = Dictionary(files.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        let cursors = state.cursors.compactMap { name, offset -> SessionCursor? in
            guard let file = byName[name] else { return nil }
            return SessionCursor(
                sourceID: file.sourceID, path: file.url.path, offset: min(offset, file.size),
                fileSize: file.size, fileIdentifier: file.fileIdentifier, model: state.models[name]
            )
        }
        try database.importLegacyTokenState(
            records: state.events,
            cursors: cursors,
            activations: timeline.map { AccountActivationRecord(account: $0.account, timestamp: $0.timestamp) }
        )
        return true
    }

    private func process(
        line: Data, sourceID: String, generation: Int, offset: UInt64,
        activations: [AccountActivationRecord], model: inout String?, records: inout [TokenUsageEvent]
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        if object["type"] as? String == "turn_context", let value = payload["model"] as? String {
            model = value
            return
        }
        if object["type"] as? String == "event_msg",
           payload["type"] as? String == "thread_settings_applied",
           let settings = payload["thread_settings"] as? [String: Any],
           let value = settings["model"] as? String {
            model = value
            return
        }
        guard object["type"] as? String == "event_msg",
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any],
              let timestampText = object["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampText),
              let account = activations.reversed().first(where: { $0.timestamp <= timestamp })?.account else { return }
        func number(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        records.append(TokenUsageEvent(
            id: "\(sourceID):\(generation):\(offset)", account: account, timestamp: timestamp,
            model: model ?? "unknown", input: number("input_tokens"),
            cachedInput: number("cached_input_tokens"), cacheWriteInput: number("cache_write_input_tokens"),
            output: number("output_tokens"), reasoningOutput: number("reasoning_output_tokens")
        ))
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func performDailyRetentionIfNeeded() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now())
        let key = String(Int64(today.timeIntervalSince1970))
        guard try database.metadataValue(for: "last_token_retention_day") != key else { return }
        guard let cutoff = calendar.date(byAdding: .day, value: -90, to: today) else { return }
        try database.performTokenRetention(before: cutoff, calendar: calendar)
        try database.setMetadataValue(key, for: "last_token_retention_day")
    }

    private func modelBeforeOffset(in file: URL, offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var model: String?
        guard let data = try? handle.read(upToCount: Int(clamping: offset)), !data.isEmpty else { return nil }
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            if object["type"] as? String == "turn_context", let value = payload["model"] as? String {
                model = value
            } else if object["type"] as? String == "event_msg",
                      payload["type"] as? String == "thread_settings_applied",
                      let settings = payload["thread_settings"] as? [String: Any],
                      let value = settings["model"] as? String {
                model = value
            }
        }
        return model
    }

    private func sessionFiles() -> [SessionFile] {
        roots.flatMap { root -> [SessionFile] in
            guard let iterator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .fileResourceIdentifierKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return iterator.compactMap { item -> SessionFile? in
                guard let url = item as? URL, url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .fileResourceIdentifierKey]),
                      let size = values.fileSize else { return nil }
                let identifier = values.fileResourceIdentifier.map(String.init(describing:))
                    ?? url.standardizedFileURL.path
                return SessionFile(
                    url: url, sourceID: identifier, fileIdentifier: identifier,
                    size: UInt64(max(0, size))
                )
            }
        }
    }
}
