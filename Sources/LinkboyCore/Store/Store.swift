import Foundation
import GRDB

public enum PendingChange: Codable, Equatable, Sendable {
    case status(id: Int64, EntryStatus)
    case starred(id: Int64, Bool)
}

public enum ListScope: Hashable, Codable, Sendable {
    case unread(category: Int64?, feed: Int64?)
    case starred
}

/// Local cache of Miniflux entries plus the queue of read/star changes not yet sent to the server.
public final class Store: Sendable {
    private let pool: DatabasePool

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        pool = try DatabasePool(path: path.path)
        try Schema.migrator().migrate(pool)
    }

    /// Inserts or updates entries. A field with a pending change keeps its local value; all else takes the server's.
    public func upsert(_ entries: [Entry]) throws {
        try pool.write { db in
            for e in entries {
                var status = e.status
                var starred = e.starred
                let rows = try Row.fetchAll(db, sql: "SELECT kind, value FROM pendingChange WHERE entryID = ?", arguments: [e.id])
                if !rows.isEmpty, let local = try Row.fetchOne(db, sql: "SELECT status, starred FROM entry WHERE id = ?", arguments: [e.id]) {
                    for r in rows {
                        switch r["kind"] as String {
                        case "status": status = EntryStatus(rawValue: local["status"]) ?? status
                        case "starred": starred = local["starred"]
                        default: break
                        }
                    }
                }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO entry
                    (id, feedID, feedTitle, categoryID, categoryTitle, status, title, url, commentsURL, publishedAt, changedAt, starred)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [e.id, e.feedID, e.feed.title, e.feed.category.id, e.feed.category.title, status.rawValue,
                                     e.title, e.url.absoluteString, e.commentsURL?.absoluteString,
                                     e.publishedAt.timeIntervalSince1970, e.changedAt.timeIntervalSince1970, starred])
            }
        }
    }

    /// Entries in the order of `ids`; unknown ids are skipped.
    public func entries(ids: [Int64]) throws -> [Entry] {
        let found = try pool.read { db in
            var found: [Int64: Entry] = [:]
            for start in stride(from: 0, to: ids.count, by: Self.idsPerQuery) {
                let chunk = Array(ids[start..<min(start + Self.idsPerQuery, ids.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT * FROM entry WHERE id IN (\(marks))",
                                            arguments: StatementArguments(chunk)) {
                    if let e = Self.entry(row) { found[e.id] = e }
                }
            }
            return found
        }
        return ids.compactMap { found[$0] }
    }

    /// How many of `ids` are known and unread, counted in the database rather than by loading the entries: cheap
    /// enough to recompute on every keypress over a long list.
    public func unreadCount(among ids: [Int64]) throws -> Int {
        try pool.read { db in
            var count = 0
            for start in stride(from: 0, to: ids.count, by: Self.idsPerQuery) {
                let chunk = Array(ids[start..<min(start + Self.idsPerQuery, ids.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                count += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE status = 'unread' AND id IN (\(marks))",
                                          arguments: StatementArguments(chunk)) ?? 0
            }
            return count
        }
    }

    /// Under SQLite's lowest default bound-parameter limit.
    private static let idsPerQuery = 999

    /// Ids matching `scope`, newest published first (ties: higher id first). Removed entries never appear.
    public func entryIDs(matching scope: ListScope) throws -> [Int64] {
        try pool.read { db in
            var sql = "SELECT id FROM entry WHERE status != 'removed'"
            var args: [any DatabaseValueConvertible] = []
            switch scope {
            case .unread(let category, let feed):
                sql += " AND status = 'unread'"
                if let category { sql += " AND categoryID = ?"; args.append(category) }
                if let feed { sql += " AND feedID = ?"; args.append(feed) }
            case .starred:
                sql += " AND starred = 1"
            }
            sql += " ORDER BY publishedAt DESC, id DESC"
            return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    public func setStatus(_ s: EntryStatus, ids: [Int64]) throws {
        try pool.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE entry SET status = ? WHERE id = ?", arguments: [s.rawValue, id])
            }
        }
    }

    public func setStarred(_ v: Bool, id: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE entry SET starred = ? WHERE id = ?", arguments: [v, id])
        }
    }

    /// A local read or star: writes each change to its entry and queues it for the server, in one transaction.
    public func record(_ changes: [PendingChange]) throws {
        try pool.write { db in
            for c in changes {
                switch c {
                case .status(let id, let s):
                    try db.execute(sql: "UPDATE entry SET status = ? WHERE id = ?", arguments: [s.rawValue, id])
                case .starred(let id, let v):
                    try db.execute(sql: "UPDATE entry SET starred = ? WHERE id = ?", arguments: [v, id])
                }
                try Self.enqueue(c, in: db)
            }
        }
    }

    /// Queues changes; a later change of the same kind for the same entry replaces the earlier one.
    public func enqueue(_ changes: [PendingChange]) throws {
        try pool.write { db in
            for c in changes { try Self.enqueue(c, in: db) }
        }
    }

    private static func enqueue(_ c: PendingChange, in db: Database) throws {
        let (id, kind, value) = columns(c)
        try db.execute(sql: "DELETE FROM pendingChange WHERE entryID = ? AND kind = ?", arguments: [id, kind])
        try db.execute(sql: "INSERT INTO pendingChange (entryID, kind, value) VALUES (?, ?, ?)", arguments: [id, kind, value])
    }

    public func pending() throws -> [PendingChange] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT entryID, kind, value FROM pendingChange ORDER BY seq").compactMap { r in
                let id: Int64 = r["entryID"]
                let value: String = r["value"]
                switch r["kind"] as String {
                case "status": return EntryStatus(rawValue: value).map { .status(id: id, $0) }
                case "starred": return .starred(id: id, value == "1")
                default: return nil
                }
            }
        }
    }

    /// Removes exactly these changes; a change since replaced by a different value stays queued.
    public func dequeue(_ changes: [PendingChange]) throws {
        try pool.write { db in
            for c in changes {
                let (id, kind, value) = Self.columns(c)
                try db.execute(sql: "DELETE FROM pendingChange WHERE entryID = ? AND kind = ? AND value = ?",
                               arguments: [id, kind, value])
            }
        }
    }

    public func lastSync() throws -> Date? {
        try pool.read { db in
            try Double.fetchOne(db, sql: "SELECT CAST(value AS REAL) FROM meta WHERE key = 'lastSync'")
                .map(Date.init(timeIntervalSince1970:))
        }
    }

    public func setLastSync(_ d: Date) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('lastSync', ?)",
                           arguments: ["\(d.timeIntervalSince1970)"])
        }
    }

    /// Empties the cache: entries, queued changes and the last-sync mark. For switching to another server,
    /// whose entry ids mean different entries.
    public func reset() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM entry; DELETE FROM pendingChange; DELETE FROM meta")
        }
    }

    private static func columns(_ c: PendingChange) -> (Int64, String, String) {
        switch c {
        case .status(let id, let s): return (id, "status", s.rawValue)
        case .starred(let id, let v): return (id, "starred", v ? "1" : "0")
        }
    }

    private static func entry(_ r: Row) -> Entry? {
        guard let status = EntryStatus(rawValue: r["status"]), let url = URL(string: r["url"] as String) else { return nil }
        let comments: String? = r["commentsURL"]
        return Entry(id: r["id"], feedID: r["feedID"], status: status, title: r["title"], url: url,
                     commentsURL: comments.flatMap { URL(string: $0) },
                     publishedAt: Date(timeIntervalSince1970: r["publishedAt"]),
                     changedAt: Date(timeIntervalSince1970: r["changedAt"]), starred: r["starred"],
                     feed: FeedRef(id: r["feedID"], title: r["feedTitle"],
                                   category: CategoryRef(id: r["categoryID"], title: r["categoryTitle"])))
    }
}
