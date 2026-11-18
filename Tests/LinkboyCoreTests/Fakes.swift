import Foundation
@testable import LinkboyCore

/// Holds callers in `pass()` until `open()`; `waitForArrival()` returns once a caller is held.
actor Gate {
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

final class FakeAPI: MinifluxAPI, @unchecked Sendable {
    var gate: Gate?                               // setStatus blocks here, then throws .transport if its task was cancelled
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _queries: [EntryQuery] = []
    private var _statusCalls: [(EntryStatus, [Int64])] = []
    var pages: [Entry] = []                       // served for every entries() call, sliced by offset/limit
    var undecodable: Set<Int64> = []              // ids in `pages` served as entries that failed to decode
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

    func entries(_ q: EntryQuery) async throws -> EntryPage {
        lock.withLock { _queries.append(q) }
        try record("entries")
        let slice = Array(pages.dropFirst(q.offset).prefix(q.limit))
        let good = slice.filter { !undecodable.contains($0.id) }
        return EntryPage(entries: good, skipped: slice.count - good.count)
    }

    func entry(id: Int64) async throws -> Entry {
        try record("entry", key: "entry:\(id)")
        guard let e = serverEntries[id] else { throw MinifluxError.notFound }
        return e
    }

    func setStatus(_ s: EntryStatus, ids: [Int64]) async throws {
        lock.withLock { _statusCalls.append((s, ids)) }
        await gate?.pass()
        if gate != nil, Task.isCancelled { throw MinifluxError.transport("cancelled") }
        try record("setStatus")
    }

    func toggleBookmark(id: Int64) async throws { try record("toggle:\(id)") }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

/// An entry in feed 1, category 10, published in id order.
func makeEntry(_ id: Int64, status: EntryStatus = .unread, starred: Bool = false) -> Entry {
    Entry(id: id, feedID: 1, status: status, title: "T", url: URL(string: "https://example.com/\(id)")!,
          commentsURL: nil, publishedAt: Date(timeIntervalSince1970: 1_000 + Double(id)),
          changedAt: Date(timeIntervalSince1970: 2_000), starred: starred,
          feed: FeedRef(id: 1, title: "F", category: CategoryRef(id: 10, title: "C")))
}
