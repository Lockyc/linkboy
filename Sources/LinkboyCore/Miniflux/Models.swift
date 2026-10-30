import Foundation

public enum EntryStatus: String, Codable, Sendable, Equatable {
    case unread, read, removed
}

public struct CategoryRef: Codable, Sendable, Equatable {
    public var id: Int64
    public var title: String

    public init(id: Int64, title: String) {
        self.id = id
        self.title = title
    }
}

public struct FeedRef: Codable, Sendable, Equatable {
    public var id: Int64
    public var title: String
    public var category: CategoryRef

    public init(id: Int64, title: String, category: CategoryRef) {
        self.id = id
        self.title = title
        self.category = category
    }
}

public struct User: Codable, Sendable, Equatable {
    public var id: Int64
    public var username: String

    public init(id: Int64, username: String) {
        self.id = id
        self.username = username
    }
}

public struct Entry: Codable, Sendable, Identifiable, Equatable {
    public var id: Int64
    public var feedID: Int64
    public var status: EntryStatus
    public var title: String
    public var url: URL
    /// Miniflux sends `""` when an item has no comments page; that decodes to nil.
    public var commentsURL: URL?
    public var publishedAt: Date
    public var changedAt: Date
    public var starred: Bool
    public var feed: FeedRef

    public init(id: Int64, feedID: Int64, status: EntryStatus, title: String, url: URL, commentsURL: URL?,
                publishedAt: Date, changedAt: Date, starred: Bool, feed: FeedRef) {
        self.id = id
        self.feedID = feedID
        self.status = status
        self.title = title
        self.url = url
        self.commentsURL = commentsURL
        self.publishedAt = publishedAt
        self.changedAt = changedAt
        self.starred = starred
        self.feed = feed
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, title, url, starred, feed
        case feedID = "feed_id"
        case commentsURL = "comments_url"
        case publishedAt = "published_at"
        case changedAt = "changed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        feedID = try c.decode(Int64.self, forKey: .feedID)
        status = try c.decode(EntryStatus.self, forKey: .status)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(URL.self, forKey: .url)
        let comments = try c.decodeIfPresent(String.self, forKey: .commentsURL) ?? ""
        commentsURL = comments.isEmpty ? nil : URL(string: comments)
        publishedAt = try MinifluxDate.decode(c, forKey: .publishedAt)
        changedAt = try MinifluxDate.decode(c, forKey: .changedAt)
        starred = try c.decode(Bool.self, forKey: .starred)
        feed = try c.decode(FeedRef.self, forKey: .feed)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(feedID, forKey: .feedID)
        try c.encode(status, forKey: .status)
        try c.encode(title, forKey: .title)
        try c.encode(url, forKey: .url)
        try c.encode(commentsURL?.absoluteString ?? "", forKey: .commentsURL)
        try c.encode(MinifluxDate.string(publishedAt), forKey: .publishedAt)
        try c.encode(MinifluxDate.string(changedAt), forKey: .changedAt)
        try c.encode(starred, forKey: .starred)
        try c.encode(feed, forKey: .feed)
    }
}

public struct EntryQuery: Sendable, Equatable {
    public var status: [EntryStatus]?
    public var starred: Bool?
    public var categoryID: Int64?
    public var feedID: Int64?
    public var changedAfter: Date?
    public var limit: Int
    public var offset: Int

    public init(status: [EntryStatus]? = nil, starred: Bool? = nil, categoryID: Int64? = nil, feedID: Int64? = nil,
                changedAfter: Date? = nil, limit: Int = 100, offset: Int = 0) {
        self.status = status
        self.starred = starred
        self.categoryID = categoryID
        self.feedID = feedID
        self.changedAfter = changedAfter
        self.limit = limit
        self.offset = offset
    }
}

/// ISO-8601 timestamps as Miniflux sends them, with or without fractional seconds.
enum MinifluxDate {
    // ISO8601DateFormatter is documented thread-safe for date(from:)/string(from:).
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }

    static func string(_ d: Date) -> String { fractional.string(from: d) }

    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) throws -> Date {
        let s = try c.decode(String.self, forKey: key)
        guard let d = parse(s) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Unparseable date: \(s)")
        }
        return d
    }
}

public enum MinifluxError: Error, Equatable, Sendable {
    case unauthorized
    case notFound
    case http(Int)
    case transport(String)
    case decoding(String)
}
