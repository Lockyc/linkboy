import XCTest
@testable import LinkboyCore

final class SnapshotTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkboy-snapshot-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() throws -> Store { try Store(path: dir.appendingPathComponent("linkboy.sqlite")) }

    private func entry(_ id: Int64, status: EntryStatus = .unread, published: TimeInterval) -> Entry {
        Entry(id: id, feedID: 1, status: status, title: "T\(id)", url: URL(string: "https://example.com/\(id)")!,
              commentsURL: nil, publishedAt: Date(timeIntervalSince1970: published),
              changedAt: Date(timeIntervalSince1970: published), starred: false,
              feed: FeedRef(id: 1, title: "Feed", category: CategoryRef(id: 10, title: "Tech")))
    }

    /// Ids 3, 2, 1 in list order (newest first).
    private func seeded() throws -> Store {
        let store = try makeStore()
        try store.upsert([entry(1, published: 100), entry(2, published: 200), entry(3, published: 300)])
        return store
    }

    func testTakeStartsWithoutCursor() throws {
        let snap = try Snapshot.take(.unread(category: nil, feed: nil), store: seeded())
        XCTAssertEqual(snap.ids, [3, 2, 1])
        XCTAssertNil(snap.cursor)
        XCTAssertEqual(snap.newCount, 0)
    }

    func testNextAndPreviousClampAtEnds() throws {
        var snap = try Snapshot.take(.unread(category: nil, feed: nil), store: seeded())
        XCTAssertNil(snap.previous())
        XCTAssertEqual(snap.next(), 3)
        XCTAssertNil(snap.previous())
        XCTAssertEqual(snap.cursor, 0)
        XCTAssertEqual(snap.next(), 2)
        XCTAssertEqual(snap.next(), 1)
        XCTAssertNil(snap.next())
        XCTAssertEqual(snap.cursor, 2)
        XCTAssertEqual(snap.previous(), 2)
    }

    func testNextOnEmptySnapshotIsNil() throws {
        var snap = try Snapshot.take(.starred, store: seeded())
        XCTAssertNil(snap.next())
        XCTAssertNil(snap.cursor)
    }

    func testPrefetchTargetsNextOnly() throws {
        let snap = try Snapshot.take(.unread(category: nil, feed: nil), store: seeded())
        XCTAssertEqual(snap.prefetchTargets(after: 3, depth: 1), [2])
    }

    func testPrefetchTargetsEmptyAtEnd() throws {
        let snap = try Snapshot.take(.unread(category: nil, feed: nil), store: seeded())
        XCTAssertEqual(snap.prefetchTargets(after: 1, depth: 1), [])
        XCTAssertEqual(snap.prefetchTargets(after: 99, depth: 1), [])
    }

    func testPrefetchTargetsRespectsDepth() throws {
        let snap = try Snapshot.take(.unread(category: nil, feed: nil), store: seeded())
        XCTAssertEqual(snap.prefetchTargets(after: 3, depth: 2), [2, 1])
        XCTAssertEqual(snap.prefetchTargets(after: 2, depth: 5), [1])
        XCTAssertEqual(snap.prefetchTargets(after: 3, depth: 0), [])
    }

    func testReadItemStaysInSnapshot() throws {
        let store = try seeded()
        var snap = try Snapshot.take(.unread(category: nil, feed: nil), store: store)
        XCTAssertEqual(snap.next(), 3)
        try store.setStatus(.read, ids: [3])
        XCTAssertEqual(snap.ids, [3, 2, 1])
        XCTAssertEqual(snap.next(), 2)
    }

    func testArrivalsCountButDoNotJoin() throws {
        var snap = try Snapshot.take(.unread(category: nil, feed: nil), store: seeded())
        snap.noteArrivals([9])
        XCTAssertEqual(snap.newCount, 1)
        XCTAssertEqual(snap.ids, [3, 2, 1])
        snap.noteArrivals([9, 3])
        XCTAssertEqual(snap.newCount, 1)
    }

    func testRetakeIncludesArrivalsAndResetsCount() throws {
        let store = try seeded()
        var snap = try Snapshot.take(.unread(category: nil, feed: nil), store: store)
        try store.upsert([entry(9, published: 900)])
        snap.noteArrivals([9])
        snap = try Snapshot.take(snap.scope, store: store)
        XCTAssertEqual(snap.ids, [9, 3, 2, 1])
        XCTAssertEqual(snap.newCount, 0)
    }

    func testPreviousAfterReadLandsOnIt() throws {
        let store = try seeded()
        var snap = try Snapshot.take(.unread(category: nil, feed: nil), store: store)
        XCTAssertEqual(snap.next(), 3)
        try store.setStatus(.read, ids: [3])
        XCTAssertEqual(snap.next(), 2)
        XCTAssertEqual(snap.previous(), 3)
    }
}
