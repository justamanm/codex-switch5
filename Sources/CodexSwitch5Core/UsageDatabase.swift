import CSQLite
import Foundation

public enum UsageDatabaseError: LocalizedError, Equatable {
    case openFailed(String)
    case statementFailed(String)
    case unsupportedVersion(found: Int, supported: Int)
    case invalidStoredData(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            "无法打开用量数据库：\(message)"
        case .statementFailed(let message):
            "无法更新用量数据库：\(message)"
        case .unsupportedVersion(let found, let supported):
            "用量数据库来自更新版本（\(found)），当前程序只支持到版本 \(supported)。"
        case .invalidStoredData(let message):
            "用量数据库包含无法识别的记录：\(message)"
        }
    }
}

public struct SessionCursor: Equatable, Sendable {
    public let sourceID: String
    public var path: String
    public var offset: UInt64
    public var fileSize: UInt64
    public var fileIdentifier: String
    public var generation: Int
    public var model: String?

    public init(
        sourceID: String,
        path: String,
        offset: UInt64,
        fileSize: UInt64,
        fileIdentifier: String,
        generation: Int = 0,
        model: String? = nil
    ) {
        self.sourceID = sourceID
        self.path = path
        self.offset = offset
        self.fileSize = fileSize
        self.fileIdentifier = fileIdentifier
        self.generation = generation
        self.model = model
    }
}

public struct AccountActivationRecord: Equatable, Sendable {
    public let account: String
    public let timestamp: Date

    public init(account: String, timestamp: Date) {
        self.account = account
        self.timestamp = timestamp
    }
}

/// Switch5 的长期用量数据库。不保存认证令牌或对话正文。
public final class UsageDatabase: @unchecked Sendable {
    public static let schemaVersion = 1

    public let url: URL
    private let lock = NSRecursiveLock()
    private var connection: OpaquePointer?

    public init(url: URL) {
        self.url = url
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    public func prepare() throws {
        try withConnection { _ in }
    }

    public func metadataValue(for key: String) throws -> String? {
        try withConnection { database in
            let statement = try prepare("SELECT value FROM metadata WHERE key = ? LIMIT 1", database: database)
            defer { sqlite3_finalize(statement) }
            try bind(key, at: 1, to: statement, database: database)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return string(statement, column: 0)
            case SQLITE_DONE:
                return nil
            default:
                throw statementError(database)
            }
        }
    }

    public func setMetadataValue(_ value: String, for key: String) throws {
        try withConnection { database in
            let statement = try prepare(
                "INSERT INTO metadata(key, value) VALUES(?, ?) " +
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(key, at: 1, to: statement, database: database)
            try bind(value, at: 2, to: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    public func insertTokenUsageRecords(_ records: [TokenUsageEvent]) throws {
        guard !records.isEmpty else { return }
        try inTransaction { database in
            try insertTokenUsageRecords(records, database: database)
        }
    }

    public func tokenUsageRecords(from start: Date, to end: Date) throws -> [TokenUsageEvent] {
        try withConnection { database in
            let statement = try prepare("""
                SELECT id, account, timestamp, model, input, cached_input,
                       cache_write_input, output, reasoning_output
                FROM token_usage_records
                WHERE timestamp >= ? AND timestamp < ?
                ORDER BY timestamp, id
                """, database: database)
            defer { sqlite3_finalize(statement) }
            try bind(start.timeIntervalSince1970, at: 1, to: statement, database: database)
            try bind(end.timeIntervalSince1970, at: 2, to: statement, database: database)
            var result: [TokenUsageEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(tokenUsageRecord(statement))
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw statementError(database)
            }
            return result
        }
    }

    public func tokenUsageRecordCount() throws -> Int {
        try withConnection { database in
            let statement = try prepare("SELECT COUNT(*) FROM token_usage_records", database: database)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw statementError(database) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func tokenTotals(account: String?, from start: Date, to end: Date) throws -> TokenUsageTotals {
        try withConnection { database in
            var sql = """
                SELECT model, SUM(input), SUM(cached_input), SUM(cache_write_input),
                       SUM(output), SUM(reasoning_output), SUM(record_count)
                FROM (
                    SELECT model, input, cached_input, cache_write_input, output, reasoning_output,
                           1 AS record_count, account, timestamp AS moment
                    FROM token_usage_records
                    UNION ALL
                    SELECT model, input, cached_input, cache_write_input, output, reasoning_output,
                           record_count, account, day_start AS moment
                    FROM daily_token_totals
                )
                WHERE moment >= ? AND moment < ?
                """
            if account != nil { sql += " AND account = ?" }
            sql += " GROUP BY model"
            let statement = try prepare(sql, database: database)
            defer { sqlite3_finalize(statement) }
            try bind(start.timeIntervalSince1970, at: 1, to: statement, database: database)
            try bind(end.timeIntervalSince1970, at: 2, to: statement, database: database)
            if let account { try bind(account, at: 3, to: statement, database: database) }
            var totals = TokenUsageTotals()
            while sqlite3_step(statement) == SQLITE_ROW {
                let model = string(statement, column: 0) ?? "unknown"
                let event = TokenUsageEvent(
                    id: "aggregate", account: account ?? "", timestamp: start, model: model,
                    input: Int(sqlite3_column_int64(statement, 1)),
                    cachedInput: Int(sqlite3_column_int64(statement, 2)),
                    cacheWriteInput: Int(sqlite3_column_int64(statement, 3)),
                    output: Int(sqlite3_column_int64(statement, 4)),
                    reasoningOutput: Int(sqlite3_column_int64(statement, 5))
                )
                let count = Int(sqlite3_column_int64(statement, 6))
                if model.caseInsensitiveCompare("codex-auto-review") == .orderedSame {
                    totals.autoReviewTokens += event.input + event.output
                    continue
                }
                totals.input += event.input
                totals.cachedInput += event.cachedInput
                totals.cacheWriteInput += event.cacheWriteInput
                totals.output += event.output
                totals.reasoningOutput += event.reasoningOutput
                if let price = ModelPricing.estimatedUSD(for: event) {
                    totals.estimatedUSD += price
                } else {
                    totals.unpricedEvents += count
                }
            }
            return totals
        }
    }

    public func cursor(for sourceID: String) throws -> SessionCursor? {
        try withConnection { database in
            let statement = try prepare("""
                SELECT source_id, path, offset, file_size, file_identifier, generation, model
                FROM session_cursors WHERE source_id = ? LIMIT 1
                """, database: database)
            defer { sqlite3_finalize(statement) }
            try bind(sourceID, at: 1, to: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sessionCursor(statement)
        }
    }

    public func cursor(matchingPath path: String) throws -> SessionCursor? {
        try withConnection { database in
            let statement = try prepare("""
                SELECT source_id, path, offset, file_size, file_identifier, generation, model
                FROM session_cursors WHERE path = ? LIMIT 1
                """, database: database)
            defer { sqlite3_finalize(statement) }
            try bind(path, at: 1, to: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sessionCursor(statement)
        }
    }

    public func saveCursor(_ cursor: SessionCursor) throws {
        try withConnection { database in try saveCursor(cursor, database: database) }
    }

    public func saveScan(records: [TokenUsageEvent], cursors: [SessionCursor]) throws {
        try inTransaction { database in
            try insertTokenUsageRecords(records, database: database)
            for cursor in cursors { try saveCursor(cursor, database: database) }
        }
    }

    public func accountActivations() throws -> [AccountActivationRecord] {
        try withConnection { database in
            let statement = try prepare(
                "SELECT account, timestamp FROM account_activations ORDER BY timestamp, id",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            var values: [AccountActivationRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(AccountActivationRecord(
                    account: string(statement, column: 0) ?? "",
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                ))
            }
            return values
        }
    }

    public func appendAccountActivation(account: String, timestamp: Date) throws {
        try withConnection { database in
            let statement = try prepare(
                "INSERT OR IGNORE INTO account_activations(account, timestamp) VALUES(?, ?)",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(account, at: 1, to: statement, database: database)
            try bind(timestamp.timeIntervalSince1970, at: 2, to: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    public func initializeTokenTracking(account: String, at timestamp: Date, cursors: [SessionCursor]) throws {
        try inTransaction { database in
            let activation = try prepare(
                "INSERT OR IGNORE INTO account_activations(account, timestamp) VALUES(?, ?)",
                database: database
            )
            defer { sqlite3_finalize(activation) }
            try bind(account, at: 1, to: activation, database: database)
            try bind(timestamp.timeIntervalSince1970, at: 2, to: activation, database: database)
            try stepDone(activation, database: database)
            for cursor in cursors { try saveCursor(cursor, database: database) }
            try setMetadataValue("1", for: "token_tracking_initialized")
        }
    }

    public func importLegacyTokenState(
        records: [TokenUsageEvent],
        cursors: [SessionCursor],
        activations: [AccountActivationRecord]
    ) throws {
        try inTransaction { database in
            try insertTokenUsageRecords(records, database: database)
            for cursor in cursors { try saveCursor(cursor, database: database) }
            let activation = try prepare(
                "INSERT OR IGNORE INTO account_activations(account, timestamp) VALUES(?, ?)",
                database: database
            )
            defer { sqlite3_finalize(activation) }
            for value in activations {
                sqlite3_reset(activation); sqlite3_clear_bindings(activation)
                try bind(value.account, at: 1, to: activation, database: database)
                try bind(value.timestamp.timeIntervalSince1970, at: 2, to: activation, database: database)
                try stepDone(activation, database: database)
            }
            let metadata = try prepare(
                "INSERT INTO metadata(key, value) VALUES(?, ?) " +
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                database: database
            )
            defer { sqlite3_finalize(metadata) }
            for (key, value) in [
                ("legacy_token_state_imported", "1"),
                ("token_tracking_initialized", "1")
            ] {
                sqlite3_reset(metadata); sqlite3_clear_bindings(metadata)
                try bind(key, at: 1, to: metadata, database: database)
                try bind(value, at: 2, to: metadata, database: database)
                try stepDone(metadata, database: database)
            }
        }
    }

    public func performTokenRetention(before cutoff: Date, calendar: Calendar = .current) throws {
        try inTransaction { database in
            let select = try prepare("""
                SELECT account, model, timestamp, input, cached_input, cache_write_input, output, reasoning_output
                FROM token_usage_records WHERE timestamp < ? ORDER BY timestamp
                """, database: database)
            defer { sqlite3_finalize(select) }
            try bind(cutoff.timeIntervalSince1970, at: 1, to: select, database: database)
            struct Key: Hashable { let day: Date; let account: String; let model: String }
            var totals: [Key: (Int64, Int64, Int64, Int64, Int64, Int64)] = [:]
            while sqlite3_step(select) == SQLITE_ROW {
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(select, 2))
                let key = Key(
                    day: calendar.startOfDay(for: timestamp),
                    account: string(select, column: 0) ?? "",
                    model: string(select, column: 1) ?? "unknown"
                )
                let old = totals[key] ?? (0, 0, 0, 0, 0, 0)
                totals[key] = (
                    old.0 + sqlite3_column_int64(select, 3), old.1 + sqlite3_column_int64(select, 4),
                    old.2 + sqlite3_column_int64(select, 5), old.3 + sqlite3_column_int64(select, 6),
                    old.4 + sqlite3_column_int64(select, 7), old.5 + 1
                )
            }
            let upsert = try prepare("""
                INSERT INTO daily_token_totals(
                    day_start, account, model, input, cached_input, cache_write_input, output, reasoning_output,
                    record_count
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day_start, account, model) DO UPDATE SET
                    input = daily_token_totals.input + excluded.input,
                    cached_input = daily_token_totals.cached_input + excluded.cached_input,
                    cache_write_input = daily_token_totals.cache_write_input + excluded.cache_write_input,
                    output = daily_token_totals.output + excluded.output,
                    reasoning_output = daily_token_totals.reasoning_output + excluded.reasoning_output,
                    record_count = daily_token_totals.record_count + excluded.record_count
                """, database: database)
            defer { sqlite3_finalize(upsert) }
            for (key, value) in totals {
                sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
                try bind(key.day.timeIntervalSince1970, at: 1, to: upsert, database: database)
                try bind(key.account, at: 2, to: upsert, database: database)
                try bind(key.model, at: 3, to: upsert, database: database)
                try bind(value.0, at: 4, to: upsert, database: database)
                try bind(value.1, at: 5, to: upsert, database: database)
                try bind(value.2, at: 6, to: upsert, database: database)
                try bind(value.3, at: 7, to: upsert, database: database)
                try bind(value.4, at: 8, to: upsert, database: database)
                try bind(value.5, at: 9, to: upsert, database: database)
                try stepDone(upsert, database: database)
            }
            let delete = try prepare("DELETE FROM token_usage_records WHERE timestamp < ?", database: database)
            defer { sqlite3_finalize(delete) }
            let retainIDs = try prepare(
                "INSERT OR IGNORE INTO retained_token_record_ids(id) " +
                "SELECT id FROM token_usage_records WHERE timestamp < ?",
                database: database
            )
            defer { sqlite3_finalize(retainIDs) }
            try bind(cutoff.timeIntervalSince1970, at: 1, to: retainIDs, database: database)
            try stepDone(retainIDs, database: database)
            try bind(cutoff.timeIntervalSince1970, at: 1, to: delete, database: database)
            try stepDone(delete, database: database)
        }
    }

    public func appendUsageHistory(_ events: [UsageHistoryEvent]) throws {
        guard !events.isEmpty else { return }
        try inTransaction { database in
            try insertUsageHistory(events, database: database)
        }
    }

    public func usageHistory(from start: Date? = nil) throws -> [UsageHistoryEvent] {
        try withConnection { database in
            let sql = start == nil
                ? "SELECT payload FROM usage_history ORDER BY timestamp, id"
                : "SELECT payload FROM usage_history WHERE timestamp >= ? ORDER BY timestamp, id"
            let statement = try prepare(sql, database: database)
            defer { sqlite3_finalize(statement) }
            if let start { try bind(start.timeIntervalSince1970, at: 1, to: statement, database: database) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            var records: [UsageHistoryEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                do {
                    records.append(try decoder.decode(UsageHistoryEvent.self, from: data(statement, column: 0)))
                } catch {
                    throw UsageDatabaseError.invalidStoredData(error.localizedDescription)
                }
            }
            return records
        }
    }

    public func usageHistoryCount() throws -> Int {
        try withConnection { database in
            let statement = try prepare("SELECT COUNT(*) FROM usage_history", database: database)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw statementError(database) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func latestObservation(account: String) throws -> QuotaObservation? {
        try withConnection { database in
            let statement = try prepare("""
                SELECT payload FROM (
                    SELECT payload, timestamp FROM usage_history WHERE kind = 0 AND account = ?
                    UNION ALL
                    SELECT last_payload AS payload, day_start AS timestamp
                    FROM usage_daily_summaries
                    WHERE account = ? AND last_payload IS NOT NULL
                ) ORDER BY timestamp DESC LIMIT 1
                """, database: database)
            defer { sqlite3_finalize(statement) }
            try bind(account, at: 1, to: statement, database: database)
            try bind(account, at: 2, to: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let event = try decoder.decode(UsageHistoryEvent.self, from: data(statement, column: 0))
            guard case .observation(let observation) = event else { return nil }
            return observation
        }
    }

    public func importLegacyUsageHistory(_ events: [UsageHistoryEvent]) throws {
        try inTransaction { database in
            try insertUsageHistory(events, database: database)
            let statement = try prepare(
                "INSERT INTO metadata(key, value) VALUES('legacy_usage_history_imported', '1') " +
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try stepDone(statement, database: database)
        }
    }

    public func performUsageHistoryRetention(before cutoff: Date, calendar: Calendar = .current) throws {
        try inTransaction { database in
            let select = try prepare("""
                SELECT kind, account, timestamp, payload FROM usage_history
                WHERE timestamp < ? AND kind IN (0, 1) ORDER BY timestamp, id
                """, database: database)
            defer { sqlite3_finalize(select) }
            try bind(cutoff.timeIntervalSince1970, at: 1, to: select, database: database)
            struct Key: Hashable { let day: Date; let account: String }
            struct Summary { var first: Data?; var last: Data?; var failures = 0 }
            var summaries: [Key: Summary] = [:]
            while sqlite3_step(select) == SQLITE_ROW {
                let account = string(select, column: 1) ?? ""
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(select, 2))
                let key = Key(day: calendar.startOfDay(for: timestamp), account: account)
                var summary = summaries[key] ?? Summary()
                if sqlite3_column_int(select, 0) == 0 {
                    let payload = data(select, column: 3)
                    if summary.first == nil { summary.first = payload }
                    summary.last = payload
                } else {
                    summary.failures += 1
                }
                summaries[key] = summary
            }
            let upsert = try prepare("""
                INSERT INTO usage_daily_summaries(day_start, account, first_payload, last_payload, failed_count)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(day_start, account) DO UPDATE SET
                    first_payload = COALESCE(usage_daily_summaries.first_payload, excluded.first_payload),
                    last_payload = COALESCE(excluded.last_payload, usage_daily_summaries.last_payload),
                    failed_count = usage_daily_summaries.failed_count + excluded.failed_count
                """, database: database)
            defer { sqlite3_finalize(upsert) }
            for (key, summary) in summaries {
                sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
                try bind(key.day.timeIntervalSince1970, at: 1, to: upsert, database: database)
                try bind(key.account, at: 2, to: upsert, database: database)
                if let first = summary.first { try bind(first, at: 3, to: upsert, database: database) }
                else { try bindNull(at: 3, to: upsert, database: database) }
                if let last = summary.last { try bind(last, at: 4, to: upsert, database: database) }
                else { try bindNull(at: 4, to: upsert, database: database) }
                try bind(Int64(summary.failures), at: 5, to: upsert, database: database)
                try stepDone(upsert, database: database)
            }
            let delete = try prepare(
                "DELETE FROM usage_history WHERE timestamp < ? AND kind IN (0, 1)",
                database: database
            )
            defer { sqlite3_finalize(delete) }
            try bind(cutoff.timeIntervalSince1970, at: 1, to: delete, database: database)
            try stepDone(delete, database: database)
        }
    }

    func inTransaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try withConnection { database in
            try execute("BEGIN IMMEDIATE", database: database)
            do {
                let value = try body(database)
                try execute("COMMIT", database: database)
                return value
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
    }

    func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let database = try openIfNeeded()
        return try body(database)
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let connection { return connection }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "SQLite \(result)"
            if let opened { sqlite3_close(opened) }
            throw UsageDatabaseError.openFailed(message)
        }
        do {
            try execute("PRAGMA busy_timeout = 5000", database: opened)
            let found = try scalarInt("PRAGMA user_version", database: opened)
            guard found <= Self.schemaVersion else {
                throw UsageDatabaseError.unsupportedVersion(found: found, supported: Self.schemaVersion)
            }
            // 先确认版本，再执行任何可能改变数据库文件的设置。
            // 这样新版应用创建的数据库不会被旧版应用误写。
            try execute("PRAGMA foreign_keys = ON", database: opened)
            try execute("PRAGMA journal_mode = WAL", database: opened)
            if found == 0 {
                try createVersionOneSchema(database: opened)
            }
            connection = opened
            return opened
        } catch {
            sqlite3_close(opened)
            throw error
        }
    }

    private func createVersionOneSchema(database: OpaquePointer) throws {
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            try execute("""
                CREATE TABLE metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE token_usage_records (
                    id TEXT PRIMARY KEY NOT NULL,
                    account TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    model TEXT NOT NULL,
                    input INTEGER NOT NULL,
                    cached_input INTEGER NOT NULL,
                    cache_write_input INTEGER NOT NULL,
                    output INTEGER NOT NULL,
                    reasoning_output INTEGER NOT NULL
                );
                CREATE INDEX token_usage_account_time
                    ON token_usage_records(account, timestamp);
                CREATE INDEX token_usage_time
                    ON token_usage_records(timestamp);
                CREATE TABLE retained_token_record_ids (
                    id TEXT PRIMARY KEY NOT NULL
                );
                CREATE TABLE session_cursors (
                    source_id TEXT PRIMARY KEY NOT NULL,
                    path TEXT NOT NULL,
                    offset INTEGER NOT NULL,
                    file_size INTEGER NOT NULL,
                    file_identifier TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    model TEXT
                );
                CREATE TABLE account_activations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    UNIQUE(account, timestamp)
                );
                CREATE INDEX account_activations_time
                    ON account_activations(timestamp);
                CREATE TABLE usage_history (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind INTEGER NOT NULL,
                    account TEXT,
                    timestamp REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX usage_history_time
                    ON usage_history(timestamp);
                CREATE INDEX usage_history_account_time
                    ON usage_history(account, timestamp);
                CREATE TABLE usage_daily_summaries (
                    day_start REAL NOT NULL,
                    account TEXT NOT NULL,
                    first_payload BLOB,
                    last_payload BLOB,
                    failed_count INTEGER NOT NULL,
                    PRIMARY KEY(day_start, account)
                );
                CREATE TABLE daily_token_totals (
                    day_start REAL NOT NULL,
                    account TEXT NOT NULL,
                    model TEXT NOT NULL,
                    input INTEGER NOT NULL,
                    cached_input INTEGER NOT NULL,
                    cache_write_input INTEGER NOT NULL,
                    output INTEGER NOT NULL,
                    reasoning_output INTEGER NOT NULL,
                    record_count INTEGER NOT NULL,
                    PRIMARY KEY(day_start, account, model)
                );
                """, database: database)
            try execute("PRAGMA user_version = \(Self.schemaVersion)", database: database)
            try execute("COMMIT", database: database)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw UsageDatabaseError.statementFailed(message)
        }
    }

    func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw statementError(database) }
        return statement
    }

    func bind(_ value: String, at index: Int32, to statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw statementError(database)
        }
    }

    func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw statementError(database) }
    }

    func bind(_ value: Double, at index: Int32, to statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw statementError(database) }
    }

    func bind(_ value: Data, at index: Int32, to statement: OpaquePointer, database: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw statementError(database) }
    }

    func bindNull(at index: Int32, to statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw statementError(database) }
    }

    func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError(database) }
    }

    func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    func data(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func scalarInt(_ sql: String, database: OpaquePointer) throws -> Int {
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw statementError(database) }
        return Int(sqlite3_column_int(statement, 0))
    }

    func statementError(_ database: OpaquePointer) -> UsageDatabaseError {
        .statementFailed(String(cString: sqlite3_errmsg(database)))
    }

    private func insertTokenUsageRecords(_ records: [TokenUsageEvent], database: OpaquePointer) throws {
        guard !records.isEmpty else { return }
        let statement = try prepare("""
            INSERT OR IGNORE INTO token_usage_records(
                id, account, timestamp, model, input, cached_input, cache_write_input, output, reasoning_output
            ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
            WHERE NOT EXISTS (SELECT 1 FROM retained_token_record_ids WHERE id = ?)
            """, database: database)
        defer { sqlite3_finalize(statement) }
        for record in records {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(record.id, at: 1, to: statement, database: database)
            try bind(record.account, at: 2, to: statement, database: database)
            try bind(record.timestamp.timeIntervalSince1970, at: 3, to: statement, database: database)
            try bind(record.model, at: 4, to: statement, database: database)
            try bind(Int64(record.input), at: 5, to: statement, database: database)
            try bind(Int64(record.cachedInput), at: 6, to: statement, database: database)
            try bind(Int64(record.cacheWriteInput), at: 7, to: statement, database: database)
            try bind(Int64(record.output), at: 8, to: statement, database: database)
            try bind(Int64(record.reasoningOutput), at: 9, to: statement, database: database)
            try bind(record.id, at: 10, to: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    private func insertUsageHistory(_ events: [UsageHistoryEvent], database: OpaquePointer) throws {
        guard !events.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let statement = try prepare("""
            INSERT OR IGNORE INTO usage_history(id, kind, account, timestamp, payload)
            VALUES(?, ?, ?, ?, ?)
            """, database: database)
        defer { sqlite3_finalize(statement) }
        for event in events {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            let identity = usageHistoryIdentity(event)
            try bind(identity.id, at: 1, to: statement, database: database)
            try bind(Int64(identity.kind), at: 2, to: statement, database: database)
            if let account = identity.account { try bind(account, at: 3, to: statement, database: database) }
            else { try bindNull(at: 3, to: statement, database: database) }
            try bind(event.timestamp.timeIntervalSince1970, at: 4, to: statement, database: database)
            try bind(try encoder.encode(event), at: 5, to: statement, database: database)
            try stepDone(statement, database: database)
        }
    }

    private func usageHistoryIdentity(_ event: UsageHistoryEvent) -> (id: String, kind: Int, account: String?) {
        let milliseconds = Int64((event.timestamp.timeIntervalSince1970 * 1_000).rounded())
        switch event {
        case .observation(let value):
            return ("observation:\(value.account):\(milliseconds)", 0, value.account)
        case .queryFailed(let account, _):
            return ("query-failed:\(account):\(milliseconds)", 1, account)
        case .accountChanged(let from, let to, _, let succeeded):
            return ("account-changed:\(from):\(to):\(milliseconds):\(succeeded)", 2, to)
        case .plannedBreak(_, let end):
            let endMilliseconds = Int64((end.timeIntervalSince1970 * 1_000).rounded())
            return ("planned-break:\(milliseconds):\(endMilliseconds)", 3, nil)
        }
    }

    private func saveCursor(_ cursor: SessionCursor, database: OpaquePointer) throws {
        let statement = try prepare("""
            INSERT INTO session_cursors(
                source_id, path, offset, file_size, file_identifier, generation, model
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                path = excluded.path, offset = excluded.offset, file_size = excluded.file_size,
                file_identifier = excluded.file_identifier, generation = excluded.generation,
                model = excluded.model
            """, database: database)
        defer { sqlite3_finalize(statement) }
        try bind(cursor.sourceID, at: 1, to: statement, database: database)
        try bind(cursor.path, at: 2, to: statement, database: database)
        try bind(Int64(clamping: cursor.offset), at: 3, to: statement, database: database)
        try bind(Int64(clamping: cursor.fileSize), at: 4, to: statement, database: database)
        try bind(cursor.fileIdentifier, at: 5, to: statement, database: database)
        try bind(Int64(cursor.generation), at: 6, to: statement, database: database)
        if let model = cursor.model { try bind(model, at: 7, to: statement, database: database) }
        else { try bindNull(at: 7, to: statement, database: database) }
        try stepDone(statement, database: database)
    }

    private func sessionCursor(_ statement: OpaquePointer) -> SessionCursor {
        SessionCursor(
            sourceID: string(statement, column: 0) ?? "",
            path: string(statement, column: 1) ?? "",
            offset: UInt64(max(0, sqlite3_column_int64(statement, 2))),
            fileSize: UInt64(max(0, sqlite3_column_int64(statement, 3))),
            fileIdentifier: string(statement, column: 4) ?? "",
            generation: Int(sqlite3_column_int64(statement, 5)),
            model: string(statement, column: 6)
        )
    }

    private func tokenUsageRecord(_ statement: OpaquePointer) -> TokenUsageEvent {
        TokenUsageEvent(
            id: string(statement, column: 0) ?? "",
            account: string(statement, column: 1) ?? "",
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            model: string(statement, column: 3) ?? "unknown",
            input: Int(sqlite3_column_int64(statement, 4)),
            cachedInput: Int(sqlite3_column_int64(statement, 5)),
            cacheWriteInput: Int(sqlite3_column_int64(statement, 6)),
            output: Int(sqlite3_column_int64(statement, 7)),
            reasoningOutput: Int(sqlite3_column_int64(statement, 8))
        )
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
