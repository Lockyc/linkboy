import XCTest
@testable import LinkboyCore

final class StoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkboy-store-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var dbPath: URL { dir.appendingPathComponent("sub/linkboy.sqlite") }

    private func makeStore() throws -> Store { try Store(path: dbPath) }

    private func entry(_ id: Int64, status: EntryStatus = .unread, starred: Bool = false, published: TimeInterval = 1_000,
                       feed: Int64 = 1, category: Int64 = 10, title: String = "T") -> Entry {
        Entry(id: id, feedID: feed, status: status, title: title, url: URL(string: "https://example.com/\(id)")!,
              commentsURL: URL(string: "https://example.com/c/\(id)"), publishedAt: Date(timeIntervalSince1970: published),
              changedAt: Date(timeIntervalSince1970: published + 5.25), starred: starred,
              feed: FeedRef(id: feed, title: "Feed \(feed)", category: CategoryRef(id: category, title: "Cat \(category)")))
    }

    func testEntryRoundTrip() throws {
        let store = try makeStore()
        var e = entry(1)
        var noComments = entry(2)
        noComments.commentsURL = nil
        e.title = "Hello"
        try store.upsert([e, noComments])
        XCTAssertEqual(try store.entries(ids: [2, 99, 1]), [noComments, e])
    }

    func testEntriesKeepRequestOrderAcrossQueryChunks() throws {
        let store = try makeStore()
        try store.upsert((1...2500).map { entry(Int64($0)) })
        let ids = (1...2500).map(Int64.init).reversed() + [99_999]
        XCTAssertEqual(try store.entries(ids: Array(ids)).map(\.id), Array(ids.dropLast()))
    }

    func testUnreadCountAmongIDsAcrossQueryChunks() throws {
        let store = try makeStore()
        try store.upsert((1...2500).map { entry(Int64($0), status: $0 % 5 == 0 ? .read : .unread) })
        try store.upsert([entry(3000, status: .removed)])
        XCTAssertEqual(try store.unreadCount(among: (1...2500).map(Int64.init)), 2000)
        XCTAssertEqual(try store.unreadCount(among: [5, 10, 3000, 99_999]), 0)
        XCTAssertEqual(try store.unreadCount(among: [1, 2, 5, 99_999]), 2)
        XCTAssertEqual(try store.unreadCount(among: []), 0)
    }

    func testRecordWritesEntriesAndQueue() throws {
        let store = try makeStore()
        try store.upsert([entry(1), entry(2)])
        try store.record([.status(id: 1, .read), .starred(id: 2, true)])
        XCTAssertEqual(try store.entries(ids: [1, 2]).map(\.status), [.read, .unread])
        XCTAssertEqual(try store.entries(ids: [1, 2]).map(\.starred), [false, true])
        XCTAssertEqual(try store.pending(), [.status(id: 1, .read), .starred(id: 2, true)])
    }

    func testUpsertPreservesLocalStatusWhilePending() throws {
        let store = try makeStore()
        try store.upsert([entry(1, status: .unread, starred: false)])
        try store.setStatus(.read, ids: [1])
        try store.enqueue([.status(id: 1, .read)])
        try store.upsert([entry(1, status: .unread, starred: true, title: "New")])
        let got = try XCTUnwrap(store.entries(ids: [1]).first)
        XCTAssertEqual(got.status, .read)
        XCTAssertTrue(got.starred)
        XCTAssertEqual(got.title, "New")
    }

    func testUpsertPreservesLocalStarredWhilePending() throws {
        let store = try makeStore()
        try store.upsert([entry(1)])
        try store.setStarred(true, id: 1)
        try store.enqueue([.starred(id: 1, true)])
        try store.upsert([entry(1, status: .read, starred: false)])
        let got = try XCTUnwrap(store.entries(ids: [1]).first)
        XCTAssertTrue(got.starred)
        XCTAssertEqual(got.status, .read)
    }

    func testUpsertTakesServerStateWhenNothingPending() throws {
        let store = try makeStore()
        try store.upsert([entry(1, status: .unread)])
        try store.setStatus(.read, ids: [1])
        try store.upsert([entry(1, status: .unread, starred: true)])
        let got = try XCTUnwrap(store.entries(ids: [1]).first)
        XCTAssertEqual(got.status, .unread)
        XCTAssertTrue(got.starred)
    }

    func testQueueSurvivesReopen() throws {
        let changes: [PendingChange] = [.status(id: 1, .read), .starred(id: 2, true)]
        do {
            let store = try makeStore()
            try store.enqueue(changes)
        }
        XCTAssertEqual(try makeStore().pending(), changes)
    }

    func testEntryIDsOrderNewestFirst() throws {
        let store = try makeStore()
        try store.upsert([entry(1, published: 100), entry(2, published: 300), entry(3, published: 200), entry(4, published: 300)])
        XCTAssertEqual(try store.entryIDs(matching: .unread(category: nil, feed: nil)), [4, 2, 3, 1])
    }

    func testEntryIDsFilters() throws {
        let store = try makeStore()
        try store.upsert([
            entry(1, feed: 1, category: 10), entry(2, feed: 2, category: 10), entry(3, feed: 3, category: 20),
            entry(4, status: .read, starred: true, feed: 1, category: 10),
        ])
        XCTAssertEqual(try store.entryIDs(matching: .unread(category: 10, feed: nil)), [2, 1])
        XCTAssertEqual(try store.entryIDs(matching: .unread(category: nil, feed: 3)), [3])
        XCTAssertEqual(try store.entryIDs(matching: .unread(category: 10, feed: 3)), [])
        XCTAssertEqual(try store.entryIDs(matching: .starred), [4])
    }

    func testRemovedEntriesNeverListed() throws {
        let store = try makeStore()
        try store.upsert([entry(1), entry(2, status: .removed, starred: true)])
        XCTAssertEqual(try store.entryIDs(matching: .unread(category: nil, feed: nil)), [1])
        XCTAssertEqual(try store.entryIDs(matching: .starred), [])
    }

    func testEnqueueCoalescesSameEntry() throws {
        let store = try makeStore()
        try store.enqueue([.status(id: 1, .read)])
        try store.enqueue([.status(id: 1, .unread), .starred(id: 1, true)])
        XCTAssertEqual(try store.pending(), [.status(id: 1, .unread), .starred(id: 1, true)])
        try store.enqueue([.starred(id: 1, false), .starred(id: 1, true)])
        XCTAssertEqual(try store.pending(), [.status(id: 1, .unread), .starred(id: 1, true)])
    }

    func testDequeueRemovesExactChangesOnly() throws {
        let store = try makeStore()
        try store.enqueue([.status(id: 1, .read), .starred(id: 1, true), .status(id: 2, .read)])
        // Replaced by a newer value in the meantime: dequeuing the old value must not remove it.
        try store.enqueue([.status(id: 1, .unread)])
        try store.dequeue([.status(id: 1, .read), .status(id: 2, .read)])
        XCTAssertEqual(try store.pending(), [.starred(id: 1, true), .status(id: 1, .unread)])
        try store.dequeue([.status(id: 1, .unread)])
        XCTAssertEqual(try store.pending(), [.starred(id: 1, true)])
    }

    func testLastSync() throws {
        let store = try makeStore()
        XCTAssertNil(try store.lastSync())
        let d = Date(timeIntervalSince1970: 1_700_000_000.5)
        try store.setLastSync(d)
        XCTAssertEqual(try makeStore().lastSync(), d)
    }

    func testResetClearsEntriesQueueAndLastSync() throws {
        let store = try makeStore()
        try store.upsert([entry(1), entry(2)])
        try store.enqueue([.status(id: 1, .read), .starred(id: 2, true)])
        try store.setLastSync(Date(timeIntervalSince1970: 1_700_000_000))
        let b = URL(string: "https://b.example.com/")!
        try store.reset(for: b)
        XCTAssertEqual(try store.entries(ids: [1, 2]), [])
        XCTAssertEqual(try store.entryIDs(matching: .unread(category: nil, feed: nil)), [])
        XCTAssertEqual(try store.pending(), [])
        XCTAssertNil(try store.lastSync())
        XCTAssertEqual(try store.server(), b)
    }

    func testTheCacheRecordsItsServer() throws {
        let store = try makeStore()
        XCTAssertNil(try store.server())
        let a = URL(string: "https://a.example.com/")!
        try store.setServer(a)
        try store.upsert([entry(1)])
        XCTAssertEqual(try makeStore().server(), a)
        XCTAssertEqual(try store.entries(ids: [1]).count, 1, "recording the server keeps the cache")
    }
}
