import AppKit
import LinkboyCore

/// Loads the next item's page and comments in offscreen viewers while the current one is read, so moving forward
/// shows them already rendered. Viewers come from the same `WebViewer` construction as the visible ones, never
/// join the window, and only ever load the item's own two URLs.
final class Prefetcher {
    typealias Viewers = (page: WebViewer?, comments: WebViewer?)

    private let depth: Int
    private var held: [Int64: Viewers] = [:]

    init(depth: Int = 1) { self.depth = depth }

    /// Starts loading the `depth` items after `entry` and discards everything held for other items.
    /// `entries` resolves ids to entries (ids it cannot resolve are skipped).
    func prepare(after entry: Entry, in snapshot: Snapshot, entries: ([Int64]) -> [Entry]) {
        let targets = snapshot.prefetchTargets(after: entry.id, depth: depth)
        for id in held.keys where !targets.contains(id) { discard(id) }
        let missing = targets.filter { held[$0] == nil }
        for next in entries(missing) { held[next.id] = start(next) }
    }

    /// Hands over the viewers held for `entry` (loaded or loading), which are no longer the prefetcher's.
    func take(for entry: Entry) -> Viewers? { held.removeValue(forKey: entry.id) }

    func discardAll() {
        for id in Array(held.keys) { discard(id) }
    }

    private func discard(_ id: Int64) {
        guard let viewers = held.removeValue(forKey: id) else { return }
        viewers.page?.discard()
        viewers.comments?.discard()
    }

    private func start(_ entry: Entry) -> Viewers {
        let page = offscreenViewer()
        page.load(entry.url)
        guard let commentsURL = entry.commentsURL else { return (page, nil) }
        let comments = offscreenViewer()
        comments.load(commentsURL)
        return (page, comments)
    }

    /// Sized like a reading pane so the page lays out as it will when shown.
    private func offscreenViewer() -> WebViewer {
        let viewer = WebViewer()
        viewer.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        return viewer
    }
}
