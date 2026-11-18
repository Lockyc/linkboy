import Foundation

/// The reading window below its views: the cache, the attached sync engine, the frozen list and the open item.
/// The window shows `snapshot` and `current` and applies each `Change` it is handed; every ordering decision
/// around attaching, syncing and recording lives here.
@MainActor
public final class ReadingSession {
    public enum Change: Equatable, Sendable {
        /// The status line's text.
        case status(String)
        /// `snapshot` was re-taken: the rows, the selection, the prefetch and the scope menu follow it.
        case listTaken
        /// A re-take failed and the previous list stands; the scope menu goes back to its scope.
        case listKept
        /// These entries' row state changed; the list's membership holds.
        case rows([Entry])
        /// A sync succeeded, so whatever couldn't load offline can retry.
        case synced
        /// Miniflux has just started rejecting the key.
        case unauthorized
        /// The open item, the new count or Sync Now's availability may have changed.
        case chrome
    }

    public let store: Store
    public private(set) var api: MinifluxAPI?
    public private(set) var engine: SyncEngine?
    /// The engine's last sync was rejected for the key; reading carries on locally until `attach`.
    public private(set) var rejected = false
    /// Bumped by `attach`, so work started for a previous attach is dropped when it returns.
    public private(set) var generation = 0
    public var snapshot: Snapshot
    /// The open item; nil when nothing is open.
    public var current: Entry?
    public var onChange: ((Change) -> Void)?

    private let makeEngine: (MinifluxAPI, Store) -> SyncEngine
    private var events: Task<Void, Never>?
    /// The latest `attach`'s handoff, which ends once the new engine has started (or the cache couldn't be
    /// emptied).
    private(set) var handoff: Task<Void, Never>?

    public convenience init(store: Store) throws {
        try self.init(store: store) { SyncEngine(api: $0, store: $1) }
    }

    init(store: Store, makeEngine: @escaping (MinifluxAPI, Store) -> SyncEngine) throws {
        self.store = store
        self.makeEngine = makeEngine
        snapshot = try Snapshot.take(.unread(category: nil, feed: nil), store: store)
    }

    /// Starts syncing with `api` at `server`, replacing any previous engine once it has fully shut down. A cache
    /// the store records as another server's is emptied in between: that server's entry ids, queued changes and
    /// last-sync mark mean nothing here; if that fails, no engine is attached and the status line says why. A
    /// cache with no server recorded predates the record and is taken as `server`'s. Until the new engine is
    /// attached, `record` writes straight to the store's queue. Returns whether `server` is a new server, in
    /// which case the open item is closed.
    @discardableResult
    public func attach(api: MinifluxAPI, server: URL) -> Bool {
        let newServer: Bool
        switch Result(catching: { try store.server() }) {
        case .success(let recorded?): newServer = recorded != server
        case .success(nil): newServer = (try? store.setServer(server)) == nil
        case .failure: newServer = true
        }
        events?.cancel()
        let old = engine
        engine = nil
        rejected = false
        generation += 1
        let generation = generation
        self.api = api
        if newServer { current = nil }
        emit(.status("Updating…"))
        handoff = Task { @MainActor [weak self] in
            await old?.shutdown()
            guard let self, self.generation == generation else { return }
            if newServer {
                do {
                    try self.store.reset(for: server)
                } catch {
                    // Syncing another server's entries into this cache would mix two servers' ids.
                    self.emit(.status("Couldn't clear the local cache: \(error.localizedDescription)"))
                    return
                }
                self.take(.unread(category: nil, feed: nil))
                self.emit(.chrome)
            }
            let engine = self.makeEngine(api, self.store)
            self.engine = engine
            self.events = Task { @MainActor [weak self] in
                for await outcome in engine.events { self?.handle(outcome) }
            }
            await engine.start()
        }
        return newServer
    }

    /// Re-takes `scope`'s list, keeping the open item selected if it is still in it. On a cache read failure the
    /// previous list stays, with the error in the status line.
    public func take(_ scope: ListScope) {
        do {
            snapshot = try Snapshot.take(scope, store: store)
        } catch {
            emit(.status("Couldn't read the local cache: \(error.localizedDescription)"))
            emit(.listKept)
            return
        }
        if let id = current?.id, let index = snapshot.ids.firstIndex(of: id) { snapshot.cursor = index }
        emit(.listTaken)
    }

    /// A local read or star: through the engine, which also schedules a sync, or, while none is attached, straight
    /// into the store's queue for the next engine to push. Returns the engine's write, when there is one.
    @discardableResult
    public func record(_ changes: [PendingChange]) -> Task<Void, Never>? {
        guard let engine else {
            do { try store.record(changes) } catch { emit(.status("Couldn't save to the local cache: \(error.localizedDescription)")) }
            return nil
        }
        return Task { @MainActor [weak self] in
            await engine.record(changes)
            self?.emit(.chrome)
        }
    }

    public func syncNow() {
        guard let engine, !rejected else { return }
        emit(.status("Updating…"))
        Task { await engine.syncNow() }
    }

    /// Why Sync Now is unavailable, or nil when it can run.
    public var syncUnavailable: String? {
        if rejected { return "Miniflux rejected the API key" }
        if engine == nil { return "Not connected to Miniflux" }
        return nil
    }

    func handle(_ outcome: SyncOutcome) {
        switch outcome {
        case .ok(let newIDs):
            rejected = false
            emit(.status("Updated \(Date().formatted(date: .omitted, time: .shortened))"))
            if snapshot.ids.isEmpty {
                take(snapshot.scope)
            } else {
                if !newIDs.isEmpty {
                    let inScope = Set((try? store.entryIDs(matching: snapshot.scope)) ?? [])
                    snapshot.noteArrivals(newIDs.filter(inScope.contains))
                }
                // A read or star made elsewhere: the rows and the open item show it, so `s`/`u` flip the
                // current value. Row state only; the snapshot's membership holds.
                emit(.rows((try? store.entries(ids: snapshot.ids)) ?? []))
            }
            if let id = current?.id, let fresh = try? store.entries(ids: [id]).first { current = fresh }
            emit(.synced)
        case .offline:
            emit(.status("Offline"))
        case .unauthorized:
            rejected = true
            emit(.status("Miniflux rejected the API key"))
            emit(.unauthorized)
        case .failed(let message):
            emit(.status("Sync failed: \(message)"))
        }
        emit(.chrome)
    }

    private func emit(_ change: Change) { onChange?(change) }
}
