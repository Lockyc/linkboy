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
/// A new-window request for no URL or `about:blank` is dropped rather than blanking the viewer. A clicked link or
/// new-window request for a scheme a web view can't load (`mailto:`, an app's own scheme) goes to macOS, since the
/// viewer would silently do nothing with it.
public enum LinkPolicy {
    /// The schemes a web view loads itself.
    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "javascript"]

    public static func decide(command: Bool, linkActivated: Bool, opensNewWindow: Bool, url: URL?) -> LinkDecision {
        let shows = url.map { $0.absoluteString != "about:blank" } ?? false
        if let scheme = url?.scheme?.lowercased(), !webSchemes.contains(scheme), linkActivated || opensNewWindow {
            return .openExternally
        }
        if command && (linkActivated || opensNewWindow) { return shows ? .openExternally : .ignore }
        if opensNewWindow { return shows ? .loadHere : .ignore }
        return .allow
    }
}
