import os

/// The app's unified-log channels, under the bundle ID as subsystem (`log show --predicate
/// 'subsystem == "com.lockyc.linkboy"'`). Nothing logged carries the API key or a URL's path or query.
public enum Log {
    /// Sync outcomes, changes the server refused for good, and entries that couldn't be decoded.
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    /// Web-view load failures and content-rule compile or save failures.
    public static let web = Logger(subsystem: subsystem, category: "web")

    private static let subsystem = LinkboyCore.bundleID
}
