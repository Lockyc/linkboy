import Foundation

/// What "mark all as read" would touch: the snapshot's items that are still unread, in snapshot order.
public struct MarkAllPlan: Sendable, Equatable {
    public let scope: ListScope
    public let ids: [Int64]
    let scopeName: String

    public var prompt: String {
        "Mark \(ids.count) unread item\(ids.count == 1 ? "" : "s") in \(scopeName) as read?"
    }

    /// Nil when nothing in the snapshot is unread. Items that arrived after the snapshot are never included.
    public static func plan(for snapshot: Snapshot, store: Store) throws -> MarkAllPlan? {
        let entries = try store.entries(ids: snapshot.ids)
        let unread = entries.filter { $0.status == .unread }
        guard !unread.isEmpty else { return nil }
        let name: String
        switch snapshot.scope {
        case .starred: name = "Starred"
        case .unread(nil, nil): name = "All feeds"
        case .unread(_, .some): name = unread[0].feed.title
        case .unread(_, nil): name = unread[0].feed.category.title
        }
        return MarkAllPlan(scope: snapshot.scope, ids: unread.map(\.id), scopeName: name)
    }
}

/// Session-only record of mark-all plans, so the latest can be undone. Writes nothing itself.
public final class UndoLedger: @unchecked Sendable {
    private var plans: [MarkAllPlan] = []
    private let lock = NSLock()

    public init() {}

    public func record(_ plan: MarkAllPlan) {
        lock.withLock { plans.append(plan) }
    }

    public func undoLast() -> MarkAllPlan? {
        lock.withLock { plans.popLast() }
    }
}
