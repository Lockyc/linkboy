import Clocks
import XCTest
@testable import LinkboyCore

final class SyncEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkboy-sync-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeStore() throws -> Store { try Store(path: dir.appendingPathComponent("l.sqlite")) }

    func testPushBeforePull() async throws {
        let store = try makeStore(), api = FakeAPI()
        try store.upsert([makeEntry(1)])
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
        api.serverEntries = [1: makeEntry(1, starred: true), 2: makeEntry(2, starred: false)]
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
        // Five minutes before the sync started, so entries changed under a lagging server clock are pulled again.
        let lastSync = try XCTUnwrap(store.lastSync())
        XCTAssertGreaterThanOrEqual(lastSync, before.addingTimeInterval(-300))
        XCTAssertLessThanOrEqual(lastSync, Date().addingTimeInterval(-300))
    }

    func testUndecodableEntriesAreSkippedAndPagingContinues() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.pages = (1...300).map { makeEntry(Int64($0)) }
        api.undecodable = [5, 260]
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(outcome, .ok(newEntryIDs: []))
        XCTAssertEqual(api.queries.map(\.offset), [0, 250, 0, 250])
        XCTAssertEqual(try store.entryIDs(matching: .unread(category: nil, feed: nil)).count, 298)
        XCTAssertNotNil(try store.lastSync())
    }

    func testFirstSyncPagesUnreadThenStarred() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.pages = (1...300).map { makeEntry(Int64($0)) }
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

    func testRejectedChangeOnPushIsDropped() async throws {
        let store = try makeStore(), api = FakeAPI()
        api.errors["setStatus"] = .notFound
        api.errors["entry:5"] = .http(400)
        api.errors["entry:7"] = .http(409)
        api.errors["entry:8"] = .http(422)
        api.serverEntries = [6: makeEntry(6)]
        try store.enqueue([.status(id: 1, .read), .starred(id: 5, true), .starred(id: 6, true), .starred(id: 7, true),
                           .starred(id: 8, true)])
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(outcome, .ok(newEntryIDs: []))
        XCTAssertEqual(try store.pending(), [])
        XCTAssertTrue(api.calls.contains("toggle:6"))
    }

    func testTransient4xxOnPushKeepsChangeAndFails() async throws {
        for code in [403, 408, 429] {
            let store = try Store(path: dir.appendingPathComponent("\(code).sqlite")), api = FakeAPI()
            api.errors["setStatus"] = .http(code)
            try store.enqueue([.status(id: 1, .read)])
            let outcome = await SyncEngine(api: api, store: store).syncNow()
            XCTAssertEqual(outcome, .failed("Server error (HTTP \(code))"), "HTTP \(code)")
            XCTAssertEqual(try store.pending(), [.status(id: 1, .read)], "HTTP \(code)")
        }
    }

    func testAfterUnauthorizedIntentsQueueWithoutSyncingOrEvents() async throws {
        let store = try makeStore(), api = FakeAPI()
        try store.upsert([makeEntry(1), makeEntry(2)])
        api.errors["entries"] = .unauthorized
        let engine = SyncEngine(api: api, store: store)
        var it = engine.events.makeAsyncIterator()
        let first = await engine.syncNow()
        XCTAssertEqual(first, .unauthorized)
        let event = await it.next()
        XCTAssertEqual(event, .unauthorized)
        let callsAfterRejection = api.calls

        await engine.markRead([2])
        await engine.setStarred(true, id: 1)
        await engine.quiesce()
        XCTAssertEqual(api.calls, callsAfterRejection)
        XCTAssertEqual(try store.entries(ids: [2]).first?.status, .read)
        XCTAssertEqual(try store.pending(), [.status(id: 2, .read), .starred(id: 1, true)])

        // An explicit sync still runs, but a repeat rejection is not a new event.
        let again = await engine.syncNow()
        XCTAssertEqual(again, .unauthorized)
        await engine.shutdown()
        var rest: [SyncOutcome] = []
        while let e = await it.next() { rest.append(e) }
        XCTAssertEqual(rest, [])
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
        try store.upsert([makeEntry(1)])
        try store.setLastSync(Date(timeIntervalSince1970: 100))
        api.pages = [makeEntry(1), makeEntry(2), makeEntry(3, status: .read)]
        let outcome = await SyncEngine(api: api, store: store).syncNow()
        XCTAssertEqual(outcome, .ok(newEntryIDs: [2]))
    }

    private static let interval = Duration.seconds(300)

    /// Returns once something is sleeping on `clock`, so an `advance` wakes it rather than racing it.
    private func untilSleeping(_ clock: TestClock<Duration>) async {
        for _ in 0..<1_000 {
            do { try await clock.checkSuspension() } catch { return }
        }
        XCTFail("nothing slept on the clock")
    }

    func testUnauthorizedStopsTimer() async throws {
        let store = try makeStore(), api = FakeAPI(), clock = TestClock()
        api.errors["setStatus"] = .unauthorized
        try store.enqueue([.status(id: 1, .read)])
        let engine = SyncEngine(api: api, store: store, interval: Self.interval, clock: clock)
        var it = engine.events.makeAsyncIterator()
        await engine.start()
        let first = await it.next()
        XCTAssertEqual(first, .unauthorized)
        await clock.advance(by: Self.interval * 10)
        await engine.quiesce()
        XCTAssertEqual(api.calls, ["setStatus"])
    }

    func testTimerSyncsEveryIntervalUntilStopped() async throws {
        let store = try makeStore(), api = FakeAPI(), clock = TestClock()
        let engine = SyncEngine(api: api, store: store, interval: Self.interval, clock: clock)
        var it = engine.events.makeAsyncIterator()
        await engine.start()
        _ = await it.next()
        XCTAssertEqual(api.queries.count, 2, "the first sync pulls unread, then starred")
        for _ in 1...3 {
            await untilSleeping(clock)
            await clock.advance(by: Self.interval)
            _ = await it.next()
        }
        XCTAssertEqual(api.queries.count, 5, "each later sync pulls changes once")
        await untilSleeping(clock)
        await clock.advance(by: Self.interval - .seconds(1))
        await engine.quiesce()
        XCTAssertEqual(api.queries.count, 5, "a sync ran before its interval was up")

        await engine.stop()
        await clock.advance(by: Self.interval * 3)
        await engine.quiesce()
        XCTAssertEqual(api.queries.count, 5)
    }

    func testTimerLoopEndsWhenEngineIsDeallocated() async throws {
        let store = try makeStore(), api = FakeAPI(), clock = TestClock()
        var engine: SyncEngine? = SyncEngine(api: api, store: store, interval: Self.interval, clock: clock)
        weak let weakEngine = engine
        await engine?.start()
        await engine?.quiesce()
        await untilSleeping(clock)
        engine = nil
        await clock.advance(by: Self.interval)
        XCTAssertNil(weakEngine)
        XCTAssertEqual(api.queries.count, 2, "the timer synced after its engine was released")
    }

    func testKicksDuringRunningSyncCoalesceIntoOneFollowUp() async throws {
        let store = try makeStore(), api = FakeAPI(), gate = Gate()
        api.gate = gate
        try store.upsert([1, 2, 3, 4].map { makeEntry($0) })
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
        try store.upsert([makeEntry(1)])
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
        try store.upsert([makeEntry(1), makeEntry(2)])
        let engine = SyncEngine(api: api, store: store)
        var it = engine.events.makeAsyncIterator()
        await engine.markRead([1])
        await gate.waitForArrival()               // the kicked sync is held inside setStatus
        let returned = Flag()
        let shutdown = Task {
            await engine.shutdown()
            returned.set()
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(returned.value, "shutdown returned while a sync was still running")
        await gate.open()
        await shutdown.value

        let calls = api.calls, statusCalls = api.statusCalls.count, pending = try store.pending()
        await engine.markRead([2])
        await engine.setStarred(true, id: 2)
        _ = await engine.syncNow()
        await engine.start()
        await engine.quiesce()
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
