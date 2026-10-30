import Foundation

public protocol MinifluxAPI: Sendable {
    func me() async throws -> User
    func entries(_ q: EntryQuery) async throws -> (total: Int, entries: [Entry])
    func entry(id: Int64) async throws -> Entry
    func setStatus(_ s: EntryStatus, ids: [Int64]) async throws
    func toggleBookmark(id: Int64) async throws
    func categories() async throws -> [CategoryRef]
}

public final class MinifluxClient: MinifluxAPI {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func me() async throws -> User {
        try await decode(User.self, from: send(request("/v1/me")))
    }

    public func entries(_ q: EntryQuery) async throws -> (total: Int, entries: [Entry]) {
        struct Page: Decodable { let total: Int; let entries: [Entry] }
        var items: [URLQueryItem] = []
        for s in q.status ?? [] { items.append(.init(name: "status", value: s.rawValue)) }
        if let starred = q.starred { items.append(.init(name: "starred", value: String(starred))) }
        if let id = q.categoryID { items.append(.init(name: "category_id", value: String(id))) }
        if let id = q.feedID { items.append(.init(name: "feed_id", value: String(id))) }
        if let d = q.changedAfter { items.append(.init(name: "changed_after", value: String(Int64(d.timeIntervalSince1970)))) }
        items += [
            .init(name: "limit", value: String(q.limit)),
            .init(name: "offset", value: String(q.offset)),
            .init(name: "order", value: "published_at"),
            .init(name: "direction", value: "desc"),
        ]
        let page = try await decode(Page.self, from: send(request("/v1/entries", query: items)))
        return (page.total, page.entries)
    }

    public func entry(id: Int64) async throws -> Entry {
        try await decode(Entry.self, from: send(request("/v1/entries/\(id)")))
    }

    public func setStatus(_ s: EntryStatus, ids: [Int64]) async throws {
        struct Body: Encodable { let entry_ids: [Int64]; let status: EntryStatus }
        var req = request("/v1/entries", method: "PUT")
        req.httpBody = try JSONEncoder().encode(Body(entry_ids: ids, status: s))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(req)
    }

    public func toggleBookmark(id: Int64) async throws {
        _ = try await send(request("/v1/entries/\(id)/bookmark", method: "PUT"))
    }

    public func categories() async throws -> [CategoryRef] {
        try await decode([CategoryRef].self, from: send(request("/v1/categories")))
    }

    // MARK: - Transport

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-Auth-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw MinifluxError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MinifluxError.transport("Non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw MinifluxError.unauthorized
        case 404: throw MinifluxError.notFound
        default: throw MinifluxError.http(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MinifluxError.decoding(String(describing: error))
        }
    }
}
