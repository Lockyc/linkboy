import XCTest
@testable import LinkboyCore

/// Stub transport. Handlers are keyed by request host so each test owns a unique host and parallel tests never share state.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data?) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    private static func handler(for host: String) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[host]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        let result = handler(request, body)
        let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MinifluxClientTests: XCTestCase {
    /// A client on a host unique to this call, with `handler` registered for it.
    private func makeClient(base: String = "", handler: @escaping StubURLProtocol.Handler) -> MinifluxClient {
        let host = "\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host, handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return MinifluxClient(baseURL: URL(string: "https://\(host)\(base)")!, apiKey: "secret-key", session: URLSession(configuration: config))
    }

    private let entryJSON = """
    {"total": 1, "entries": [{
      "id": 42, "feed_id": 3, "status": "unread", "title": "Hello", "url": "https://example.com/a",
      "comments_url": "", "published_at": "2026-10-29T08:12:01.123456+11:00",
      "changed_at": "2026-10-29T09:00:00+11:00", "starred": false,
      "feed": {"id": 3, "title": "HN", "category": {"id": 7, "title": "News"}}
    }]}
    """

    func testEntriesQueryEncodesFilters() async throws {
        let captured = LockedBox<URLRequest>()
        let json = entryJSON
        let client = makeClient { req, _ in
            captured.value = req
            return (200, Data(json.utf8))
        }
        let after = Date(timeIntervalSince1970: 1_700_000_000)
        var q = EntryQuery()
        q.status = [.unread]
        q.categoryID = 7
        q.changedAfter = after
        let result = try await client.entries(q)

        let req = try XCTUnwrap(captured.value)
        XCTAssertEqual(req.url?.path, "/v1/entries")
        XCTAssertEqual(req.url?.query, "status=unread&category_id=7&changed_after=1700000000&limit=100&offset=0&order=published_at&direction=desc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Auth-Token"), "secret-key")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.entries.first?.id, 42)
    }

    func testMultipleStatusesAreRepeatedParams() async throws {
        let captured = LockedBox<URLRequest>()
        let client = makeClient { req, _ in
            captured.value = req
            return (200, Data(#"{"total":0,"entries":[]}"#.utf8))
        }
        var q = EntryQuery()
        q.status = [.unread, .read]
        q.starred = true
        _ = try await client.entries(q)
        XCTAssertEqual(captured.value?.url?.query, "status=unread&status=read&starred=true&limit=100&offset=0&order=published_at&direction=desc")
    }

    func testDecodesEntryWithEmptyCommentsURLAsNil() async throws {
        let json = entryJSON
        let client = makeClient { _, _ in (200, Data(json.utf8)) }
        let entry = try await client.entries(EntryQuery()).entries[0]
        XCTAssertNil(entry.commentsURL)
        XCTAssertEqual(entry.feedID, 3)
        XCTAssertEqual(entry.status, .unread)
        XCTAssertEqual(entry.url, URL(string: "https://example.com/a"))
        XCTAssertEqual(entry.feed.category, CategoryRef(id: 7, title: "News"))
        XCTAssertFalse(entry.starred)
        // Fractional seconds with an offset, and the same without fractions.
        XCTAssertEqual(entry.publishedAt.timeIntervalSince1970, 1_793_221_921.123, accuracy: 0.001)
        XCTAssertEqual(entry.changedAt.timeIntervalSince1970, 1_793_224_800, accuracy: 0)
    }

    func testSetStatusSendsPUTBody() async throws {
        let captured = LockedBox<URLRequest>()
        let body = LockedBox<Data>()
        let client = makeClient { req, data in
            captured.value = req
            body.value = data
            return (204, Data())
        }
        try await client.setStatus(.read, ids: [1, 2])
        XCTAssertEqual(captured.value?.httpMethod, "PUT")
        XCTAssertEqual(captured.value?.url?.path, "/v1/entries")
        let sent = try XCTUnwrap(body.value)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual(obj["entry_ids"] as? [Int], [1, 2])
        XCTAssertEqual(obj["status"] as? String, "read")
        XCTAssertEqual(captured.value?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testToggleBookmarkPutsToEntryBookmark() async throws {
        let captured = LockedBox<URLRequest>()
        let client = makeClient { req, _ in captured.value = req; return (204, Data()) }
        try await client.toggleBookmark(id: 9)
        XCTAssertEqual(captured.value?.httpMethod, "PUT")
        XCTAssertEqual(captured.value?.url?.path, "/v1/entries/9/bookmark")
    }

    func testTrailingSlashBaseURLDoesNotDoubleUp() async throws {
        let captured = LockedBox<URLRequest>()
        let client = makeClient(base: "/miniflux/") { req, _ in
            captured.value = req
            return (200, Data(#"{"id":1,"username":"lach"}"#.utf8))
        }
        let user = try await client.me()
        XCTAssertEqual(captured.value?.url?.path, "/miniflux/v1/me")
        XCTAssertEqual(user, User(id: 1, username: "lach"))
    }

    func testCategoriesAndEntryDecode() async throws {
        let client = makeClient { req, _ in
            if req.url?.path == "/v1/categories" {
                return (200, Data(#"[{"id":7,"title":"News"},{"id":8,"title":"Tech"}]"#.utf8))
            }
            return (200, Data(#"""
            {"id": 42, "feed_id": 3, "status": "read", "title": "Hello", "url": "https://example.com/a",
             "comments_url": "https://example.com/c", "published_at": "2026-10-29T08:12:01+11:00",
             "changed_at": "2026-10-29T09:00:00.5+11:00", "starred": true,
             "feed": {"id": 3, "title": "HN", "category": {"id": 7, "title": "News"}}}
            """#.utf8))
        }
        let cats = try await client.categories()
        XCTAssertEqual(cats, [CategoryRef(id: 7, title: "News"), CategoryRef(id: 8, title: "Tech")])
        let entry = try await client.entry(id: 42)
        XCTAssertEqual(entry.commentsURL, URL(string: "https://example.com/c"))
        XCTAssertTrue(entry.starred)
        XCTAssertEqual(entry.status, .read)
    }

    func test401MapsToUnauthorized() async {
        let client = makeClient { _, _ in (401, Data()) }
        do { _ = try await client.me(); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? MinifluxError, .unauthorized) }
    }

    func test404MapsToNotFound() async {
        let client = makeClient { _, _ in (404, Data()) }
        do { _ = try await client.entry(id: 5); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? MinifluxError, .notFound) }
    }

    func test500MapsToHTTP() async {
        let client = makeClient { _, _ in (500, Data()) }
        do { _ = try await client.me(); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? MinifluxError, .http(500)) }
    }

    func testGarbageBodyMapsToDecoding() async {
        let client = makeClient { _, _ in (200, Data("nope".utf8)) }
        do { _ = try await client.me(); XCTFail("expected throw") }
        catch {
            guard case .decoding = error as? MinifluxError else { return XCTFail("got \(error)") }
        }
    }

    func testTransportFailureMapsToTransport() async {
        // Unregistered host: the stub fails the request.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = MinifluxClient(baseURL: URL(string: "https://unregistered.test")!, apiKey: "k", session: URLSession(configuration: config))
        do { _ = try await client.me(); XCTFail("expected throw") }
        catch {
            guard case .transport = error as? MinifluxError else { return XCTFail("got \(error)") }
        }
    }
}

/// Mutable capture shared between a test and the stub handler.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
