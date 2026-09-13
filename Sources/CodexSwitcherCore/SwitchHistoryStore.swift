import Foundation

public enum SwitchResult: String, Codable, Sendable { case success, failure }
public enum AccountHistoryAction: String, Codable, Sendable {
    case switchAccount, addAccount, reauthenticate, changeGroup
}

public struct SwitchHistoryRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let fromAccount: String
    public let toAccount: String
    public let result: SwitchResult
    public let message: String
    public let action: AccountHistoryAction?
    public let fromGroup: String?
    public let toGroup: String?
    public let includesGroupAssignment: Bool?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        fromAccount: String,
        toAccount: String,
        result: SwitchResult,
        message: String = "",
        action: AccountHistoryAction = .switchAccount,
        fromGroup: String? = nil,
        toGroup: String? = nil,
        includesGroupAssignment: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.fromAccount = fromAccount
        self.toAccount = toAccount
        self.result = result
        self.message = message
        self.action = action
        self.fromGroup = fromGroup
        self.toGroup = toGroup
        self.includesGroupAssignment = includesGroupAssignment
    }

    public var resolvedAction: AccountHistoryAction { action ?? .switchAccount }
}

public final class SwitchHistoryStore: @unchecked Sendable {
    private let url: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(url: URL) {
        self.url = url
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> [SwitchHistoryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let records = (try? decoder.decode([SwitchHistoryRecord].self, from: data)) ?? []
        return records.filter { $0.resolvedAction != .switchAccount || $0.fromAccount != $0.toAccount }
    }

    @discardableResult
    public func append(_ record: SwitchHistoryRecord) throws -> [SwitchHistoryRecord] {
        var records = load()
        guard record.resolvedAction != .switchAccount || record.fromAccount != record.toAccount else {
            return records
        }
        records.insert(record, at: 0)
        if records.count > 500 { records.removeLast(records.count - 500) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
        return records
    }
}
