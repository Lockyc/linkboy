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
    /// fragment or trailing slash. Nil when the text isn't such a URL.
    public static func serverURL(from text: String) -> URL? {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return nil }
        c.query = nil
        c.fragment = nil
        while c.path.hasSuffix("/") { c.path.removeLast() }
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

    /// Replaces any saved login.
    public static func save(_ c: Credentials) throws {
        try clear()
        var item = baseQuery
        item[kSecAttrAccount as String] = c.baseURL.absoluteString
        item[kSecValueData as String] = Data(c.apiKey.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    public static func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }
}
