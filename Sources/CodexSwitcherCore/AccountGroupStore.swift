import Foundation

public struct AccountGroup: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct AccountGroupState: Codable, Equatable, Sendable {
    public var groups: [AccountGroup]
    public var accountGroupIDs: [String: UUID]

    public init(groups: [AccountGroup] = [], accountGroupIDs: [String: UUID] = [:]) {
        self.groups = groups
        self.accountGroupIDs = accountGroupIDs
    }

    public mutating func createGroup(named rawName: String) throws -> AccountGroup {
        let name = try validatedName(rawName)
        let group = AccountGroup(name: name)
        groups.append(group)
        return group
    }

    public mutating func renameGroup(id: UUID, to rawName: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let name = try validatedName(rawName, excluding: id)
        groups[index].name = name
    }

    public mutating func deleteGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        accountGroupIDs = accountGroupIDs.filter { $0.value != id }
    }

    public mutating func assign(accounts: Set<String>, to groupID: UUID?) {
        for account in accounts {
            if let groupID, groups.contains(where: { $0.id == groupID }) {
                accountGroupIDs[account] = groupID
            } else {
                accountGroupIDs.removeValue(forKey: account)
            }
        }
    }

    public mutating func clean(validAccounts: Set<String>) {
        let groupIDs = Set(groups.map(\.id))
        accountGroupIDs = accountGroupIDs.filter {
            validAccounts.contains($0.key) && groupIDs.contains($0.value)
        }
    }

    private func validatedName(_ rawName: String, excluding excludedID: UUID? = nil) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AccountGroupError.emptyName }
        guard !groups.contains(where: { $0.id != excludedID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
        else { throw AccountGroupError.duplicateName }
        return name
    }
}

public enum AccountGroupError: LocalizedError, Equatable {
    case emptyName
    case duplicateName

    public var errorDescription: String? {
        switch self {
        case .emptyName: "分组名称不能为空"
        case .duplicateName: "分组名称已存在"
        }
    }
}

public struct AccountGroupStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load(validAccounts: Set<String>) throws -> AccountGroupState {
        guard FileManager.default.fileExists(atPath: url.path) else { return AccountGroupState() }
        var state = try JSONDecoder().decode(AccountGroupState.self, from: Data(contentsOf: url))
        state.clean(validAccounts: validAccounts)
        return state
    }

    public func save(_ state: AccountGroupState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }
}
