import Foundation

/// 账号来自凭据文件；额度缓存缺失时仍可显示账号，不把未知额度当成零。
public struct StartupAccounts {
    public let current: String?
    public let names: Set<String>

    public init(directory: URL, preferredNames: [String] = []) {
        let files = FileManager.default
        let contents = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        var archives: [String: [String: Any]] = [:]
        for url in contents where url.lastPathComponent.hasPrefix("auth.json.") {
            let name = String(url.lastPathComponent.dropFirst("auth.json.".count))
            guard Self.validName(name), name != "bak", name != "hub", !name.hasPrefix("hub."),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let tokens = Self.tokens(url) else { continue }
            archives[name] = tokens
        }
        var names = Set(archives.keys)
        var current: String?
        if let active = Self.tokens(directory.appendingPathComponent("auth.json")) {
            let matches = archives.keys.filter { Self.sameIdentity(active, archives[$0]!) }.sorted()
            if let match = preferredNames.first(where: { matches.contains($0) }) ?? matches.first {
                current = match
            } else {
                let email = Self.payload(active)["email"] as? String ?? ""
                let stem = email.split(separator: "@").first.map(String.init) ?? "local_account"
                let normalized = stem.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
                let base = normalized.isEmpty ? "local_account" : normalized
                // 没有存档的旧名称通常属于活动账号；有存档的名称不能被覆盖。
                var candidate = preferredNames.first { Self.validName($0) && !names.contains($0) } ?? base
                var suffix = 2
                while names.contains(candidate) { candidate = "\(base)_\(suffix)"; suffix += 1 }
                current = candidate
            }
            if let current { names.insert(current) }
        }
        self.current = current
        self.names = names
    }

    public func merging(_ cached: [AccountUsage]) -> [AccountUsage] {
        let byName = Dictionary(cached.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return names.sorted().map { name in
            byName[name] ?? AccountUsage(name: name, fiveHourRemaining: -1, fiveHourReset: "", weeklyRemaining: -1, weeklyReset: "", resetCards: 0, notedAt: "")
        }
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private static func tokens(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        return tokens
    }

    private static func payload(_ tokens: [String: Any]) -> [String: Any] {
        let parts = (tokens["id_token"] as? String ?? "").split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    private static func sameIdentity(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        if let left = lhs["account_id"] as? String, let right = rhs["account_id"] as? String, !left.isEmpty, left != right { return false }
        let left = payload(lhs), right = payload(rhs)
        if let subject = left["sub"] as? String, !subject.isEmpty, let other = right["sub"] as? String { return subject == other }
        return (lhs["access_token"] as? String) == (rhs["access_token"] as? String)
    }
}
