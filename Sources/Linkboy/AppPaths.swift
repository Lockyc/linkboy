import Foundation

/// Where the app keeps its files on disk.
enum AppPaths {
    /// The app's folder in Application Support; created by whoever first writes into it.
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("linkboy", isDirectory: true)
}
