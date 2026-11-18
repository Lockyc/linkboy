import Exhaust
import XCTest
@testable import LinkboyCore

final class PropertyTests: XCTestCase {
    /// However the endpoint is pasted (slashes, a `/v1` in either case, trailing slashes), it names the same
    /// server as the bare base URL, normalising it again changes nothing, and the client's requests carry one `/v1`.
    func testServerURLNamesTheSameServerHoweverItIsPasted() {
        let pasted = #gen(
            .element(from: ["http", "https", "HTTPS"]),
            .element(from: ["localhost", "reader.local", "192.168.1.5", "[::1]", "news.example.com"]),
            .element(from: ["", "/miniflux", "/a/b"]),
            .int(in: 0...2),
            .element(from: ["v1", "V1"]),
            .int(in: 0...3)
        ) { scheme, host, base, slashesBeforeV1, v1, trailing in
            let root = "\(scheme)://\(host)\(base)"
            let endpoint = slashesBeforeV1 == 0 ? "" : String(repeating: "/", count: slashesBeforeV1) + v1
            return (root: root, text: root + endpoint + String(repeating: "/", count: trailing))
        }
        #exhaust(pasted) { input in
            guard let url = try? Credentials.serverURL(from: input.text) else {
                // Refused only as plain http to a server that isn't local, whatever the shape.
                return (try? Credentials.serverURL(from: input.root)) == nil
            }
            let again = try Credentials.serverURL(from: url.absoluteString)
            let bare = try Credentials.serverURL(from: input.root)
            let path = MinifluxClient(baseURL: url, apiKey: "k").request("/v1/me").url?.path ?? ""
            return again == url && url == bare && !path.lowercased().contains("/v1/v1") && !path.contains("//")
        }
    }

    /// `entries(ids:)` reads in chunks under SQLite's parameter limit: across any number of chunks it returns
    /// exactly the known ids, in the order asked, duplicates included.
    func testEntriesByIdAcrossChunksKeepsOrderAndSkipsUnknown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkboy-prop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(path: dir.appendingPathComponent("l.sqlite"))
        let known: ClosedRange<Int64> = 1...2_000
        try store.upsert(known.map { makeEntry($0) })
        #exhaust(#gen(.int(in: 1...4_000).array(length: 0...3_000))) { ids in
            let asked = ids.map(Int64.init)
            return try store.entries(ids: asked).map(\.id) == asked.filter(known.contains)
        }
    }

    /// A page whose elements fail to decode one by one still yields every good entry, in order, and counts the rest
    /// as skipped, so paging can tell a short page from a full one.
    func testPageDecodeAccountsForEveryServedElement() async {
        await #exhaust(#gen(.int(in: 0...5).array(length: 0...30))) { kinds in
            let elements = kinds.enumerated().map { i, kind in Self.element(id: i + 1, kind: kind) }
            let json = #"{"total": \#(kinds.count), "entries": ["# + elements.joined(separator: ",") + "]}"
            let page = try await Self.client(serving: json).entries(EntryQuery())
            let good = kinds.enumerated().filter { $0.element == 0 }.map { Int64($0.offset + 1) }
            return page.entries.map(\.id) == good && page.entries.count + page.skipped == kinds.count
        }
    }

    /// Kind 0 decodes; every other kind is an element Miniflux could serve that must not.
    private static func element(id: Int, kind: Int) -> String {
        func entry(url: String = "https://example.com/\(id)", published: String = "2026-10-29T08:12:01+11:00") -> String {
            """
            {"id": \(id), "feed_id": 3, "status": "unread", "title": "T", "url": "\(url)", "comments_url": "",
             "published_at": "\(published)", "changed_at": "2026-10-29T09:00:00+11:00", "starred": false,
             "feed": {"id": 3, "title": "HN", "category": {"id": 7, "title": "News"}}}
            """
        }
        switch kind {
        case 0: return entry()
        case 1: return entry(url: "")
        case 2: return entry(published: "yesterday")
        case 3: return #"{"id": \#(id)}"#
        case 4: return #"{"id": "\#(id)"}"#
        default: return "null"
        }
    }

    private static func client(serving json: String) -> MinifluxClient {
        let host = "\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(host: host) { _, _ in (200, Data(json.utf8)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return MinifluxClient(baseURL: URL(string: "https://\(host)")!, apiKey: "k", session: URLSession(configuration: config))
    }
}
