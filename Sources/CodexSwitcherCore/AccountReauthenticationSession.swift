import Foundation

/// 重新登录事务：先暂存当前账号，新凭据验证通过后再替换目标账号。
public final class AccountReauthenticationSession {
    private struct PendingReauthentication: Codable {
        let currentAccount: String
        let targetAccount: String
        let originalMarker: String
    }

    private let directory: URL
    private let currentAccount: String
    private let targetAccount: String
    private let active: URL
    private let currentArchive: URL
    private let targetArchive: URL
    private let marker: URL
    private let pending: URL
    private let originalMarker: Data
    public private(set) var isPending = true

    public init(directory: URL, stateDirectory: URL, currentAccount: String, targetAccount: String) throws {
        try Self.validate(currentAccount)
        try Self.validate(targetAccount)
        guard currentAccount != targetAccount else { throw Self.failure("当前账号无需重新登录。") }
        self.directory = directory
        self.currentAccount = currentAccount
        self.targetAccount = targetAccount
        active = directory.appendingPathComponent("auth.json")
        currentArchive = directory.appendingPathComponent("auth.json.\(currentAccount)")
        targetArchive = directory.appendingPathComponent("auth.json.\(targetAccount)")
        marker = stateDirectory.appendingPathComponent(".active-auth-profile")
        pending = Self.pendingURL(in: stateDirectory)
        originalMarker = (try? Data(contentsOf: marker)) ?? Data("account \(currentAccount)\n".utf8)
        guard FileManager.default.fileExists(atPath: active.path) else { throw Self.failure("找不到当前 auth.json。") }
        guard !FileManager.default.fileExists(atPath: currentArchive.path) else { throw Self.failure("当前账号备份已存在，为避免覆盖已停止。") }
        guard FileManager.default.fileExists(atPath: targetArchive.path) else { throw Self.failure("找不到需要重新登录的账号文件。") }
        guard !FileManager.default.fileExists(atPath: pending.path) else { throw Self.failure("已有未完成的重新登录操作，请重新打开应用完成恢复。") }
        do {
            let record = PendingReauthentication(
                currentAccount: currentAccount,
                targetAccount: targetAccount,
                originalMarker: String(decoding: originalMarker, as: UTF8.self)
            )
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: pending, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            try FileManager.default.moveItem(at: active, to: currentArchive)
        } catch {
            try? FileManager.default.removeItem(at: pending)
            if FileManager.default.fileExists(atPath: currentArchive.path), !FileManager.default.fileExists(atPath: active.path) {
                try? FileManager.default.moveItem(at: currentArchive, to: active)
            }
            throw error
        }
    }

    public func complete() throws {
        guard isPending else { return }
        let files = FileManager.default
        guard files.fileExists(atPath: active.path) else { throw Self.failure("找不到重新登录后的凭据。") }
        try files.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("account \(targetAccount)\n".utf8).write(to: marker, options: .atomic)
        try files.removeItem(at: targetArchive)
        try files.removeItem(at: pending)
        isPending = false
    }

    public func cancel() throws {
        guard isPending else { return }
        let files = FileManager.default
        if files.fileExists(atPath: active.path) { try files.removeItem(at: active) }
        guard files.fileExists(atPath: currentArchive.path) else { throw Self.failure("找不到原账号备份，已停止恢复。") }
        try files.moveItem(at: currentArchive, to: active)
        try originalMarker.write(to: marker, options: .atomic)
        try files.removeItem(at: pending)
        isPending = false
    }

    /// 若标记已指向目标账号，说明新凭据已验证，完成清理；否则恢复原账号。
    public static func recoverInterrupted(in directory: URL, stateDirectory: URL) throws -> Bool {
        let pending = pendingURL(in: stateDirectory)
        guard FileManager.default.fileExists(atPath: pending.path) else { return false }
        let record = try JSONDecoder().decode(PendingReauthentication.self, from: Data(contentsOf: pending))
        try validate(record.currentAccount)
        try validate(record.targetAccount)
        let files = FileManager.default
        let active = directory.appendingPathComponent("auth.json")
        let currentArchive = directory.appendingPathComponent("auth.json.\(record.currentAccount)")
        let targetArchive = directory.appendingPathComponent("auth.json.\(record.targetAccount)")
        let marker = stateDirectory.appendingPathComponent(".active-auth-profile")
        let markerText = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if markerText == "account \(record.targetAccount)", files.fileExists(atPath: active.path) {
            if files.fileExists(atPath: targetArchive.path) { try files.removeItem(at: targetArchive) }
            try files.removeItem(at: pending)
            return true
        }
        guard files.fileExists(atPath: currentArchive.path) else { throw failure("上次重新登录的原账号备份不存在，未修改现有凭据。") }
        if files.fileExists(atPath: active.path) { try files.removeItem(at: active) }
        try files.moveItem(at: currentArchive, to: active)
        try Data(record.originalMarker.utf8).write(to: marker, options: .atomic)
        try files.removeItem(at: pending)
        return true
    }

    private static func pendingURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".codex-switcher-reauthentication-pending.json")
    }

    private static func validate(_ account: String) throws {
        guard !account.isEmpty, !account.contains("/"), account != ".", account != ".." else { throw failure("账号名称无效。") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CodexSwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
