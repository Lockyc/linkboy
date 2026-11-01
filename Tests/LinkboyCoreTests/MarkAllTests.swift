import XCTest
@testable import LinkboyCore

final class MarkAllTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkboy-markall-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() throws -> Store { try Store(path: dir.appendingPathComponent("linkboy.sqlite")) }

    private func entry(_ id: Int64, status: EntryStatus = .unread, feed: Int64 = 1, category: Int64 = 10,
                       starred: Bool = false, published: TimeInterval? = nil) -> Entry {
        let p = published ?? TimeInterval(id)
        return Entry(id: id, feedID: feed, status: status, title: "T\(id)", url: URL(string: "https://example.com/\(id)")!,
                     commentsURL: nil, publishedAt: Date(timeIntervalSince1970: p), changedAt: Date(timeIntervalSince1970: p),
                     starred: starred,
                     feed: FeedRef(id: feed, title: "Feed \(feed)", category: CategoryRef(id: category, title: category == 10 ? "Tech" : "Other")))
    }

    func testMarkAllPlanCoversOnlySnapshotUnread() throws {
        let store = try makeStore()
        try store.upsert([entry(1), entry(2), entry(3)])
        let snap = try Snapshot.take(.unread(category: nil, feed: nil), store: store)
        try store.setStatus(.read, ids: [2])
        try store.upsert([entry(9)])
        let plan = try XCTUnwrap(MarkAllPlan.plan(for: snap, store: store))
        XCTAssertEqual(plan.ids, [3, 1])
        XCTAssertEqual(plan.scope, snap.scope)
    }

    func testPlanIsNilWhenNothingUnread() throws {
        let store = try makeStore()
        try store.upsert([entry(1)])
        let snap = try Snapshot.take(.unread(category: nil, feed: nil), store: store)
        try store.setStatus(.read, ids: [1])
        XCTAssertNil(try MarkAllPlan.plan(for: snap, store: store))
    }

    func testMarkAllPromptCopy() throws {
        let store = try makeStore()
        try store.upsert((1...214).map { entry(Int64($0)) })
        let tech = try Snapshot.take(.unread(category: 10, feed: nil), store: store)
        XCTAssertEqual(try MarkAllPlan.plan(for: tech, store: store)?.prompt, "Mark 214 unread items in Tech as read?")
        let feed = try Snapshot.take(.unread(category: 10, feed: 1), store: store)
        XCTAssertEqual(try MarkAllPlan.plan(for: feed, store: store)?.prompt, "Mark 214 unread items in Feed 1 as read?")

        let single = try makeStore2()
        try single.upsert([entry(1)])
        let all = try Snapshot.take(.unread(category: nil, feed: nil), store: single)
        XCTAssertEqual(try MarkAllPlan.plan(for: all, store: single)?.prompt, "Mark 1 unread item in All feeds as read?")
    }

    func testStarredPromptName() throws {
        let store = try makeStore()
        try store.upsert([entry(1, starred: true), entry(2, starred: true)])
        let snap = try Snapshot.take(.starred, store: store)
        XCTAssertEqual(try MarkAllPlan.plan(for: snap, store: store)?.prompt, "Mark 2 unread items in Starred as read?")
    }

    private func makeStore2() throws -> Store {
        try Store(path: dir.appendingPathComponent("second.sqlite"))
    }
}
