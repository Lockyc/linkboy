import XCTest
@testable import LinkboyCore

/// Holds callers in `pass()` until `open()`; `waitForArrival()` returns once a caller is held.
private actor Gate {
    private var isOpen = false
    private var arrived = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiter: CheckedContinuation<Void, Never>?

    func pass() async {
        arrived += 1
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        if isOpen { return }
        await withCheckedContinuation { held.append($0) }
    }

    func waitForArrival() async {
        if arrived > 0 { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func open() {
        isOpen = true
        held.forEach { $0.resume() }
        held = []
    }
}

private final class FakeAPI: MinifluxAPI, @unchecked Sendable {
    var gate: Gate?                               // setStatus blocks here, then throws .transport if its task was cancelled
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _queries: [EntryQuery] = []
    private var _statusCalls: [(EntryStatus, [Int64])] = []
    var pages: [Entry] = []                       // served for every entries() call, sliced by offset/limit
    var serverEntries: [Int64: Entry] = [:]
    var errors: [String: MinifluxError] = [:]     // keyed by call name, e.g. "setStatus", "entries", "entry:7"

    var calls: [String] { lock.withLock { _calls } }
    var queries: [EntryQuery] { lock.withLock { _queries } }
    var statusCalls: [(EntryStatus, [Int64])] { lock.withLock { _statusCalls } }

    private func record(_ name: String, key: String? = nil) throws {
        let err: MinifluxError? = lock.withLock {
            _calls.append(name)
            return errors[key ?? name] ?? errors[name]
        }
        if let err { throw err }
    }

    func me() async throws -> User { User(id: 1, username: "u") }
    func categories() async throws -> [CategoryRef] { [] }

    func entries(_ q: EntryQuery) async throws -> (total: Int, entries: [Entry]) {
        lock.withLock { _queries.append(q) }
        try record("entries")
        let slice = Array(pages.dropFirst(q.offset).prefix(q.limit))
        return (pages.count, slice)
    }

    func entry(id: Int64) async throws -> Entry {
        try record("entry", key: "entry:\(id)")
        return serverEntries[id]!
    }

    func setStatus(_ s: EntryStatus, ids: [Int64]) async throws {
        lock.withLock { _statusCalls.append((s, ids)) }
        await gate?.pass()
        if gate != nil, Task.isCancelled { throw MinifluxError.transport("cancelled") }
        try record("setStatus")
    }

    func toggleBookmark(id: Int64) async throws { try record("toggle:\(id)") }
}

final class SyncEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkboy-sync-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeStore() throws -> Store { try Store(path: dir.appendingPathComponent("l.sqlite")) }

    private func entry(_ id: Int64, status: EntryStatus = .unread, starred: Bool = false) -> Entry {
        Entry(id: id, feedID: 1, status: status, title: "T", url: URL(string: "https://example.com/\(id)")!,
              commentsURL: nil, publishedAt: Date(timeIntervalSince1970: 1_000 + Double(id)),
              changedAt: Date(timeIntervalSince1970: 2_000), starred: starred,
              feed: FeedRef(id: 1, title: "F", category: CategoryRef(id: 10, title: "C")))
    }

    func testPushBeforePull() async throws {
        let store = try makeStore(), api = FakeAPI()
        try store.upsert([entry(1)])
        try store.setStatus(.read, ids: [1])
        try store.enqueue([.status(id: 1, .read)])
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(outcome, .ok(newEntryIDs: []))
        XCTAssertEqual(api.calls.first, "setStatus")
        XCTAssertTrue(api.calls.contains("entries"))
        XCTAssertEqual(try store.pending(), [])
    }

    func testStatusChangesBatchedPerStatus() async throws {
        let store = try makeStore(), api = FakeAPI()
        let readIDs = Array(1...1500).map(Int64.init)
        try store.enqueue(readIDs.map { .status(id: $0, .read) } + [.status(id: 2000, .unread), .status(id: 2001, .unread)])
        _ = await SyncEngine(api: api, store: store).syncNow()
        let calls = api.statusCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.filter { $0.0 == .read }.map(\.1.count).sorted(), [500, 1000])
        XCTAssertEqual(calls.filter { $0.0 == .unread }.map(\.1), [[2000, 2001]])
        XCTAssertEqual(try store.pending(), [])
    }

    func testStarPushTogglesOnlyWhenServerDiffers() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.serverEntries = [1: entry(1, starred: true), 2: entry(2, starred: false)]
        try store.enqueue([.starred(id: 1, true), .starred(id: 2, true)])
        _ = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("toggle") }, ["toggle:2"])
        XCTAssertEqual(try store.pending(), [])
    }

    func testIncrementalPullUsesChangedAfterLastSync() async throws {
        let store = try makeStore(), api = FakeAPI()
        let last = Date(timeIntervalSince1970: 5_000)
        try store.setLastSync(last)
        let before = Date()
        _ = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(api.queries.count, 1)
        XCTAssertEqual(api.queries[0].changedAfter, last)
        XCTAssertNil(api.queries[0].status)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.lastSync()), before)
    }

    func testFirstSyncPagesUnreadThenStarred() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.pages = (1...300).map { entry(Int64($0)) }
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(outcome, .ok(newEntryIDs: []))
        let qs = api.queries
        XCTAssertEqual(qs.map(\.offset), [0, 250, 0, 250])
        XCTAssertEqual(qs.map(\.limit), [250, 250, 250, 250])
        XCTAssertEqual(qs[0].status, [.unread])
        XCTAssertEqual(qs[2].starred, true)
        XCTAssertEqual(try store.entryIDs(matching: .unread(category: nil, feed: nil)).count, 300)
    }

    func testTransportErrorYieldsOfflineAndKeepsQueue() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.errors["setStatus"] = .transport("down")
        try store.enqueue([.status(id: 1, .read)])
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(outcome, .offline)
        XCTAssertEqual(try store.pending(), [.status(id: 1, .read)])
        XCTAssertFalse(api.calls.contains("entries"))
    }

    func testUnauthorizedStopsLoopAndKeepsQueue() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.errors["setStatus"] = .unauthorized
        try store.enqueue([.status(id: 1, .read), .status(id: 2, .unread), .starred(id: 3, true)])
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(outcome, .unauthorized)
        XCTAssertEqual(api.calls, ["setStatus"])
        XCTAssertEqual(try store.pending().count, 3)
    }

    func test4xxOnPushDropsThatChange() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.errors["setStatus"] = .notFound
        api.errors["entry:5"] = .http(400)
        api.serverEntries = [6: entry(6)]
        try store.enqueue([.status(id: 1, .read), .starred(id: 5, true), .starred(id: 6, true)])
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(outcome, .ok(newEntryIDs: []))
        XCTAssertEqual(try store.pending(), [])
        XCTAssertTrue(api.calls.contains("toggle:6"))
    }

    func testServerErrorOnPushKeepsChangeAndFails() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.errors["setStatus"] = .http(503)
        try store.enqueue([.status(id: 1, .read)])
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try store.pending().count, 1)
    }

    func testNewEntryIDsReportsOnlyUnseen() async throws {
        let store = try makeStore(), api = FakeAPI()
        try store.upsert([entry(1)])
        try store.setLastSync(Date(timeIntervalSince1970: 100))
        api.pages = [entry(1), entry(2), entry(3, status: .read)]
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(outcome, .ok(newEntryIDs: [2]))
    }

    func testUnauthorizedStopsTimer() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.errors["setStatus"] = .unauthorized
        try store.enqueue([.status(id: 1, .read)])
        let engine = SyncEngine(api: api, store: store, interval: .milliseconds(5))
        var it = engine.events.makeAsyncIterator()
        await engine.start()
        let first = await it.next()
        XCTAssertEqual(first, .unauthorized)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(api.calls, ["setStatus"])
    }

    func testStopEndsTimer() async throws {
        let store = try makeStore(), api = FakeAPI()
        let engine = SyncEngine(api: api, store: store, interval: .milliseconds(5))
        var it = engine.events.makeAsyncIterator()
        await engine.start()
        _ = await it.next()
        _ = await it.next()
        await engine.stop()
        try await Task.sleep(for: .milliseconds(100))
        let settled = api.calls.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.calls.count, settled)
    }

    func testTimerLoopEndsWhenEngineIsDeallocated() async throws {
        let store = try makeStore(), api = FakeAPI()
        var engine: SyncEngine? = SyncEngine(api: api, store: store, interval: .milliseconds(5))
        weak let weakEngine = engine
        await engine?.start()
        engine = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(weakEngine)
    }

    func testKicksDuringRunningSyncCoalesceIntoOneFollowUp() async throws {
        let store = try makeStore(), api = FakeAPI(), gate = Gate()
        api.gate = gate
        try store.upsert([1, 2, 3, 4].map { entry($0) })
        let engine = SyncEngine(api: api, store: store)
        var it = engine.events.makeAsyncIterator()
        await engine.markRead([1])
        await gate.waitForArrival()               // sync 1 is now held inside setStatus
        await engine.markRead([2])
        await engine.markRead([3])
        await engine.markRead([4])
        await gate.open()
        let e1 = await it.next(), e2 = await it.next()
        XCTAssertEqual([e1, e2], [.ok(newEntryIDs: []), .ok(newEntryIDs: [])])
        XCTAssertEqual(api.statusCalls.map(\.1), [[1], [2, 3, 4]])
        XCTAssertEqual(try store.pending(), [])
    }

    func testCancelledSyncEmitsNothingAndKeepsQueue() async throws {
        let store = try makeStore(), api = FakeAPI(), gate = Gate()
        api.gate = gate
        try store.enqueue([.status(id: 1, .read)])
        let engine = SyncEngine(api: api, store: store)
        var it = engine.events.makeAsyncIterator()
        let task = Task { await engine.syncNow() }
        await gate.waitForArrival()
        task.cancel()
        await gate.open()
        _ = await task.value
        XCTAssertEqual(try store.pending(), [.status(id: 1, .read)])
        // The next event on the stream must be the follow-up sync's, proving the cancelled one emitted none.
        let outcome = await engine.syncNow()
        XCTAssertEqual(outcome, .ok(newEntryIDs: []))
        let next = await it.next()
        XCTAssertEqual(next, .ok(newEntryIDs: []))
        XCTAssertEqual(try store.pending(), [])
    }

    func testMarkReadWritesStoreQueuesAndPushesInBackground() async throws {
        let store = try makeStore(), api = FakeAPI()
        try store.upsert([entry(1)])
        let engine = SyncEngine(api: api, store: store)
        var it = engine.events.makeAsyncIterator()
        await engine.markRead([1])
        XCTAssertEqual(try store.entries(ids: [1]).first?.status, .read)
        let outcome = await it.next()
        XCTAssertEqual(outcome, .ok(newEntryIDs: []))
        XCTAssertEqual(api.statusCalls.map(\.1), [[1]])
        XCTAssertEqual(try store.pending(), [])
    }

    func testShutdownWaitsForInFlightSyncThenIgnoresEverything() async throws {
        let store = try makeStore(), api = FakeAPI(), gate = Gate()
        api.gate = gate
        try store.upsert([entry(1), entry(2)])
        let engine = SyncEngine(api: api, store: store)
        var it = engine.events.makeAsyncIterator()
        await engine.markRead([1])
        await gate.waitForArrival()               // the kicked sync is held inside setStatus
        let returned = Flag()
        let shutdown = Task {
            await engine.shutdown()
            returned.set()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(returned.value, "shutdown returned while a sync was still running")
        await gate.open()
        await shutdown.value

        let calls = api.calls, statusCalls = api.statusCalls.count, pending = try store.pending()
        await engine.markRead([2])
        await engine.setStarred(true, id: 2)
        _ = await engine.syncNow()
        await engine.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(api.calls, calls)
        XCTAssertEqual(api.statusCalls.count, statusCalls)
        XCTAssertEqual(try store.pending(), pending)
        XCTAssertEqual(try store.entries(ids: [2]).first?.status, .unread)
        XCTAssertEqual(try store.entries(ids: [2]).first?.starred, false)
        var events: [SyncOutcome] = []
        while let e = await it.next() { events.append(e) }   // ends: shutdown finishes the stream
        XCTAssertEqual(events, [])
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
