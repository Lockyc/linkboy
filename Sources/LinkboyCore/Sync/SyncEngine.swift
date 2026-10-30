import Foundation

public enum SyncOutcome: Equatable, Sendable {
    case ok(newEntryIDs: [Int64])
    case offline
    case unauthorized
    case failed(String)
}

/// Pushes queued read/star changes to Miniflux, then pulls new and changed entries into the store.
/// One sync runs at a time; local intents write the store and queue immediately, then kick a background sync.
/// Once Miniflux rejects the key, intents still write the store and queue but kick nothing, until `start()`.
public actor SyncEngine {
    private static let pageSize = 250
    private static let batchSize = 1000
    /// `lastSync` is stored this far before the sync started, so an entry stamped by a server clock running behind
    /// ours is still pulled next time. Re-pulling an entry is harmless: upsert is idempotent.
    private static let clockSkew: TimeInterval = 5 * 60
    /// Status codes that mean the server will never accept a pushed change, so it is dropped rather than retried.
    private static let permanentRejections: Set<Int> = [400, 409, 422]

    private let api: MinifluxAPI
    private let store: Store
    private let interval: Duration
    private let continuation: AsyncStream<SyncOutcome>.Continuation
    /// Every sync's result, in order, except that `.unauthorized` is reported only when the key becomes rejected,
    /// not again while it stays so. Single consumer.
    public nonisolated let events: AsyncStream<SyncOutcome>

    private var timer: Task<Void, Never>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var kickQueued = false
    private var kickTask: Task<SyncOutcome, Never>?
    private var isShutDown = false
    /// Miniflux rejected the key on the last sync; cleared by a successful sync or `start()`.
    private var rejected = false

    public init(api: MinifluxAPI, store: Store, interval: Duration = .seconds(300)) {
        self.api = api
        self.store = store
        self.interval = interval
        (events, continuation) = AsyncStream.makeStream()
    }

    /// Syncs now, then every `interval`, until `stop()`.
    public func start() {
        guard timer == nil, !isShutDown else { return }
        rejected = false
        let interval = interval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.syncNow() != nil else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Retires the engine for good: cancels the timer and any background sync, waits until no sync is
    /// running, and ends `events`. Afterwards every call is a no-op, so nothing touches the API or the store
    /// again — the store can be wiped for another server.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        stop()
        kickTask?.cancel()
        await acquire()
        release()
        continuation.finish()
    }

    @discardableResult
    public func syncNow() async -> SyncOutcome {
        await run(fromKick: false)
    }

    public func markRead(_ ids: [Int64]) async { await record(ids.map { .status(id: $0, .read) }) }
    public func markUnread(_ ids: [Int64]) async { await record(ids.map { .status(id: $0, .unread) }) }
    public func setStarred(_ v: Bool, id: Int64) async { await record([.starred(id: id, v)]) }

    /// Writes local changes to the store and its queue, then schedules a background sync to push them (none while
    /// the key is rejected; the queue keeps them for the next sync).
    public func record(_ changes: [PendingChange]) async {
        guard !isShutDown else { return }
        do {
            try store.record(changes)
        } catch {
            continuation.yield(.failed(String(describing: error)))
            return
        }
        kick()
    }

    // MARK: - Scheduling

    /// Schedules a background sync; kicks arriving before it starts coalesce into it.
    private func kick() {
        guard !kickQueued, !rejected else { return }
        kickQueued = true
        kickTask = Task { await self.run(fromKick: true) }
    }

    @discardableResult
    private func run(fromKick: Bool) async -> SyncOutcome {
        guard !isShutDown else { return .failed("Shut down") }
        await acquire()
        defer { release() }
        if fromKick { kickQueued = false }
        guard !isShutDown else { return .failed("Shut down") }
        if fromKick && rejected { return .unauthorized }
        guard let outcome = await sync() else { return .failed("Cancelled") }
        if outcome == .unauthorized {
            // A rejected key stays rejected: the timer and kicks stay off until the UI calls `start()` after re-auth.
            stop()
            if rejected { return outcome }
            rejected = true
        } else if case .ok = outcome {
            rejected = false
        }
        continuation.yield(outcome)
        return outcome
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: - Sync

    /// nil when cancelled: not an outcome, nothing is emitted.
    private func sync() async -> SyncOutcome? {
        do {
            try await push()
            let syncStart = Date()
            let newIDs = try await pull()
            try store.setLastSync(syncStart.addingTimeInterval(-Self.clockSkew))
            return .ok(newEntryIDs: newIDs)
        } catch is CancellationError {
            return nil
        } catch let e as MinifluxError {
            if Task.isCancelled { return nil }
            switch e {
            case .unauthorized: return .unauthorized
            case .transport: return .offline
            case .notFound: return .failed("Not found")
            case .http(let code): return .failed("Server error (HTTP \(code))")
            case .decoding(let m): return .failed(m)
            }
        } catch {
            return Task.isCancelled ? nil : .failed(String(describing: error))
        }
    }

    /// Errors that abort the sync propagate; a change the server will never accept (404, `permanentRejections`) is
    /// dropped. Anything else (403, 408, 429, 5xx…) keeps it queued for the next sync.
    private func push() async throws {
        let pending = try store.pending()
        for status in [EntryStatus.read, .unread, .removed] {
            let ids = pending.compactMap { c -> Int64? in
                if case .status(let id, let s) = c, s == status { return id }
                return nil
            }
            for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
                let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
                let changes = batch.map { PendingChange.status(id: $0, status) }
                try await attempt(changes) { try await self.api.setStatus(status, ids: batch) }
            }
        }
        for case .starred(let id, let desired) in pending {
            try await attempt([.starred(id: id, desired)]) {
                if try await self.api.entry(id: id).starred != desired { try await self.api.toggleBookmark(id: id) }
            }
        }
    }

    private func attempt(_ changes: [PendingChange], _ call: () async throws -> Void) async throws {
        do {
            try await call()
            try store.dequeue(changes)
        } catch MinifluxError.notFound where !Task.isCancelled {
            try store.dequeue(changes)
        } catch MinifluxError.http(let code) where Self.permanentRejections.contains(code) && !Task.isCancelled {
            try store.dequeue(changes)
        }
    }

    private func pull() async throws -> [Int64] {
        let lastSync = try store.lastSync()
        var queries: [EntryQuery] = []
        if let lastSync {
            queries = [EntryQuery(changedAfter: lastSync, limit: Self.pageSize)]
        } else {
            queries = [EntryQuery(status: [.unread], limit: Self.pageSize), EntryQuery(starred: true, limit: Self.pageSize)]
        }
        var fresh: [Int64] = []
        var seen = Set<Int64>()
        for var query in queries {
            while true {
                let page = try await api.entries(query)
                let known = Set(try store.entries(ids: page.entries.map(\.id)).map(\.id))
                try store.upsert(page.entries)
                for e in page.entries where !known.contains(e.id) && seen.insert(e.id).inserted { fresh.append(e.id) }
                if page.served < Self.pageSize { break }
                query.offset += Self.pageSize
            }
        }
        guard lastSync != nil else { return [] }
        return try store.entries(ids: fresh).filter { $0.status == .unread }.map(\.id)
    }
}
