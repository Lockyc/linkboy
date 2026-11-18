import Exhaust
import XCTest
@testable import LinkboyCore

final class SessionStateMachineTests: XCTestCase {
    /// Generated sequences of attaches, reads, stars, syncs, starts, stops, shutdowns and server errors, with the
    /// store, the queue and both servers' fakes checked against a model after every step.
    func testSessionStoreAndServersAgreeWithTheModel() async {
        await #execute(SessionSpec.self, mode: .sequential, .commandLimit(15))
    }
}

/// One cache, one `ReadingSession`, and a fake Miniflux for each of two servers. Every call returns only once
/// the engine has nothing running or scheduled, so the next step sees a settled state.
final class SessionHarness: @unchecked Sendable {
    static let servers = [URL(string: "https://a.example")!, URL(string: "https://b.example")!]
    static let errors: [MinifluxError?] = [nil, .unauthorized, .transport("down"), .http(503), .notFound, .http(422)]
    /// Indices into `errors` the engine drops a change on rather than keeping it.
    static let permanent: Set<Int> = [4, 5]

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkboy-spec-\(UUID().uuidString)")
    let store: Store
    let apis = [FakeAPI(), FakeAPI()]
    private var session: ReadingSession?
    private var engines: [SyncEngine] = []

    init() {
        store = try! Store(path: dir.appendingPathComponent("l.sqlite"))
        for api in apis { api.serverEntries = Dictionary(uniqueKeysWithValues: (1...4).map { ($0, makeEntry($0)) }) }
    }

    deinit {
        let engines = engines, dir = dir
        Task {
            for e in engines { await e.shutdown() }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @MainActor private func live() -> ReadingSession {
        if let session { return session }
        let s = try! ReadingSession(store: store)
        session = s
        return s
    }

    var engine: SyncEngine? { get async { await MainActor.run { session?.engine } } }

    /// Attaches `server`; `gap`, when given, is recorded after the attach call and before its handoff ends.
    func attach(_ server: Int, gap: PendingChange? = nil) async {
        let handoff = await MainActor.run {
            let s = live()
            s.attach(api: apis[server], server: Self.servers[server])
            if let gap { s.record([gap]) }
            return s.handoff
        }
        await handoff?.value
        if let e = await engine {
            engines.append(e)
            await e.quiesce()
        }
    }

    func record(_ change: PendingChange) async {
        let write = await MainActor.run { live().record([change]) }
        await write?.value
        await engine?.quiesce()
    }

    func syncNow() async {
        guard let e = await engine else { return }
        await e.syncNow()
        await e.quiesce()
    }

    func start() async {
        guard let e = await engine else { return }
        await e.start()
        await e.quiesce()
    }

    func stop() async { await engine?.stop() }

    func shutdown() async { await engine?.shutdown() }

    func setError(_ server: Int, _ choice: Int) {
        let e = Self.errors[choice]
        apis[server].errors = e.map { ["setStatus": $0, "entries": $0, "entry": $0] } ?? [:]
    }

    /// Ids a server has been sent, by `setStatus` or a star toggle.
    func idsSent(to server: Int) -> Set<Int64> {
        let api = apis[server]
        let toggled = api.calls.compactMap { $0.hasPrefix("toggle:") ? Int64($0.dropFirst(7)) : nil }
        return Set(api.statusCalls.flatMap(\.1) + toggled)
    }
}

@StateMachine
final class SessionSpec {
    @SystemUnderTest var h = SessionHarness()

    /// The server the cache records as its own; nil before the first attach.
    var cacheServer: Int?
    /// The queue, keyed by entry and kind.
    var pending: [String: String] = [:]
    /// The attached engine: its server, whether it is shut down, whether its timer runs, whether the key is rejected.
    var engine: (server: Int, alive: Bool, running: Bool, rejected: Bool)?
    /// Ids recorded while each server's cache was the store's (-1: before any server was recorded).
    var recordedOn: [Int: Set<Int64>] = [:]
    /// Each server's error choice.
    var errors = [0, 0]
    /// A shut-down engine's server and the call count its fake must keep.
    var frozen: [Int: Int] = [:]

    @Invariant
    func cacheIsTheLastAttachedServers() -> Bool {
        (try? h.store.server()) == cacheServer.map { SessionHarness.servers[$0] }
    }

    @Invariant
    func queueMatchesTheModel() -> Bool {
        guard let queue = try? h.store.pending() else { return false }
        return Dictionary(uniqueKeysWithValues: queue.map(Self.key)) == pending
    }

    @Invariant
    func everyIdSentWasRecordedForThatServer() -> Bool {
        (0...1).allSatisfy { h.idsSent(to: $0).isSubset(of: recordedOn[$0, default: []]) }
    }

    @Invariant
    func aShutDownEngineCallsNothing() -> Bool {
        frozen.allSatisfy { h.apis[$0.key].calls.count == $0.value }
    }

    @Command(weight: 2, .int(in: 0...1))
    func attach(server: Int) async throws {
        let old = engine?.server
        attachModel(server, gap: nil)
        await h.attach(server)
        freezeReplaced(old, by: server)
    }

    /// The handoff gap: a read recorded after `attach` returns and before the new engine is attached.
    @Command(weight: 1, .int(in: 0...1), .int(in: 1...4))
    func attachThenRead(server: Int, id: Int) async throws {
        let old = engine?.server
        let change = PendingChange.status(id: Int64(id), .read)
        attachModel(server, gap: change)
        await h.attach(server, gap: change)
        freezeReplaced(old, by: server)
    }

    /// The replaced engine is shut down, so its server hears nothing more until it is attached again.
    private func freezeReplaced(_ old: Int?, by server: Int) {
        if let old, old != server { frozen[old] = h.apis[old].calls.count }
    }

    @Command(weight: 4, .int(in: 1...4), .int(in: 0...3))
    func record(id: Int, kind: Int) async throws {
        let change: PendingChange = switch kind {
        case 0: .status(id: Int64(id), .read)
        case 1: .status(id: Int64(id), .unread)
        default: .starred(id: Int64(id), kind == 2)
        }
        if let e = engine {
            guard e.alive else { throw skip() }
            queue(change)
            if !e.rejected { sync() }
        } else {
            queue(change)
        }
        await h.record(change)
    }

    @Command(weight: 2)
    func syncNow() async throws {
        guard engine?.alive == true else { throw skip() }
        sync()
        await h.syncNow()
    }

    @Command(weight: 1)
    func start() async throws {
        guard let e = engine, e.alive else { throw skip() }
        if !e.running {
            engine?.running = true
            engine?.rejected = false
            sync()
        }
        await h.start()
    }

    @Command(weight: 1)
    func stop() async throws {
        guard engine?.alive == true else { throw skip() }
        engine?.running = false
        await h.stop()
    }

    @Command(weight: 1)
    func shutdown() async throws {
        guard let e = engine, e.alive else { throw skip() }
        engine?.alive = false
        engine?.running = false
        await h.shutdown()
        frozen[e.server] = h.apis[e.server].calls.count
    }

    /// What the attached engine's server (A before any attach) answers every call with from now on.
    @Command(weight: 3, .int(in: 0...5))
    func setError(choice: Int) throws {
        let server = engine?.server ?? 0
        errors[server] = choice
        h.setError(server, choice)
    }

    func failureDescription() -> String? {
        "cache: \(String(describing: cacheServer)), engine: \(String(describing: engine)), errors: \(errors), "
            + "model queue: \(pending), store queue: \(String(describing: try? h.store.pending())), "
            + "recorded: \(recordedOn), sent: \((0...1).map { h.idsSent(to: $0) }), calls: \(h.apis.map(\.calls))"
    }

    // MARK: - Model

    private static func key(_ c: PendingChange) -> (String, String) {
        switch c {
        case .status(let id, let s): ("\(id)/status", s.rawValue)
        case .starred(let id, let v): ("\(id)/starred", "\(v)")
        }
    }

    private func queue(_ c: PendingChange) {
        let (k, v) = Self.key(c)
        pending[k] = v
        if case .status(let id, _) = c { recordedOn[cacheServer ?? -1, default: []].insert(id) }
        if case .starred(let id, _) = c { recordedOn[cacheServer ?? -1, default: []].insert(id) }
    }

    /// One sync on the attached engine against its server's current error.
    private func sync() {
        guard let e = engine, e.alive else { return }
        let choice = errors[e.server]
        if choice == 0 {
            pending = [:]
            engine?.rejected = false
        } else if SessionHarness.permanent.contains(choice) {
            pending = [:]
        } else if SessionHarness.errors[choice] == .unauthorized {
            engine?.rejected = true
            engine?.running = false
        }
    }

    private func attachModel(_ server: Int, gap: PendingChange?) {
        let newServer: Bool
        if let cacheServer {
            newServer = cacheServer != server
        } else {
            // A cache with no server recorded is adopted on the spot.
            cacheServer = server
            recordedOn[server, default: []].formUnion(recordedOn.removeValue(forKey: -1) ?? [])
            newServer = false
        }
        frozen[server] = nil
        if let gap { queue(gap) }      // no engine is attached: straight into the store's queue
        if newServer {
            pending = [:]
            cacheServer = server
        }
        engine = (server: server, alive: true, running: true, rejected: false)
        sync()
    }
}
