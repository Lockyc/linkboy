import Foundation

public enum SyncOutcome: Equatable, Sendable {
    case ok(newEntryIDs: [Int64])
    case offline
    case unauthorized
    case failed(String)
}

/// Pushes queued read/star changes to Miniflux, then pulls new and changed entries into the store.
/// One sync runs at a time; local intents write the store and queue immediately, then kick a background sync.
public actor SyncEngine {
    private static let pageSize = 250
    private static let batchSize = 1000

    private let api: MinifluxAPI
    private let store: Store
    private let interval: Duration
    private let continuation: AsyncStream<SyncOutcome>.Continuation
    /// Every `syncNow` result, in order. Single consumer.
    public nonisolated let events: AsyncStream<SyncOutcome>

    private var timer: Task<Void, Never>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var kickQueued = false

    public init(api: MinifluxAPI, store: Store, interval: Duration = .seconds(300)) {
        self.api = api
        self.store = store
        self.interval = interval
        (events, continuation) = AsyncStream.makeStream()
    }

    /// Syncs now, then every `interval`, until `stop()`.
    public func start() {
        guard timer == nil else { return }
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

    @discardableResult
    public func syncNow() async -> SyncOutcome {
        await run(fromKick: false)
    }

    public func markRead(_ ids: [Int64]) async { await record(.read, ids) }
    public func markUnread(_ ids: [Int64]) async { await record(.unread, ids) }

    public func setStarred(_ v: Bool, id: Int64) async {
        do {
            try store.setStarred(v, id: id)
            try store.enqueue([.starred(id: id, v)])
        } catch {
            continuation.yield(.failed(String(describing: error)))
            return
        }
        kick()
    }

    // MARK: - Scheduling

    private func record(_ status: EntryStatus, _ ids: [Int64]) async {
        do {
            try store.setStatus(status, ids: ids)
            try store.enqueue(ids.map { .status(id: $0, status) })
        } catch {
            continuation.yield(.failed(String(describing: error)))
            return
        }
        kick()
    }

    /// Schedules a background sync; kicks arriving before it starts coalesce into it.
    private func kick() {
        guard !kickQueued else { return }
        kickQueued = true
        Task { await self.run(fromKick: true) }
    }

    @discardableResult
    private func run(fromKick: Bool) async -> SyncOutcome {
        await acquire()
        defer { release() }
        if fromKick { kickQueued = false }
        guard let outcome = await sync() else { return .failed("Cancelled") }
        continuation.yield(outcome)
        // A rejected key stays rejected: the timer stays off until the UI calls `start()` after re-auth.
        if outcome == .unauthorized { stop() }
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
            try store.setLastSync(syncStart)
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

    /// Errors that abort the sync propagate; a change the server will never accept (404, 4xx) is dropped.
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
        } catch MinifluxError.http(let code) where (400..<500).contains(code) && !Task.isCancelled {
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
                let page = try await api.entries(query).entries
                let known = Set(try store.entries(ids: page.map(\.id)).map(\.id))
                try store.upsert(page)
                for e in page where !known.contains(e.id) && seen.insert(e.id).inserted { fresh.append(e.id) }
                if page.count < Self.pageSize { break }
                query.offset += Self.pageSize
            }
        }
        guard lastSync != nil else { return [] }
        return try store.entries(ids: fresh).filter { $0.status == .unread }.map(\.id)
    }
}
