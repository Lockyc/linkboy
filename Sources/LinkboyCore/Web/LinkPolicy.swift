import Foundation

public enum LinkDecision: Equatable, Sendable {
    /// Hand the URL to the default browser and cancel the navigation.
    case openExternally
    /// Cancel the new-window request and load its URL in the viewer that made it.
    case loadHere
    /// Cancel a new-window request that has nothing to show.
    case ignore
    /// Let the navigation proceed in the viewer.
    case allow
}

/// Where a viewer's navigation goes: ⌘ on a clicked link or a new-window request sends it to the default browser;
/// a new-window request without ⌘ (`target=_blank`, `window.open`) loads in the same viewer; anything else stays.
/// A new-window request for no URL or `about:blank` is dropped rather than blanking the viewer.
public enum LinkPolicy {
    public static func decide(command: Bool, linkActivated: Bool, opensNewWindow: Bool, url: URL?) -> LinkDecision {
        let shows = url.map { $0.absoluteString != "about:blank" } ?? false
        if command && (linkActivated || opensNewWindow) { return shows ? .openExternally : .ignore }
        if opensNewWindow { return shows ? .loadHere : .ignore }
        return .allow
    }
}
