import XCTest
@testable import LinkboyCore

@MainActor
final class ReadingSessionTests: XCTestCase {
    private var dir: URL!
    private let serverA = URL(string: "https://a.example")!
    private let serverB = URL(string: "https://b.example")!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkboy-session-\(UUID().uuidString)")
    }

    private var sessions: [ReadingSession] = []

    /// Shuts each session's engine down, so no timer outlives the test or its store.
    override func tearDown() async throws {
        for s in sessions {
            await s.handoff?.value
            await s.engine?.shutdown()
        }
        sessions = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() throws -> Store { try Store(path: dir.appendingPathComponent("l.sqlite")) }

    private func makeSession(_ store: Store,
                             engine: @escaping (MinifluxAPI, Store) -> SyncEngine = { SyncEngine(api: $0, store: $1) })
        throws -> ReadingSession {
        let s = try ReadingSession(store: store, makeEngine: engine)
        sessions.append(s)
        return s
    }

    /// Every change the session hands its window, in order, awaitable one at a time.
    private func changes(of session: ReadingSession) -> AsyncStream<ReadingSession.Change>.Iterator {
        let (stream, continuation) = AsyncStream<ReadingSession.Change>.makeStream()
        session.onChange = { continuation.yield($0) }
        return stream.makeAsyncIterator()
    }

    /// Waits for the session's next `.synced`, failing on a sync that did not succeed.
    private func nextSync(_ it: inout AsyncStream<ReadingSession.Change>.Iterator) async throws {
        while let change = await it.next() {
            switch change {
            case .synced: return
            case .status(let s) where s.hasPrefix("Sync failed") || s == "Offline": return XCTFail(s)
            default: continue
            }
        }
        XCTFail("the change stream ended")
    }

    func testServerChangeHandsOverOnlyAfterTheOldEngineStops() async throws {
        let store = try makeStore()
        try store.reset(for: serverA)
        try store.upsert([makeEntry(1), makeEntry(2)])
        try store.enqueue([.status(id: 1, .read)])
        try store.setLastSync(Date(timeIntervalSince1970: 5_000))
        let apiA = FakeAPI(), apiB = FakeAPI(), gate = Gate()
        apiA.gate = gate
        let session = try makeSession(store)
        var it = changes(of: session)

        XCTAssertFalse(session.attach(api: apiA, server: serverA))
        await session.handoff?.value
        await gate.waitForArrival()               // A's first sync is held pushing id 1
        XCTAssertTrue(session.attach(api: apiB, server: serverB))
        session.record([.starred(id: 2, true)])   // in the handoff gap: no engine attached
        await gate.open()
        await session.handoff?.value
        try await nextSync(&it)

        XCTAssertEqual(apiA.statusCalls.map(\.1), [[1]])
        XCTAssertEqual(apiB.statusCalls.count, 0, "server A's queued read reached server B")
        XCTAssertFalse(apiB.calls.contains { $0.hasPrefix("toggle") || $0 == "entry" }, "\(apiB.calls)")
        XCTAssertNil(apiB.queries.first?.changedAfter, "server B's first pull used server A's last-sync mark")
        XCTAssertEqual(apiB.queries.first?.status, [.unread])
        XCTAssertEqual(try store.server(), serverB)
        XCTAssertEqual(try store.pending(), [])
    }

    func testRecordWithNoEngineAttachedQueuesForTheNextEngine() async throws {
        let store = try makeStore()
        try store.reset(for: serverA)
        try store.upsert([makeEntry(1), makeEntry(2)])
        let api = FakeAPI()
        api.serverEntries = [2: makeEntry(2)]
        let session = try makeSession(store)
        var it = changes(of: session)

        XCTAssertNil(session.record([.status(id: 1, .read)]))
        XCTAssertEqual(try store.pending(), [.status(id: 1, .read)])
        XCTAssertEqual(try store.entries(ids: [1]).first?.status, .read)

        // Re-attaching the same server (a new key) keeps the cache, so a star made mid-handoff is pushed too.
        XCTAssertFalse(session.attach(api: api, server: serverA))
        XCTAssertNil(session.record([.starred(id: 2, true)]))
        await session.handoff?.value
        try await nextSync(&it)
        XCTAssertEqual(api.statusCalls.map(\.1), [[1]])
        XCTAssertTrue(api.calls.contains("toggle:2"), "\(api.calls)")
        XCTAssertEqual(try store.pending(), [])
    }

    func testCacheWithNoServerRecordedIsAdoptedNotEmptied() async throws {
        let store = try makeStore()
        try store.upsert([makeEntry(1)])
        try store.enqueue([.status(id: 1, .read)])
        let session = try makeSession(store)
        var it = changes(of: session)
        let api = FakeAPI()
        XCTAssertFalse(session.attach(api: api, server: serverA))
        await session.handoff?.value
        try await nextSync(&it)
        XCTAssertEqual(try store.server(), serverA)
        XCTAssertEqual(api.statusCalls.map(\.1), [[1]])
    }

    func testOkSyncRefreshesTheOpenItemAndTheRows() async throws {
        let store = try makeStore()
        try store.reset(for: serverA)
        try store.upsert([makeEntry(1), makeEntry(2)])
        try store.setLastSync(Date(timeIntervalSince1970: 5_000))
        let api = FakeAPI()
        api.pages = [makeEntry(1, starred: true)]  // starred elsewhere
        let session = try makeSession(store)
        session.current = try store.entries(ids: [1]).first
        var it = changes(of: session)

        session.attach(api: api, server: serverA)
        var rows: [Entry]?
        while let change = await it.next() {
            if case .rows(let r) = change { rows = r }
            if change == .synced { break }
        }
        XCTAssertEqual(session.current?.starred, true, "the open item kept its pre-sync star, so `s` would re-send it")
        XCTAssertEqual(rows?.first { $0.id == 1 }?.starred, true)
        XCTAssertEqual(session.snapshot.ids, [2, 1], "a sync changed the list's membership")
    }

    func testLaterAttachSupersedesAnEarlierOneStillHandingOver() async throws {
        let store = try makeStore()
        try store.reset(for: serverA)
        var made: [ObjectIdentifier] = []
        let apiA = FakeAPI(), apiB = FakeAPI()
        let session = try makeSession(store) { api, store in
            made.append(ObjectIdentifier(api as AnyObject))
            return SyncEngine(api: api, store: store)
        }
        var it = changes(of: session)
        session.attach(api: apiA, server: serverA)
        session.attach(api: apiB, server: serverA)
        await session.handoff?.value
        try await nextSync(&it)
        XCTAssertEqual(made, [ObjectIdentifier(apiB)])
        XCTAssertEqual(apiA.calls, [])
    }

    func testRetakeKeepsTheOpenItemSelected() throws {
        let store = try makeStore()
        try store.upsert([makeEntry(1), makeEntry(2), makeEntry(3)])
        let session = try makeSession(store)
        var seen: [ReadingSession.Change] = []
        session.onChange = { seen.append($0) }
        session.current = try store.entries(ids: [2]).first
        try store.upsert([makeEntry(4)])
        session.take(.unread(category: nil, feed: nil))
        XCTAssertEqual(session.snapshot.ids, [4, 3, 2, 1])
        XCTAssertEqual(session.snapshot.cursor, 2)
        XCTAssertEqual(seen, [.listTaken])
    }

    func testOkSyncRetakesAnEmptyListOnly() throws {
        let store = try makeStore()
        let session = try makeSession(store)
        var seen: [ReadingSession.Change] = []
        session.onChange = { seen.append($0) }
        try store.upsert([makeEntry(1), makeEntry(2)])
        session.handle(.ok(newEntryIDs: [1, 2]))
        XCTAssertEqual(session.snapshot.ids, [2, 1], "the first sync's entries didn't fill the empty list")
        XCTAssertTrue(seen.contains(.listTaken))

        seen = []
        try store.upsert([makeEntry(3)])
        session.handle(.ok(newEntryIDs: [3]))
        XCTAssertEqual(session.snapshot.ids, [2, 1], "a sync changed a non-empty list's membership")
        XCTAssertEqual(session.snapshot.newCount, 1)
        XCTAssertFalse(seen.contains(.listTaken))
    }

    func testUnauthorizedDisablesSyncNowUntilAttach() throws {
        let session = try makeSession(try makeStore())
        var seen: [ReadingSession.Change] = []
        session.onChange = { seen.append($0) }
        session.handle(.unauthorized)
        XCTAssertEqual(seen, [.status("Miniflux rejected the API key"), .unauthorized, .chrome])
        XCTAssertEqual(session.syncUnavailable, "Miniflux rejected the API key")
        session.attach(api: FakeAPI(), server: serverA)
        XCTAssertFalse(session.rejected)
    }
}
