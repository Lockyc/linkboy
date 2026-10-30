import Foundation
import Security

public struct Credentials: Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String

    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// The Miniflux server URL typed by the user, as `MinifluxClient` needs it: http(s) with a host, no query,
    /// fragment, trailing slash or trailing `/v1` — Miniflux's API Keys page shows the endpoint with `/v1/`,
    /// and the client adds that itself. Nil when the text isn't such a URL.
    public static func serverURL(from text: String) -> URL? {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return nil }
        c.query = nil
        c.fragment = nil
        while c.path.hasSuffix("/") { c.path.removeLast() }
        if c.path.lowercased().hasSuffix("/v1") { c.path.removeLast(3) }
        return c.url
    }
}

public enum CredentialError: Error, Equatable {
    case keychain(OSStatus)
}

/// One saved Miniflux login, as a Keychain generic password: account = base URL, secret = API key.
public enum CredentialStore {
    /// Overridden by tests so they never touch the app's item.
    nonisolated(unsafe) static var service = "com.lockyc.linkboy"

    public static func load() throws -> Credentials? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let item = result as? [String: Any],
              let account = item[kSecAttrAccount as String] as? String, let url = URL(string: account),
              let data = item[kSecValueData as String] as? Data, let key = String(data: data, encoding: .utf8)
        else { return nil }
        return Credentials(baseURL: url, apiKey: key)
    }

    /// Replaces any saved login. The new item is written before any other server's item is removed, so a
    /// failed save leaves the previous login in place.
    public static func save(_ c: Credentials) throws {
        let account = c.baseURL.absoluteString
        var match = baseQuery
        match[kSecAttrAccount as String] = account
        let secret = [kSecValueData as String: Data(c.apiKey.utf8)]
        var status = SecItemUpdate(match as CFDictionary, secret as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(match.merging(secret) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        for other in try accounts() where other != account {
            var stale = baseQuery
            stale[kSecAttrAccount as String] = other
            let s = SecItemDelete(stale as CFDictionary)
            guard s == errSecSuccess || s == errSecItemNotFound else { throw CredentialError.keychain(s) }
        }
    }

    static func itemCount() throws -> Int { try accounts().count }

    private static func accounts() throws -> [String] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public static func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }
}
