import Foundation

/// A frozen reading list: items read since it was taken stay put so you can step back to them, and new
/// arrivals only raise `newCount` until the list is re-taken.
public struct Snapshot: Sendable {
    public let scope: ListScope
    public private(set) var ids: [Int64]
    /// Index into `ids` of the item being read; nil before the first `next()`.
    public var cursor: Int?
    public private(set) var newCount: Int
    private var arrivals: Set<Int64> = []

    public static func take(_ scope: ListScope, store: Store) throws -> Snapshot {
        Snapshot(scope: scope, ids: try store.entryIDs(matching: scope), cursor: nil, newCount: 0)
    }

    /// Moves forward and returns that item's id; nil (cursor unchanged) at the end or for an empty list.
    public mutating func next() -> Int64? {
        let target = (cursor ?? -1) + 1
        guard ids.indices.contains(target) else { return nil }
        cursor = target
        return ids[target]
    }

    /// Moves back and returns that item's id; nil (cursor unchanged) at the start or before the first `next()`.
    public mutating func previous() -> Int64? {
        guard let cursor, cursor > 0 else { return nil }
        self.cursor = cursor - 1
        return ids[cursor - 1]
    }

    /// Counts ids that are not in the list and not already counted; they do not join it.
    public mutating func noteArrivals(_ incoming: [Int64]) {
        let known = Set(ids)
        for id in incoming where !known.contains(id) {
            arrivals.insert(id)
        }
        newCount = arrivals.count
    }
}
